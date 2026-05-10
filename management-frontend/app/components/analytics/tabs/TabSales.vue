<!--
  TabSales
  --------
  Sales-breakdown workbench for the Analytics dashboard (Task 4.1 / Phase 4).

  Layout:
    1. KPI grid (revenue, units, avg basket, sales count)
    2. Dimension switcher: pills for machine | product | category | channel |
       vat | hour | dow
    3. Visualization: AnalyticsHeatmap for hour/dow, AnalyticsChart otherwise
    4. Sortable breakdown table with drill-through on the label column

  Data source: analytics_sales_breakdown RPC (see Chunk 2 migration). The RPC
  returns per-row { key, label, revenue, units, avg_basket, count,
  share_revenue_pct, share_units_pct }. `key` carries the UUID/string/int
  needed to drill back into the filter — `label` is for display only.

  Drill semantics: AnalyticsTable emits { type, value, row } on label-cell
  clicks. We dispatch on `row.key` (UUID for machine/category, channel
  string, numeric vat rate) so filter values match the RPC's expected
  identifier types, not the rendered display string.
-->
<script setup lang="ts">
import { ref, watch, computed, onMounted } from 'vue'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'
import { useAnalyticsData } from '@/composables/useAnalyticsData'
import { useOrganization } from '@/composables/useOrganization'

const { t } = useI18n()
const { filter } = useAnalyticsFilters()
const { fetch, loading, error } = useAnalyticsData()
const { organization } = useOrganization()

type Dimension = 'machine' | 'product' | 'category' | 'channel' | 'vat' | 'hour' | 'dow'
const DIMENSIONS: readonly Dimension[] = ['machine', 'product', 'category', 'channel', 'vat', 'hour', 'dow'] as const

const dimension = ref<Dimension>('machine')
const data = ref<any>(null)

async function load() {
  if (!organization.value?.id) return
  data.value = await fetch('sales', filter.value, organization.value.id, { p_dimension: dimension.value })
}

onMounted(load)
watch([filter, dimension], load, { deep: true })

const isHeatmap = computed(() => dimension.value === 'hour' || dimension.value === 'dow')

const totalRevenue = computed(() =>
  data.value?.rows?.reduce((s: number, r: any) => s + (Number(r.revenue) || 0), 0) ?? 0,
)
const totalUnits = computed(() =>
  data.value?.rows?.reduce((s: number, r: any) => s + (Number(r.units) || 0), 0) ?? 0,
)
const avgBasket = computed(() => (totalUnits.value > 0 ? totalRevenue.value / totalUnits.value : 0))
const salesCount = computed(() =>
  data.value?.rows?.reduce((s: number, r: any) => s + (Number(r.count) || 0), 0) ?? 0,
)

// Drill column type — only emit a clickable label when filtering on that
// dimension is supported by useAnalyticsFilters. Hour / dow / product are
// not yet exposed through the filter shape, so they stay non-drillable.
const labelDrillTo = computed<'machine' | 'product' | 'category' | undefined>(() => {
  if (dimension.value === 'machine') return 'machine'
  if (dimension.value === 'product') return 'product'
  if (dimension.value === 'category') return 'category'
  return undefined
})

function onDrill(payload: { type: string; value: any; row: Record<string, any> }) {
  // Use row.key (UUID/identifier) rather than row.label (display string) so
  // filter values match what the RPC expects.
  const key = payload.row?.key
  if (key == null) return
  if (dimension.value === 'machine') {
    filter.value.machines = [String(key)]
  } else if (dimension.value === 'product') {
    // TODO Phase 3b: add product filter to useAnalyticsFilters / RPC param.
  } else if (dimension.value === 'category') {
    filter.value.categories = [String(key)]
  } else if (dimension.value === 'channel') {
    filter.value.channels = [String(key)]
  } else if (dimension.value === 'vat') {
    const n = Number(key)
    if (!Number.isNaN(n)) filter.value.vatRates = [n]
  }
}
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- KPI Grid -->
    <AnalyticsKpiGrid
      v-if="data"
      :kpis="[
        { label: t('analytics.kpi.revenue'),    value: totalRevenue, format: 'currency' },
        { label: t('analytics.kpi.units'),      value: totalUnits,   format: 'number' },
        { label: t('analytics.kpi.avgBasket'),  value: avgBasket,    format: 'currency' },
        { label: t('analytics.kpi.salesCount'), value: salesCount,   format: 'number' },
      ]"
    />

    <!-- Dimension switcher -->
    <div class="flex flex-wrap gap-2" data-testid="analytics-sales-dimension-switcher">
      <button
        v-for="d in DIMENSIONS"
        :key="d"
        type="button"
        class="rounded-full border px-3 py-1 text-xs font-medium transition-colors"
        :class="dimension === d ? 'bg-primary text-primary-foreground border-primary' : 'hover:bg-muted'"
        @click="dimension = d"
      >
        {{ t('analytics.dimension.' + d) }}
      </button>
    </div>

    <!-- Heatmap (hour/dow) OR bar chart (other dimensions) -->
    <AnalyticsHeatmap
      v-if="data && isHeatmap"
      :rows="data.rows"
      :dimension="(dimension as 'hour' | 'dow')"
    />
    <AnalyticsChart
      v-else-if="data"
      :data="data.rows"
      x-key="label"
      y-key="revenue"
      :title="t('analytics.sales.byDimension', { dim: t('analytics.dimension.' + dimension) })"
    />

    <!-- Breakdown table -->
    <AnalyticsTable
      v-if="data"
      :rows="data.rows"
      :columns="[
        { key: 'label',             label: t('analytics.label'),        type: 'string',   drillTo: labelDrillTo },
        { key: 'revenue',           label: t('analytics.revenue'),      type: 'currency' },
        { key: 'units',             label: t('analytics.units'),        type: 'number' },
        { key: 'avg_basket',        label: t('analytics.avgBasket'),    type: 'currency' },
        { key: 'share_revenue_pct', label: t('analytics.shareRevenue'), type: 'percent' },
        { key: 'share_units_pct',   label: t('analytics.shareUnits'),   type: 'percent' },
      ]"
      @drill="onDrill"
    />

    <!-- Loading / error -->
    <div v-if="loading" class="text-sm text-muted-foreground">{{ t('analytics.loading') }}</div>
    <div v-if="error" class="text-sm text-destructive">{{ error }}</div>
  </div>
</template>
