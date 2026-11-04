/**
 * I/O test of a WROOM-1U board (machine detail, "I/O test" tab).
 *
 * The firmware publishes a snapshot on `/{company}/{device}/io` while a test
 * runs (config cmd 0x36); mqtt-webhook stores the latest one in
 * `embeddeds.io_state` and the page follows it through realtime. These are the
 * pure helpers behind the panel.
 */

export interface OneWireDevice {
  /** 64-bit ROM id, 16 hex digits. The low byte is the family (0x28 = DS18B20). */
  id: string
  /** °C, missing for a device that is not a DS18B20 or could not be read. */
  t?: number
}

export interface IoState {
  active: boolean
  /** Seconds the test still runs, as of `updated_at`. */
  left: number
  /** Custom inputs 1..3: 1 = high (open, pulled up), 0 = low (closed to GND). */
  in: number[]
  /** Relays 1..2 as last commanded: 1 = on. */
  relay: number[]
  /** Onboard NTC, °C. */
  ntc?: number
  /** Devices per 1-Wire bus (bus 1 = GPIO15, bus 2 = GPIO16); missing before the first scan. */
  ow?: OneWireDevice[][]
  updated_at?: string
}

export type IoTestStatus = 'live' | 'waiting' | 'idle'

/** Mirrors IO_TEST_MAX_SECONDS in the firmware and send-device-config. */
export const IO_TEST_MAX_SECONDS = 600
/** The device publishes at least every 5 s while a test runs. */
export const IO_STALE_MS = 12_000

/** Only the WROOM-1U board has relays, custom inputs and 1-Wire buses. */
export function isWroomBoard(diagnostics: unknown): boolean {
  return (diagnostics as { board?: unknown } | null | undefined)?.board === 'wroom-1u'
}

function updatedAtMs(state: IoState | null | undefined): number | null {
  if (!state?.updated_at) return null
  const ms = Date.parse(state.updated_at)
  return Number.isNaN(ms) ? null : ms
}

/** A snapshot from a running test that is recent enough to trust. */
export function isLive(state: IoState | null | undefined, now: number): boolean {
  const at = updatedAtMs(state)
  return !!state?.active && at !== null && now - at < IO_STALE_MS
}

/** Seconds left in the running test, counted down locally from the last snapshot. */
export function remainingSeconds(state: IoState | null | undefined, now: number): number {
  const at = updatedAtMs(state)
  if (!state?.active || at === null) return 0
  return Math.max(0, Math.ceil(state.left - (now - at) / 1000))
}

/**
 * live    — snapshots are arriving
 * waiting — a test was just requested and nothing arrived yet
 * idle    — no test
 */
export function ioTestStatus(state: IoState | null | undefined, now: number, requestedAt: number | null): IoTestStatus {
  if (isLive(state, now) && remainingSeconds(state, now) > 0) return 'live'
  if (requestedAt !== null && now - requestedAt < IO_STALE_MS) {
    // A snapshot newer than the request means the device answered (and
    // possibly already ended the test).
    const at = updatedAtMs(state)
    if (at === null || at < requestedAt) return 'waiting'
  }
  return 'idle'
}

/** Adds the input level changes between two snapshots to `counts` (one per input). */
export function countInputChanges(prev: number[] | undefined, next: number[] | undefined, counts: number[]): number[] {
  if (!prev || !next) return counts
  return counts.map((c, i) => (prev[i] !== undefined && next[i] !== undefined && prev[i] !== next[i] ? c + 1 : c))
}

/** 1-Wire family byte → a short label for the known ones. */
export function oneWireFamily(id: string): string | null {
  const family = id.slice(-2).toUpperCase()
  return ({ '28': 'DS18B20', '10': 'DS18S20', '22': 'DS1822', '01': 'DS2401' } as Record<string, string>)[family] ?? null
}

export function formatClockSeconds(s: number): string {
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}
