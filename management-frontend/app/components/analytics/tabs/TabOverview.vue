<!--
  TabOverview
  -----------
  Overview tab for the Analytics dashboard (Task 3.8 / Phase 3a).

  Layout:
    1. KPI grid (revenue, units, avg basket, conversion %)
    2. Daily series chart (revenue + units over time)
    3. Top products + top machines tables (side-by-side on lg+)
    4. AI insights (CompanyInsights, re-used from existing component)

  Data source: analytics_overview RPC (see useAnalyticsData / Chunk 2 migration).
-->
<script setup lang="ts">
import { ref, watch, onMounted } from 'vue'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'
import { useAnalyticsData } from '@/composables/useAnalyticsData'
import { useOrganization } from '@/composables/useOrganization'
import CompanyInsights from '@/components/CompanyInsights.vue'

const { filter } = useAnalyticsFilters()
const { fetch, loading, error } = useAnalyticsData()
const { organization } = useOrganization()
const data = ref<any>(null)

// Guarded percentage delta — null when prev is missing or zero (no division-by-zero spikes).
function pctDelta(curr: number, prev: number | null | undefined): number | null {
  if (prev == null || prev === 0) return null
  return ((curr - prev) / prev) * 100
}

async function load() {
  if (!organization.value?.id) return
  data.value = await fetch('overview', filter.value, organization.value.id)
}

onMounted(load)
watch(filter, load, { deep: true })
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- KPI Grid -->
    <!-- TODO i18n: KPI labels hardcoded; add analytics.kpi.* keys -->
    <AnalyticsKpiGrid v-if="data" :kpis="[
      { label: 'Revenue',    value: data.kpis.revenue,        delta: pctDelta(data.kpis.revenue, data.kpis_compare?.revenue), format: 'currency' },
      { label: 'Units',      value: data.kpis.units,          delta: pctDelta(data.kpis.units,   data.kpis_compare?.units),   format: 'number' },
      { label: 'Avg basket', value: data.kpis.avg_basket,     delta: null, format: 'currency' },
      { label: 'Conversion', value: data.kpis.conversion_pct, delta: null, format: 'percent' },
    ]" />

    <!-- Daily series chart -->
    <!-- TODO i18n: chart title hardcoded; add analytics.overview.dailySeriesTitle -->
    <AnalyticsChart v-if="data"
      :data="data.daily_series"
      x-key="date"
      y-key="revenue"
      secondary-y-key="units"
      title="Daily revenue & units"
    />

    <!-- Top products + Top machines -->
    <!-- TODO Phase 3b: handle @drill to route to product/machine detail -->
    <div class="grid gap-4 lg:grid-cols-2">
      <!-- TODO i18n: column labels + table title hardcoded -->
      <AnalyticsTable v-if="data"
        :rows="data.top_products"
        :columns="[
          { key: 'name',    label: 'Product', type: 'string',   drillTo: 'product' },
          { key: 'units',   label: 'Units',   type: 'number' },
          { key: 'revenue', label: 'Revenue', type: 'currency' },
          { key: 'mix_pct', label: 'Mix',     type: 'percent' },
        ]"
        title="Top products"
      />
      <!-- TODO i18n: column labels + table title hardcoded -->
      <AnalyticsTable v-if="data"
        :rows="data.top_machines"
        :columns="[
          { key: 'name',    label: 'Machine', type: 'string',   drillTo: 'machine' },
          { key: 'revenue', label: 'Revenue', type: 'currency' },
        ]"
        title="Top machines"
      />
    </div>

    <!-- AI Insights — re-uses existing CompanyInsights component (claim from Task 3.7) -->
    <CompanyInsights />

    <!-- Loading / error -->
    <!-- TODO i18n: status strings hardcoded -->
    <div v-if="loading" class="text-sm text-muted-foreground">Loading…</div>
    <div v-if="error" class="text-sm text-destructive">{{ error }}</div>
  </div>
</template>
