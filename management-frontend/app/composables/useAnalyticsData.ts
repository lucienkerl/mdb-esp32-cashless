import { ref } from 'vue'
import { useSupabaseClient } from '#imports'
import type { AnalyticsFilter } from './useAnalyticsFilters'

export type AnalyticsTab = 'overview' | 'sales' | 'products' | 'machines' | 'conversion' | 'operations'

export const RPC_NAME_BY_TAB: Record<AnalyticsTab, string> = {
  overview:   'analytics_overview',
  sales:      'analytics_sales_breakdown',
  products:   'analytics_products',
  machines:   'analytics_machines',
  conversion: 'analytics_conversion',
  operations: 'analytics_operations',
}

export function computeFilterHash(tab: AnalyticsTab, f: AnalyticsFilter): string {
  return JSON.stringify([tab, f])
}

interface CacheEntry { at: number; data: any }
const CACHE_TTL_MS = 30_000

export function useAnalyticsData() {
  const cache = new Map<string, CacheEntry>()
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetch(
    tab: AnalyticsTab,
    filter: AnalyticsFilter,
    companyId: string,
    extra: Record<string, unknown> = {}
  ) {
    const key = computeFilterHash(tab, filter)
    const cached = cache.get(key)
    if (cached && Date.now() - cached.at < CACHE_TTL_MS) return cached.data

    loading.value = true
    error.value = null
    try {
      const supabase = useSupabaseClient()
      const params: Record<string, unknown> = {
        p_company_id:    companyId,
        p_from:          filter.from,
        p_to:            filter.to,
        p_compare_from:  filter.compare ? null /* TODO compute compare window */ : null,
        p_compare_to:    null,
        p_machine_ids:   filter.machines,
        p_channels:      filter.channels,
        p_category_ids:  filter.categories,
        p_vat_rates:     filter.vatRates,
        ...extra,
      }
      const { data, error: rpcError } = await (supabase as any).rpc(RPC_NAME_BY_TAB[tab], params)
      if (rpcError) throw rpcError
      cache.set(key, { at: Date.now(), data })
      return data
    } catch (e: any) {
      error.value = e?.message ?? String(e)
      throw e
    } finally {
      loading.value = false
    }
  }

  function invalidate() { cache.clear() }

  return { fetch, loading, error, invalidate }
}
