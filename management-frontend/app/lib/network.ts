/**
 * Which network a device is on and how good its signal is, from
 * `embeddeds.mdb_diagnostics`.
 *
 * The `mqtt-webhook` writes the uplink into `network` (WiFi or cellular, with
 * `measured_at`); devices seen only before that change still have the older
 * `cellular` block, which is read as a fallback.
 *
 * Signal levels (0–4) use separate dBm limits per kind: WiFi RSSI and LTE
 * RSSI live on different scales. Ported 1:1 to iOS
 * (`Models/DeviceNetwork.swift`) and Android (`data/DeviceNetwork.kt`).
 */

export type NetworkKind = 'wifi' | 'cellular'
export type SignalQuality = 'excellent' | 'good' | 'fair' | 'weak' | 'none'
/** How the signal is painted: only weak and none draw attention. */
export type SignalTone = 'ok' | 'weak' | 'bad'

export interface DeviceNetwork {
  kind: NetworkKind
  /** SSID on WiFi, operator on cellular. */
  name: string | null
  rssi: number | null
  /** 0–4 bars / arcs; null when no signal value is known. */
  level: number | null
  quality: SignalQuality | null
  tone: SignalTone | null
  /** Radio mode on cellular (LTE-M, NB-IoT …). */
  mode: string | null
  ip: string | null
  /** When the signal was last sampled; null for the legacy `cellular` block. */
  measuredAt: Date | null
}

/** Lower dBm limit for 4, 3, 2 and 1 bars. */
export const SIGNAL_THRESHOLDS: Record<NetworkKind, readonly [number, number, number, number]> = {
  wifi: [-55, -67, -75, -85],
  cellular: [-65, -80, -95, -105],
}

export function signalLevel(kind: NetworkKind, rssi: number | null | undefined): number | null {
  if (typeof rssi !== 'number' || !Number.isFinite(rssi)) return null
  // 0 dBm is what the firmware reports when it has no reading.
  if (rssi >= 0) return null
  const [l4, l3, l2, l1] = SIGNAL_THRESHOLDS[kind]
  if (rssi >= l4) return 4
  if (rssi >= l3) return 3
  if (rssi >= l2) return 2
  if (rssi >= l1) return 1
  return 0
}

const QUALITY: readonly SignalQuality[] = ['none', 'weak', 'fair', 'good', 'excellent']

export function signalQuality(level: number | null): SignalQuality | null {
  return level == null ? null : QUALITY[Math.max(0, Math.min(4, level))]!
}

export function signalTone(level: number | null): SignalTone | null {
  if (level == null) return null
  if (level >= 2) return 'ok'
  return level === 1 ? 'weak' : 'bad'
}

const str = (v: unknown): string | null => {
  if (typeof v !== 'string') return null
  const s = v.trim()
  return s && s !== 'unknown' && s !== '0.0.0.0' && s !== '?' ? s : null
}

export function deviceNetwork(diagnostics: Record<string, any> | null | undefined): DeviceNetwork | null {
  if (!diagnostics || typeof diagnostics !== 'object') return null
  const net = diagnostics.network
  const legacy = diagnostics.cellular
  let block: Record<string, any> | null = null
  if (net && typeof net === 'object' && (net.uplink === 'wifi' || net.uplink === 'cellular')) block = net
  else if (legacy && typeof legacy === 'object' && legacy.uplink === 'cellular') block = legacy
  if (!block) return null

  const kind: NetworkKind = block.uplink
  const rssi = typeof block.rssi === 'number' && Number.isFinite(block.rssi) ? block.rssi : null
  const level = signalLevel(kind, rssi)
  const measured = typeof block.measured_at === 'string' ? new Date(block.measured_at) : null
  return {
    kind,
    name: kind === 'wifi' ? str(block.ssid) : str(block.op),
    rssi: level == null ? null : rssi,
    level,
    quality: signalQuality(level),
    tone: signalTone(level),
    mode: kind === 'cellular' ? str(block.mode) : null,
    ip: str(block.ip),
    measuredAt: measured && !Number.isNaN(measured.getTime()) ? measured : null,
  }
}
