import { describe, it, expect } from 'vitest'
import { computeFilterHash, RPC_NAME_BY_TAB } from '../useAnalyticsData'
import { DEFAULT_FILTER } from '../useAnalyticsFilters'

describe('computeFilterHash', () => {
  it('produces stable hash for same filter', () => {
    const a = computeFilterHash('overview', DEFAULT_FILTER)
    const b = computeFilterHash('overview', DEFAULT_FILTER)
    expect(a).toBe(b)
  })
  it('produces different hash for different tabs', () => {
    expect(computeFilterHash('overview', DEFAULT_FILTER))
      .not.toBe(computeFilterHash('sales', DEFAULT_FILTER))
  })
  it('produces different hash when machines change', () => {
    const f1 = { ...DEFAULT_FILTER, machines: ['m1'] }
    const f2 = { ...DEFAULT_FILTER, machines: ['m2'] }
    expect(computeFilterHash('overview', f1)).not.toBe(computeFilterHash('overview', f2))
  })
  it('produces different hash when extra differs', () => {
    expect(computeFilterHash('sales', DEFAULT_FILTER, { p_dimension: 'machine' }))
      .not.toBe(computeFilterHash('sales', DEFAULT_FILTER, { p_dimension: 'product' }))
  })
})

describe('RPC_NAME_BY_TAB', () => {
  it('maps each of the 6 tabs to its RPC', () => {
    expect(RPC_NAME_BY_TAB.overview).toBe('analytics_overview')
    expect(RPC_NAME_BY_TAB.sales).toBe('analytics_sales_breakdown')
    expect(RPC_NAME_BY_TAB.products).toBe('analytics_products')
    expect(RPC_NAME_BY_TAB.machines).toBe('analytics_machines')
    expect(RPC_NAME_BY_TAB.conversion).toBe('analytics_conversion')
    expect(RPC_NAME_BY_TAB.operations).toBe('analytics_operations')
  })
})
