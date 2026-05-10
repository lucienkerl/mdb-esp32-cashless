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

const { t } = useI18n()
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
    <AnalyticsKpiGrid v-if="data" :kpis="[
      { label: t('analytics.kpi.revenue'),    value: data.kpis.revenue,        delta: pctDelta(data.kpis.revenue, data.kpis_compare?.revenue), format: 'currency' },
      { label: t('analytics.kpi.units'),      value: data.kpis.units,          delta: pctDelta(data.kpis.units,   data.kpis_compare?.units),   format: 'number' },
      { label: t('analytics.kpi.avgBasket'),  value: data.kpis.avg_basket,     delta: null, format: 'currency' },
      { label: t('analytics.kpi.conversion'), value: data.kpis.conversion_pct, delta: null, format: 'percent' },
    ]" />

    <!-- Daily series chart -->
    <AnalyticsChart v-if="data"
      :data="data.daily_series"
      x-key="date"
      y-key="revenue"
      secondary-y-key="units"
      :title="t('analytics.overview.dailySeriesTitle')"
    />

    <!-- Top products + Top machines -->
    <!-- TODO Phase 3b: handle @drill to route to product/machine detail -->
    <div class="grid gap-4 lg:grid-cols-2">
      <AnalyticsTable v-if="data"
        :rows="data.top_products"
        :columns="[
          { key: 'name',    label: t('analytics.product'),  type: 'string',   drillTo: 'product' },
          { key: 'units',   label: t('analytics.units'),    type: 'number' },
          { key: 'revenue', label: t('analytics.revenue'),  type: 'currency' },
          { key: 'mix_pct', label: t('analytics.mix'),      type: 'percent' },
        ]"
        :title="t('analytics.overview.topProducts')"
      />
      <AnalyticsTable v-if="data"
        :rows="data.top_machines"
        :columns="[
          { key: 'name',    label: t('analytics.machine'), type: 'string',   drillTo: 'machine' },
          { key: 'revenue', label: t('analytics.revenue'), type: 'currency' },
        ]"
        :title="t('analytics.overview.topMachines')"
      />
    </div>

    <!-- AI Insights — re-uses existing CompanyInsights component (claim from Task 3.7) -->
    <CompanyInsights />

    <!-- Loading / error -->
    <div v-if="loading" class="text-sm text-muted-foreground">{{ t('analytics.loading') }}</div>
    <div v-if="error" class="text-sm text-destructive">{{ error }}</div>
  </div>
</template>
