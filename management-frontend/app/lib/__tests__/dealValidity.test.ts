import { describe, expect, it } from 'vitest'
import {
  compareByValidity,
  dealValidityInfo,
  groupByValidity,
  isValidToday,
  parseDealDate,
} from '../dealValidity'

// Fri 25.09.2026, mid-afternoon local time.
const NOW = new Date(2026, 8, 25, 15, 30)

describe('parseDealDate', () => {
  it('parses a DATE column value as a local calendar day, not UTC', () => {
    const d = parseDealDate('2026-09-28')!
    expect([d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()]).toEqual([2026, 8, 28, 0])
  })

  it('returns null for empty or garbage input', () => {
    expect(parseDealDate(null)).toBeNull()
    expect(parseDealDate('')).toBeNull()
    expect(parseDealDate('soon')).toBeNull()
  })
})

describe('dealValidityInfo', () => {
  it('flags a deal that starts on a later day as upcoming with the day distance', () => {
    const info = dealValidityInfo('2026-09-28', '2026-10-03', NOW)
    expect(info.status).toBe('upcoming')
    expect(info.startsInDays).toBe(3)
    expect(isValidToday(info)).toBe(false)
  })

  it('treats a deal starting today as valid today', () => {
    const info = dealValidityInfo('2026-09-25', '2026-10-03', NOW)
    expect(info.status).toBe('active')
    expect(isValidToday(info)).toBe(true)
  })

  it('detects upcoming even without an end date', () => {
    expect(dealValidityInfo('2026-09-26', null, NOW).status).toBe('upcoming')
  })

  it('marks the last day and the day before as expiring', () => {
    expect(dealValidityInfo('2026-09-20', '2026-09-25', NOW)).toMatchObject({ status: 'expiring', daysLeft: 0 })
    expect(dealValidityInfo('2026-09-20', '2026-09-27', NOW)).toMatchObject({ status: 'expiring', daysLeft: 2 })
    expect(dealValidityInfo('2026-09-20', '2026-09-28', NOW).status).toBe('active')
  })

  it('marks a past end date as expired', () => {
    expect(dealValidityInfo('2026-09-14', '2026-09-24', NOW).status).toBe('expired')
  })

  it('treats open-ended deals as active', () => {
    expect(dealValidityInfo(null, null, NOW).status).toBe('active')
  })
})

describe('compareByValidity / groupByValidity', () => {
  const deals = [
    { id: 'later', from: '2026-10-01', until: '2026-10-07' },
    { id: 'now-a', from: '2026-09-21', until: '2026-09-26' },
    { id: 'monday-1', from: '2026-09-28', until: '2026-10-03' },
    { id: 'now-b', from: null, until: null },
    { id: 'monday-2', from: '2026-09-28', until: '2026-10-03' },
  ]
  const info = (d: typeof deals[number]) => dealValidityInfo(d.from, d.until, NOW)

  it('sorts valid-now first (keeping prior order), then upcoming by start day', () => {
    const sorted = [...deals].sort((a, b) => compareByValidity(info(a), info(b)))
    expect(sorted.map((d) => d.id)).toEqual(['now-a', 'now-b', 'monday-1', 'monday-2', 'later'])
  })

  it('groups into "now" plus one section per upcoming start day', () => {
    const sections = groupByValidity(deals, info)
    expect(sections.map((s) => [s.key, s.items.map((d) => d.id)])).toEqual([
      ['now', ['now-a', 'now-b']],
      ['from:2026-09-28', ['monday-1', 'monday-2']],
      ['from:2026-10-01', ['later']],
    ])
    expect(sections[1]).toMatchObject({ kind: 'upcoming', startsInDays: 3 })
  })
})
