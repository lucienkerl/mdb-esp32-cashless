/**
 * Device connectivity: one definition of "online" for the whole app.
 *
 * Ported 1:1 to iOS (`Models/DeviceConnectivity.swift`) and Android
 * (`data/DeviceConnectivity.kt`) — keep the three in step, and the test
 * cases in `__tests__/connectivity.test.ts` with them.
 *
 * Inputs and what they mean:
 * - `embeddeds.status` is written by mqtt-webhook: "online" when the device
 *   connects, "offline" from the broker's Last Will when the connection drops
 *   (≈1.5 × keepalive: 90 s on WiFi, 4.5 min on cellular), plus the OTA states.
 * - `embeddeds.status_at` moves with every status message and with the 5-minute
 *   mdb-log heartbeat. It is the device's last contact while it is online, and
 *   the moment the drop was noticed once it is offline.
 *
 * The Last Will does not always arrive (broker or forwarder restarted, message
 * lost), so "online" alone is not trusted: without a heartbeat for
 * STALE_AFTER_MS the device is "stale" — no answer, state unclear. That is two
 * missed heartbeats plus margin, so a single lost QoS-0 heartbeat never flips a
 * running device.
 */

export const HEARTBEAT_INTERVAL_MS = 5 * 60 * 1000
export const STALE_AFTER_MS = 12 * 60 * 1000
/** An update that has not finished (reboot + "online") by then is treated as stale. */
export const UPDATE_STALE_AFTER_MS = 10 * 60 * 1000

export type ConnectivityState = 'online' | 'stale' | 'offline' | 'updating' | 'never' | 'none'

/** Can the machine sell cashless? From `mdb_diagnostics.state`, the LED's second axis. */
export type ReaderState = 'ready' | 'disabled' | 'inactive'

export interface EmbeddedLike {
  status?: string | null
  status_at?: string | null
  online_since?: string | null
  mdb_diagnostics?: unknown
}

export interface Connectivity {
  state: ConnectivityState
  /** Last time the device was heard from (status_at), if ever. */
  lastContactAt: Date | null
  /**
   * The moment the state's time label refers to: online → online since,
   * offline → offline since, updating → update started, stale → last contact.
   */
  since: Date | null
  /** Start of the current (or, when offline, the last) online run. */
  onlineSince: Date | null
  /** Only set while the device is online and has reported an MDB state. */
  reader: ReaderState | null
  /** Offline, no answer, or online but the machine does not talk to the reader. */
  needsAttention: boolean
}

function toDate(value: string | null | undefined): Date | null {
  if (!value) return null
  const d = new Date(value)
  return Number.isNaN(d.getTime()) ? null : d
}

function toMs(now: Date | number): number {
  return typeof now === 'number' ? now : now.getTime()
}

export function readerStateOf(diagnostics: unknown): ReaderState | null {
  if (!diagnostics || typeof diagnostics !== 'object') return null
  const state = (diagnostics as Record<string, unknown>).state
  if (typeof state !== 'string') return null
  switch (state.toUpperCase()) {
    case 'ENABLED':
    case 'IDLE':
    case 'VEND':
      return 'ready'
    case 'DISABLED':
      return 'disabled'
    case 'INACTIVE':
      return 'inactive'
    default:
      return null
  }
}

export function deviceConnectivity(embedded: EmbeddedLike | null | undefined, now: Date | number = Date.now()): Connectivity {
  const nowMs = toMs(now)
  if (!embedded) {
    return { state: 'none', lastContactAt: null, since: null, onlineSince: null, reader: null, needsAttention: false }
  }

  const status = (embedded.status ?? '').trim().toLowerCase()
  const lastContactAt = toDate(embedded.status_at)
  const onlineSince = toDate(embedded.online_since)
  const age = lastContactAt ? nowMs - lastContactAt.getTime() : Infinity

  if (!status) {
    return { state: 'never', lastContactAt, since: null, onlineSince: null, reader: null, needsAttention: false }
  }

  if (status === 'offline') {
    return { state: 'offline', lastContactAt, since: lastContactAt, onlineSince, reader: null, needsAttention: true }
  }

  if (status === 'ota_updating' && age <= UPDATE_STALE_AFTER_MS) {
    return { state: 'updating', lastContactAt, since: lastContactAt, onlineSince, reader: null, needsAttention: false }
  }

  // "online", "ota_success", "ota_failed" (the device is still running) and
  // any status this version does not know: trusted only while heartbeats come.
  if (status !== 'ota_updating' && age <= STALE_AFTER_MS) {
    const reader = readerStateOf(embedded.mdb_diagnostics)
    return {
      state: 'online',
      lastContactAt,
      since: onlineSince,
      onlineSince,
      reader,
      needsAttention: reader === 'inactive',
    }
  }

  return { state: 'stale', lastContactAt, since: lastContactAt, onlineSince, reader: null, needsAttention: true }
}

/** Sort key: what needs attention first, machines without a device last. */
export function connectivityRank(c: Connectivity): number {
  switch (c.state) {
    case 'offline': return 0
    case 'stale': return 1
    case 'online': return c.reader === 'inactive' ? 2 : 4
    case 'updating': return 3
    case 'never': return 5
    case 'none': return 6
  }
}

