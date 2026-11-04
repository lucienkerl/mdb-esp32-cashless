import { describe, it, expect } from 'vitest'
import {
  buildStatusHistory,
  connectivityRank,
  deviceConnectivity,
  durationParts,
  formatContactClock,
  readerStateOf,
  summarizeFleet,
} from '../connectivity'

// The same cases are mirrored in the iOS and Android ports.
const NOW = new Date('2026-11-04T16:00:00Z').getTime()
const minAgo = (m: number) => new Date(NOW - m * 60000).toISOString()

describe('deviceConnectivity', () => {
  it('is none for a machine without a device', () => {
    const c = deviceConnectivity(null, NOW)
    expect(c.state).toBe('none')
    expect(c.needsAttention).toBe(false)
  })

  it('is never for a device that has not reported any status', () => {
    expect(deviceConnectivity({ status: null, status_at: null }, NOW).state).toBe('never')
    expect(deviceConnectivity({ status: '', status_at: minAgo(1) }, NOW).state).toBe('never')
  })

  it('is online while heartbeats arrive', () => {
    const c = deviceConnectivity({ status: 'online', status_at: minAgo(2), online_since: minAgo(600) }, NOW)
    expect(c.state).toBe('online')
    expect(c.lastContactAt?.toISOString()).toBe(minAgo(2))
    expect(c.since?.toISOString()).toBe(minAgo(600))
    expect(c.needsAttention).toBe(false)
  })

  it('survives one lost heartbeat (5 min interval) without flipping', () => {
    expect(deviceConnectivity({ status: 'online', status_at: minAgo(10) }, NOW).state).toBe('online')
    expect(deviceConnectivity({ status: 'online', status_at: minAgo(12) }, NOW).state).toBe('online')
  })

  it('is stale when online but silent for more than 12 minutes', () => {
    const c = deviceConnectivity({ status: 'online', status_at: minAgo(13) }, NOW)
    expect(c.state).toBe('stale')
    expect(c.since?.toISOString()).toBe(minAgo(13))
    expect(c.needsAttention).toBe(true)
  })

  it('is stale when online without any status_at', () => {
    expect(deviceConnectivity({ status: 'online', status_at: null }, NOW).state).toBe('stale')
  })

  it('is offline with the time the drop was noticed', () => {
    const c = deviceConnectivity({ status: 'offline', status_at: minAgo(120), online_since: minAgo(9000) }, NOW)
    expect(c.state).toBe('offline')
    expect(c.since?.toISOString()).toBe(minAgo(120))
    expect(c.onlineSince?.toISOString()).toBe(minAgo(9000))
    expect(c.needsAttention).toBe(true)
  })

  it('treats offline case-insensitively and never as online', () => {
    expect(deviceConnectivity({ status: 'OFFLINE', status_at: minAgo(1) }, NOW).state).toBe('offline')
  })

  it('is updating for a fresh update and stale once it hangs', () => {
    expect(deviceConnectivity({ status: 'ota_updating', status_at: minAgo(3) }, NOW).state).toBe('updating')
    expect(deviceConnectivity({ status: 'ota_updating', status_at: minAgo(11) }, NOW).state).toBe('stale')
  })

  it('counts the finished or failed update states as online (the device keeps running)', () => {
    expect(deviceConnectivity({ status: 'ota_success', status_at: minAgo(1) }, NOW).state).toBe('online')
    expect(deviceConnectivity({ status: 'ota_failed', status_at: minAgo(1) }, NOW).state).toBe('online')
  })

  it('reports the reader state only while online', () => {
    const ready = deviceConnectivity({ status: 'online', status_at: minAgo(1), mdb_diagnostics: { state: 'IDLE' } }, NOW)
    expect(ready.reader).toBe('ready')
    expect(ready.needsAttention).toBe(false)

    const silent = deviceConnectivity({ status: 'online', status_at: minAgo(1), mdb_diagnostics: { state: 'INACTIVE' } }, NOW)
    expect(silent.reader).toBe('inactive')
    expect(silent.needsAttention).toBe(true)

    const off = deviceConnectivity({ status: 'offline', status_at: minAgo(1), mdb_diagnostics: { state: 'IDLE' } }, NOW)
    expect(off.reader).toBeNull()
  })
})

describe('readerStateOf', () => {
  it('maps the MDB states', () => {
    expect(readerStateOf({ state: 'ENABLED' })).toBe('ready')
    expect(readerStateOf({ state: 'VEND' })).toBe('ready')
    expect(readerStateOf({ state: 'DISABLED' })).toBe('disabled')
    expect(readerStateOf({ state: 'INACTIVE' })).toBe('inactive')
    expect(readerStateOf({ state: 'UNKNOWN' })).toBeNull()
    expect(readerStateOf(null)).toBeNull()
    expect(readerStateOf({})).toBeNull()
  })
})

