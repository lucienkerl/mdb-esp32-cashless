/**
 * Uplink telemetry from the device: which network it is on and how good the
 * signal is.
 *
 * Two sources:
 *  - the `status` payload sent on every MQTT connect carries extra
 *    `key:value` segments after `online|v:…|b:…`:
 *      cellular: `uplink:cellular|op:Telekom.de|rssi:-78|mode:LTE-M|ip:10.0.0.1`
 *      wifi:     `uplink:wifi|ssid:Office|rssi:-62|ip:192.168.1.47`
 *  - the 5-minute `mdb-log` heartbeat carries a live `rssi` on WiFi (the
 *    status value is from connect time and can be hours old).
 *
 * Stored in `embeddeds.mdb_diagnostics`:
 *  - `network`  – the current uplink, any kind, plus `measured_at` (when the
 *    signal was last sampled). What the clients read.
 *  - `cellular` – kept for cellular uplinks so older clients still show their
 *    badge; dropped when the device is on WiFi so a stale cellular block
 *    (e.g. after switching the uplink) is not shown any more.
 *
 * Pure functions only — no DB, no I/O — so they stay unit-testable.
 */

export type NetworkInfo = Record<string, string | number>;

/** Parse the extra `key:value` segments of a status payload (everything after `online|v:…|b:…`). */
export function parseStatusExtras(segments: string[]): NetworkInfo {
  const out: NetworkInfo = {};
  for (const seg of segments) {
    const colonIdx = seg.indexOf(':');
    if (colonIdx <= 0) continue;
    const key = seg.slice(0, colonIdx).trim();
    const val = seg.slice(colonIdx + 1).trim();
    if (!key || !val) continue;
    if (key === 'v' || key === 'b') continue;
    if (key === 'rssi') {
      const n = parseInt(val, 10);
      if (!Number.isNaN(n)) out[key] = n;
    } else {
      out[key] = val;
    }
  }
  return out;
}

/**
 * New diagnostics after a status payload with uplink extras. Returns `null`
 * when the payload carried none (old firmware, offline/OTA states), so the
 * caller leaves `mdb_diagnostics` untouched.
 */
export function applyStatusNetwork(
  prev: Record<string, unknown> | null,
  extras: NetworkInfo,
  nowIso: string,
): Record<string, unknown> | null {
  if (Object.keys(extras).length === 0) return null;
  const base: Record<string, unknown> = { ...(prev ?? {}) };
  // Firmware older than the WiFi telemetry sends cellular extras without
  // anything else; those payloads always meant cellular.
  const uplink = typeof extras.uplink === 'string' ? extras.uplink : 'cellular';
  const network: NetworkInfo = { ...extras, uplink, measured_at: nowIso };
  base.network = network;
  if (uplink === 'cellular') {
    base.cellular = { ...extras, uplink };
  } else {
    delete base.cellular;
  }
  return base;
}

/**
 * Fold the live signal of an mdb-log heartbeat into the stored network block.
 * Returns the diagnostics fields to write, without a top-level `rssi`.
 */
export function applyHeartbeatSignal(
  diag: Record<string, unknown>,
  prevNetwork: unknown,
  nowIso: string,
): Record<string, unknown> {
  const { rssi, ...rest } = diag;
  if (typeof rssi !== 'number' || !Number.isFinite(rssi)) return rest;
  const prev = (prevNetwork && typeof prevNetwork === 'object') ? prevNetwork as NetworkInfo : null;
  // Only WiFi sends a live value; without a known WiFi uplink there is
  // nothing to attach it to (status payload not seen yet).
  if (!prev || prev.uplink !== 'wifi') return rest;
  return { ...rest, network: { ...prev, rssi: Math.round(rssi), measured_at: nowIso } };
}
