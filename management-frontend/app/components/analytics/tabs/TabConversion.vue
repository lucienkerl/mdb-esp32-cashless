<!--
  TabConversion
  -------------
  Conversion analytics workbench for the Analytics dashboard (Task 4.4 / Phase 4).

  Layout:
    1. KPI grid (footfall, conversion %, empty passes, avg revenue/visitor)
       + a compact "Best machine: <name>" label below the grid since the name
       doesn't fit AnalyticsKpiGrid's numeric-value contract.
    2. Machines × hour heatmap — top 10 machines by sales count, each as a
       row of 24 cells colored by conversion_pct. Custom inline grid (the
       shared AnalyticsHeatmap is single-row only). Empty hours render gray.
    3. Traffic vs sales scatter (pax on x, sales on y, one dot per machine),
       via AnalyticsChart with chartType='scatter'.
    4. Daily conversion trend — bar chart of conversion_pct over time.
    5. Per-machine table with drill-through on the machine name.

  Data source: analytics_conversion RPC (see Chunk 2 migration). Returns
  { kpis, machines[], hour_heatmap: { <machine_id>: number[24] },
    daily_conversion_series[] }. We fetch once per filter-change and slice
  locally.
-->
<script setup lang="ts">
import { ref, watch, computed, onMounted } from 'vue'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'
import { useAnalyticsData } from '@/composables/useAnalyticsData'
import { useOrganization } from '@/composables/useOrganization'

const { t } = useI18n()

interface ConversionMachine {
  id: string
  name: string
  pax: number
  sales: number
  conversion_pct: number
  revenue_per_visitor: number | null
}

interface ConversionResponse {
  version: number
  kpis: {
    footfall: number
    conversion_pct: number | null
    best_machine_id: string | null
    empty_passes: number
  }
  machines: ConversionMachine[]
  hour_heatmap: Record<string, number[]>
  daily_conversion_series: { date: string; conversion_pct: number | null }[]
}

const { filter } = useAnalyticsFilters()
const { fetch, loading, error } = useAnalyticsData()
const { organization } = useOrganization()

const data = ref<ConversionResponse | null>(null)

async function load() {
  if (!organization.value?.id) return
  data.value = (await fetch('conversion', filter.value, organization.value.id)) as
    | ConversionResponse
    | null
}

onMounted(load)
watch(filter, load, { deep: true })

// Resolve best-machine UUID -> display name. RPC returns the id only; we
// look it up in machines[] so the badge can render a human-readable name.
const bestMachineName = computed<string | null>(() => {
  const id = data.value?.kpis?.best_machine_id
  if (!id) return null
  return data.value?.machines?.find((m) => m.id === id)?.name ?? null
})

// Avg revenue per visitor across the fleet. Weighted by pax (so a machine
// with 10× the footfall counts 10× as much) — a plain mean would over-
// weight low-traffic machines that happen to score one big sale.
const avgRevenuePerVisitor = computed<number>(() => {
  const ms = data.value?.machines ?? []
  let totalPax = 0
  let totalRevenue = 0
  for (const m of ms) {
    const pax = Number(m.pax ?? 0)
    const rpv = m.revenue_per_visitor == null ? null : Number(m.revenue_per_visitor)
    if (pax > 0 && rpv != null) {
      totalPax += pax
      totalRevenue += rpv * pax
    }
  }
  return totalPax > 0 ? totalRevenue / totalPax : 0
})

// Scatter input: pax (x) vs sales (y) per machine. Label is the machine
// name so the SVG <title> tooltip on each dot reads as "<name>: pax/sales".
const scatterData = computed(() =>
  (data.value?.machines ?? []).map((m) => ({
    label: m.name,
    pax: Number(m.pax ?? 0),
    sales: Number(m.sales ?? 0),
  })),
)

// Top 10 machines by sales for the heatmap. Capping prevents the strip
// stack from overflowing on fleets with 50+ machines, where each row
// would compress to a single-pixel column.
const topMachinesForHeatmap = computed<ConversionMachine[]>(() => {
  const ms = data.value?.machines ?? []
  return [...ms].sort((a, b) => Number(b.sales ?? 0) - Number(a.sales ?? 0)).slice(0, 10)
})

// Heatmap cell style: gray for null (no pax that hour), green-shaded by
// conversion_pct otherwise. Saturate at 50% conversion — anything above
// reads as "fully saturated" since fleet averages typically sit < 10%.
function heatmapCellStyle(conv: number | null): Record<string, string> {
  if (conv == null) return { backgroundColor: 'rgba(156, 163, 175, 0.1)' }
  const t = Math.min(1, conv / 50)
  return { backgroundColor: `rgba(34, 197, 94, ${0.15 + t * 0.65})` }
}

function heatmapCellTitle(machineName: string, hour: number, conv: number | null): string {
  const hh = String(hour).padStart(2, '0') + ':00'
  if (conv == null) return t('analytics.heatmapNoPax', { machine: machineName, hour: hh })
  return t('analytics.heatmapWithConv', { machine: machineName, hour: hh, conv: conv.toFixed(1) + '%' })
}

