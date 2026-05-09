import { describe, it, expect, beforeEach } from 'vitest'
import { useAnalyticsFilters, serializeFilter, deserializeFilter, DEFAULT_FILTER } from '../useAnalyticsFilters'

describe('serializeFilter / deserializeFilter', () => {
  it('round-trips a default filter', () => {
    const enc = serializeFilter(DEFAULT_FILTER)
    expect(typeof enc).toBe('string')
    const dec = deserializeFilter(enc)
    expect(dec.from).toBe(DEFAULT_FILTER.from)
    expect(dec.to).toBe(DEFAULT_FILTER.to)
    expect(dec.machines).toEqual([])
  })

  it('drops unknown keys silently', () => {
    const future = { ...DEFAULT_FILTER, somethingNew: 'x', anotherFutureKey: [1, 2] } as any
    const enc = serializeFilter(future)
    const dec = deserializeFilter(enc)
    expect((dec as any).somethingNew).toBeUndefined()
    expect((dec as any).anotherFutureKey).toBeUndefined()
  })

  it('clamps v to current schema (1) when older URL is loaded', () => {
    const olderEncoded = serializeFilter({ ...DEFAULT_FILTER, v: 99 } as any)
    const dec = deserializeFilter(olderEncoded)
    expect(dec.v).toBe(1)
  })

  it('returns DEFAULT_FILTER when given malformed input', () => {
    const dec = deserializeFilter('not-a-real-base64url-string')
    expect(dec).toEqual(DEFAULT_FILTER)
  })
})