describe('summarizeFleet', () => {
  it('counts devices and leaves machines without a device out', () => {
    const s = summarizeFleet([
      deviceConnectivity({ status: 'online', status_at: minAgo(1) }, NOW),
      deviceConnectivity({ status: 'online', status_at: minAgo(1), mdb_diagnostics: { state: 'INACTIVE' } }, NOW),
      deviceConnectivity({ status: 'ota_updating', status_at: minAgo(1) }, NOW),
      deviceConnectivity({ status: 'online', status_at: minAgo(47) }, NOW),
      deviceConnectivity({ status: 'offline', status_at: minAgo(120) }, NOW),
      deviceConnectivity({ status: null }, NOW),
      deviceConnectivity(null, NOW),
    ])
    expect(s).toEqual({ online: 3, stale: 1, offline: 1, updating: 1, never: 1, none: 1, devices: 6, attention: 3 })
  })
})

describe('connectivityRank', () => {
  it('sorts problems first and machines without a device last', () => {
    const list = [
      deviceConnectivity(null, NOW),
      deviceConnectivity({ status: 'online', status_at: minAgo(1) }, NOW),
      deviceConnectivity({ status: 'offline', status_at: minAgo(1) }, NOW),
      deviceConnectivity({ status: 'online', status_at: minAgo(30) }, NOW),
      deviceConnectivity({ status: 'online', status_at: minAgo(1), mdb_diagnostics: { state: 'INACTIVE' } }, NOW),
    ]
    const ordered = [...list].sort((a, b) => connectivityRank(a) - connectivityRank(b)).map(c => `${c.state}:${c.reader ?? ''}`)
    expect(ordered).toEqual(['offline:', 'stale:', 'online:inactive', 'online:', 'none:'])
  })
})

describe('durationParts', () => {
  it('splits into days, hours and minutes', () => {
    expect(durationParts((3 * 1440 + 4 * 60 + 5) * 60000)).toEqual({ days: 3, hours: 4, minutes: 5 })
    expect(durationParts(59_000)).toEqual({ days: 0, hours: 0, minutes: 0 })
    expect(durationParts(-5000)).toEqual({ days: 0, hours: 0, minutes: 0 })
  })
})

describe('formatContactClock', () => {
  // Local-time construction so the test is independent of the runner's zone.
  const now = new Date(2026, 10, 4, 16, 0)

  it('shows only the time for today', () => {
    expect(formatContactClock(new Date(2026, 10, 4, 14, 32), now, 'de-DE')).toBe('14:32')
  })

  it('adds the weekday within the last six days', () => {
    expect(formatContactClock(new Date(2026, 10, 2, 14, 32), now, 'de-DE')).toMatch(/^Mo\.? 14:32$/) // ICU versions differ on the dot
  })

  it('adds the date before that', () => {
    expect(formatContactClock(new Date(2026, 9, 12, 9, 5), now, 'de-DE')).toBe('12.10. 09:05')
  })
})

describe('buildStatusHistory', () => {
  const H = 3600000
  const start = NOW - 24 * H
  const at = (h: number) => new Date(start + h * H).toISOString()

  it('is one segment of the current status without changes', () => {
    const h = buildStatusHistory([], 'online', start, NOW)
    expect(h.segments).toEqual([{ state: 'online', start, end: NOW }])
    expect(h.onlinePercent).toBe(100)
    expect(h.outages).toEqual([])
  })

  it('starts from the first change\'s previous status and splits at every change', () => {
    const h = buildStatusHistory([
      { status: 'online', prev_status: 'offline', created_at: at(12.75) },
      { status: 'offline', prev_status: 'online', created_at: at(12) },
      { status: 'ota_updating', prev_status: 'online', created_at: at(18) },
      { status: 'online', prev_status: 'ota_updating', created_at: at(18.25) },
    ], 'online', start, NOW)
    expect(h.segments.map(s => s.state)).toEqual(['online', 'offline', 'online', 'updating', 'online'])
    expect(h.outages).toEqual([{ start: start + 12 * H, end: start + 12.75 * H }])
    expect(h.onlinePercent).toBe(96.9)
  })

  it('merges repeated states and leaves the unknown time out of the percentage', () => {
    const h = buildStatusHistory([
      { status: 'online', prev_status: null, created_at: at(12) },
      { status: 'ota_success', prev_status: 'online', created_at: at(13) },
    ], 'ota_success', start, NOW)
    expect(h.segments).toEqual([
      { state: 'unknown', start, end: start + 12 * H },
      { state: 'online', start: start + 12 * H, end: NOW },
    ])
    expect(h.onlinePercent).toBe(100)
  })

  it('ignores rows outside the window', () => {
    const h = buildStatusHistory([
      { status: 'offline', prev_status: 'online', created_at: new Date(start - H).toISOString() },
    ], 'offline', start, NOW)
    expect(h.segments).toEqual([{ state: 'offline', start, end: NOW }])
    expect(h.onlinePercent).toBe(0)
  })
})