export interface FleetConnectivity {
  /** Devices that are connected: online plus updating. */
  online: number
  stale: number
  offline: number
  updating: number
  never: number
  /** Machines without a device: not counted as devices at all. */
  none: number
  /** Everything that has a device. */
  devices: number
  /** Offline, stale, or online with a silent machine. */
  attention: number
}

export function summarizeFleet(items: Connectivity[]): FleetConnectivity {
  const s: FleetConnectivity = { online: 0, stale: 0, offline: 0, updating: 0, never: 0, none: 0, devices: 0, attention: 0 }
  for (const c of items) {
    if (c.state === 'none') { s.none++; continue }
    s.devices++
    if (c.state === 'online' || c.state === 'updating') s.online++
    if (c.state === 'updating') s.updating++
    if (c.state === 'stale') s.stale++
    if (c.state === 'offline') s.offline++
    if (c.state === 'never') s.never++
    if (c.needsAttention) s.attention++
  }
  return s
}

// ─── Time labels ────────────────────────────────────────────────────────────

/** Compact elapsed time: "45 s", "12 min", "3 h 5 min", "6 d 2 h" — units come from the caller. */
export interface DurationParts { days: number; hours: number; minutes: number }

export function durationParts(ms: number): DurationParts {
  const totalMinutes = Math.max(0, Math.floor(ms / 60000))
  return {
    days: Math.floor(totalMinutes / 1440),
    hours: Math.floor((totalMinutes % 1440) / 60),
    minutes: totalMinutes % 60,
  }
}

/**
 * Wall-clock label for a past moment, as short as it can be without being
 * ambiguous: "14:32" today, "Mo 14:32" within the last 6 days, "12.10. 14:32"
 * before that (formatted for `locale`).
 */
export function formatContactClock(at: Date, now: Date | number = Date.now(), locale?: string): string {
  const nowDate = new Date(toMs(now))
  const time = at.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' })
  const startOfToday = new Date(nowDate.getFullYear(), nowDate.getMonth(), nowDate.getDate()).getTime()
  if (at.getTime() >= startOfToday) return time
  const sixDaysAgo = startOfToday - 6 * 86400000
  if (at.getTime() >= sixDaysAgo) {
    const day = at.toLocaleDateString(locale, { weekday: 'short' })
    return `${day} ${time}`
  }
  const date = at.toLocaleDateString(locale, { day: '2-digit', month: '2-digit' })
  return `${date} ${time}`
}

// ─── 24-hour history ────────────────────────────────────────────────────────

export interface StatusLogRow {
  status: string
  prev_status: string | null
  created_at: string
}

export type SegmentState = 'online' | 'offline' | 'updating' | 'unknown'

export interface StatusSegment {
  state: SegmentState
  start: number
  end: number
}

export interface StatusHistory {
  segments: StatusSegment[]
  /** Share of the known time the device was connected (online or updating), 0-100, null if nothing is known. */
  onlinePercent: number | null
  /** Offline stretches inside the window, oldest first. */
  outages: { start: number; end: number }[]
}

export function segmentStateOf(status: string | null | undefined): SegmentState {
  const s = (status ?? '').trim().toLowerCase()
  if (!s) return 'unknown'
  if (s === 'offline') return 'offline'
  if (s === 'ota_updating') return 'updating'
  return 'online'
}

/**
 * Turns the status changes of a window into contiguous segments.
 *
 * `rows` are the `embedded_status_log` rows with `created_at` inside the
 * window, in any order. The state before the first change is that row's
 * `prev_status`; without any change in the window it is the current status.
 * Adjacent segments with the same state are merged.
 */
export function buildStatusHistory(
  rows: StatusLogRow[],
  currentStatus: string | null | undefined,
  windowStart: number,
  now: number,
): StatusHistory {
  const sorted = rows
    .map(r => ({ ...r, at: new Date(r.created_at).getTime() }))
    .filter(r => !Number.isNaN(r.at) && r.at >= windowStart && r.at <= now)
    .sort((a, b) => a.at - b.at)

  const segments: StatusSegment[] = []
  const push = (state: SegmentState, start: number, end: number) => {
    if (end <= start) return
    const last = segments[segments.length - 1]
    if (last && last.state === state && last.end === start) {
      last.end = end
    } else {
      segments.push({ state, start, end })
    }
  }

  let state: SegmentState = sorted.length > 0
    ? segmentStateOf(sorted[0]!.prev_status)
    : segmentStateOf(currentStatus)
  let cursor = windowStart
  for (const row of sorted) {
    push(state, cursor, row.at)
    state = segmentStateOf(row.status)
    cursor = row.at
  }
  push(state, cursor, now)

  let known = 0
  let connected = 0
  const outages: { start: number; end: number }[] = []
  for (const seg of segments) {
    const len = seg.end - seg.start
    if (seg.state !== 'unknown') known += len
    if (seg.state === 'online' || seg.state === 'updating') connected += len
    if (seg.state === 'offline') outages.push({ start: seg.start, end: seg.end })
  }

  return {
    segments,
    onlinePercent: known > 0 ? Math.round((connected / known) * 1000) / 10 : null,
    outages,
  }
}