function hourArrayFor(machineId: string): (number | null)[] {
  const arr = data.value?.hour_heatmap?.[machineId]
  if (!arr || !Array.isArray(arr)) {
    return Array<number | null>(24).fill(null)
  }
  // Server returns a number[24] (0 when no pax). The plan describes "null
  // if no pax that hour" but the RPC currently coerces to 0 — we surface
  // them identically (both render as the lightest gray cell).
  return arr.map((v) => (v == null ? null : Number(v)))
}

// Drill-through: clicking a machine name in the per-machine table
// scopes the filter to that machine, mirroring TabSales behaviour.
function onDrill(payload: { type: string; value: any; row: Record<string, any> }) {
  const key = payload.row?.id
  if (key == null) return
  if (payload.type === 'machine') {
    filter.value.machines = [String(key)]
  }
}
</script>

<template>
  <div class="flex flex-col gap-4" data-testid="analytics-tab-conversion">
    <!-- KPI Grid -->
    <AnalyticsKpiGrid
      v-if="data"
      :kpis="[
        { label: t('analytics.kpi.footfall'),             value: data.kpis.footfall,                   format: 'number' },
        { label: t('analytics.kpi.conversion'),           value: data.kpis.conversion_pct ?? 0,        format: 'percent' },
        { label: t('analytics.kpi.emptyPasses'),          value: data.kpis.empty_passes,               format: 'number' },
        { label: t('analytics.kpi.avgRevenuePerVisitor'), value: avgRevenuePerVisitor,                 format: 'currency' },
      ]"
    />
    <div
      v-if="bestMachineName"
      class="text-xs text-muted-foreground"
      data-testid="analytics-conversion-best-label"
    >
      {{ t('analytics.kpi.bestRevenue') }}: <span class="font-medium text-foreground">{{ bestMachineName }}</span>
    </div>

    <!-- Machines × hour heatmap (top 10 by sales) -->
    <div
      v-if="data && topMachinesForHeatmap.length"
      class="rounded-xl border bg-card p-4"
      data-testid="analytics-conversion-heatmap"
    >
      <h3 class="mb-3 text-sm font-medium">
        {{ t('analytics.heatmapByMachineHour') }}
      </h3>
      <div class="space-y-1">
        <div
          v-for="m in topMachinesForHeatmap"
          :key="m.id"
          class="grid items-center gap-2"
          :style="{ gridTemplateColumns: '8rem 1fr' }"
        >
          <div class="truncate text-xs" :title="m.name">{{ m.name }}</div>
          <div
            class="grid gap-px"
            :style="{ gridTemplateColumns: 'repeat(24, minmax(0, 1fr))' }"
          >
            <div
              v-for="(conv, h) in hourArrayFor(m.id)"
              :key="h"
              class="aspect-square rounded-sm border"
              :style="heatmapCellStyle(conv)"
              :title="heatmapCellTitle(m.name, h, conv)"
            />
          </div>
        </div>
      </div>
    </div>

    <!-- Traffic vs sales scatter -->
    <!-- TODO Phase 4b: diagonal reference line y = avgConv * x for "fleet-avg conversion" overlay -->
    <AnalyticsChart
      v-if="data"
      chart-type="scatter"
      :data="scatterData"
      x-key="pax"
      y-key="sales"
      :title="t('analytics.scatterTitle')"
      :description="t('analytics.scatterDescription')"
    />

    <!-- Daily conversion trend -->
    <AnalyticsChart
      v-if="data && data.daily_conversion_series?.length"
      :data="data.daily_conversion_series"
      x-key="date"
      y-key="conversion_pct"
      :title="t('analytics.dailyTrend')"
    />

    <!-- Per-machine table -->
    <AnalyticsTable
      v-if="data?.machines?.length"
      :rows="data.machines"
      :columns="[
        { key: 'name',                label: t('analytics.machine'),            type: 'string',   drillTo: 'machine' },
        { key: 'pax',                 label: t('analytics.kpi.footfall'),       type: 'number' },
        { key: 'sales',               label: t('analytics.sales'),              type: 'number' },
        { key: 'conversion_pct',      label: t('analytics.conversion'),         type: 'percent' },
        { key: 'revenue_per_visitor', label: t('analytics.revenuePerVisitor'),  type: 'currency' },
      ]"
      @drill="onDrill"
    />

    <!-- Empty state -->
    <div
      v-else-if="data && !loading"
      class="rounded-xl border border-dashed bg-muted/30 p-12 text-center text-sm text-muted-foreground"
    >
      {{ t('analytics.noMachinesMatch') }}
    </div>

    <!-- Loading / error -->
    <div v-if="loading" class="text-sm text-muted-foreground">{{ t('analytics.loading') }}</div>
    <div v-if="error" class="text-sm text-destructive">{{ error }}</div>
  </div>
</template>
