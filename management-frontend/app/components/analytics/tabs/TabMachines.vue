<!--
  TabMachines
  -----------
  Machine-fleet workbench for the Analytics dashboard (Task 4.3 / Phase 4).

  Layout:
    1. KPI grid (active count / best revenue / avg conversion / stockout hours)
       + a compact "Best machine: <name>" label below the grid since the name
       doesn't fit AnalyticsKpiGrid's numeric-value contract.
    2. Toggle row: "Show map", "Show heatmaps", and the Compare button (which
       is disabled until 2-4 machines are checked).
    3. AnalyticsGeoMap — bubble map of all machines with coords, revenue
       drives radius, conversion-percentile drives color.
    4. Responsive machine card grid. Each card shows status badge, revenue,
       units, conversion %, last-sale freshness, a Compare checkbox, and an
       optional inline hour heatmap (when "Show heatmaps" is on).
    5. AnalyticsCompareSheet — side-panel with 2-4 selected machines.

  Data source: analytics_machines RPC (see Chunk 2 migration). Returns
  { kpis, machines[], heatmaps: { <id>: { dow, hour } } }. We fetch once
  per filter-change and pass slices to AnalyticsGeoMap / AnalyticsHeatmap /
  AnalyticsCompareSheet — no extra round-trips.

  TODO i18n: every visible string is hardcoded English (search "TODO i18n").
-->
<script setup lang="ts">
import { ref, watch, computed, onMounted } from 'vue'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'
import { useAnalyticsData } from '@/composables/useAnalyticsData'
import { useOrganization } from '@/composables/useOrganization'
import AnalyticsGeoMap from '@/components/analytics/AnalyticsGeoMap.vue'
import AnalyticsCompareSheet from '@/components/analytics/AnalyticsCompareSheet.vue'
import { formatCurrency } from '@/lib/utils'

interface MachineRow {
  id: string
  name: string
  lat: number | null
  lng: number | null
  status: string | null
  revenue: number
  units: number
  conversion_pct: number | null
  last_sale_gap_minutes: number | null
  stock_health: unknown | null
  current_online: boolean
}

interface MachineHeatmap {
  dow: number[]
  hour: number[]
}

interface MachinesResponse {
  version: number
  kpis: {
    active_count: number
    best_machine_id: string | null
    best_machine_name: string | null
    best_revenue: number | null
    avg_conversion_pct: number | null
    total_stockout_hours: number
  }
  machines: MachineRow[]
  heatmaps: Record<string, MachineHeatmap>
}

const { filter } = useAnalyticsFilters()
const { fetch, loading, error } = useAnalyticsData()
const { organization } = useOrganization()

const data = ref<MachinesResponse | null>(null)

// UI toggles. Map visible by default since the bubble map is the most
// scannable summary; heatmaps are off by default to avoid 24-cell strips
// stacking under every card.
const showHeatmaps = ref(false)
const showMap = ref(true)
const compareOpen = ref(false)
const selectedIds = ref<string[]>([])

const canCompare = computed(
  () => selectedIds.value.length >= 2 && selectedIds.value.length <= 4,
)

async function load() {
  if (!organization.value?.id) return
  data.value = (await fetch('machines', filter.value, organization.value.id)) as MachinesResponse | null
}

onMounted(load)
watch(filter, load, { deep: true })

// Toggle membership in the selectedIds list, capping at 4 so the Compare
// sheet's 2x2 grid stays full-bleed. The Compare button below also enforces
// the 2..4 lower/upper bound — this just stops the UX from letting you tick
// a 5th box.
function toggleSelected(id: string) {
  const i = selectedIds.value.indexOf(id)
  if (i >= 0) selectedIds.value.splice(i, 1)
  else if (selectedIds.value.length < 4) selectedIds.value.push(id)
}

function isSelected(id: string): boolean {
  return selectedIds.value.includes(id)
}

function openCompare() {
  if (!canCompare.value) return
  compareOpen.value = true
}

// AnalyticsHeatmap takes rows shaped like { key, label, revenue, units }
// where revenue drives the cell intensity. The RPC gives us a 24-element
// hour array of sales counts per machine — adapt by mapping count into both
// `revenue` (intensity) and `units` (tooltip), so we don't have to fork the
// heatmap component for a different intensity source.
function hourCellsFor(machineId: string) {
  const arr = data.value?.heatmaps?.[machineId]?.hour ?? []
  return arr.map((cnt: number, h: number) => ({
    key: h,
    label: String(h).padStart(2, '0') + ':00',
    revenue: cnt,
    units: cnt,
  }))
}

function statusBadgeClass(online: boolean): string {
  return online
    ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300'
    : 'bg-muted text-muted-foreground'
}

const numberFmt = new Intl.NumberFormat()

function fmtNumber(v: number | null | undefined): string {
  return numberFmt.format(Number(v ?? 0))
}
function fmtCurrency(v: number | null | undefined): string {
  return formatCurrency(Number(v ?? 0))
}
function fmtPercent(v: number | null | undefined): string {
  if (v == null) return '—'
  return `${Number(v).toFixed(1)}%`
}
function fmtLastSale(minutes: number | null): string {
  // TODO i18n: relative-time strings hardcoded.
  if (minutes == null) return 'No sales yet'
  if (minutes < 60) return `${Math.round(minutes)}m ago`
  const hours = minutes / 60
  if (hours < 24) return `${hours.toFixed(1)}h ago`
  const days = hours / 24
  return `${days.toFixed(1)}d ago`
}
</script>

<template>
  <div class="flex flex-col gap-4" data-testid="analytics-tab-machines">
    <!-- KPI Grid -->
    <!-- TODO i18n: KPI labels hardcoded; add analytics.machines.kpi.* keys -->
    <AnalyticsKpiGrid
      v-if="data"
      :kpis="[
        { label: 'Active machines',     value: data.kpis.active_count,                  format: 'number' },
        { label: 'Best revenue',        value: data.kpis.best_revenue ?? 0,             format: 'currency' },
        { label: 'Avg conversion',      value: data.kpis.avg_conversion_pct ?? 0,       format: 'percent' },
        { label: 'Stockout hours',      value: data.kpis.total_stockout_hours,          format: 'number' },
      ]"
    />
    <div
      v-if="data?.kpis?.best_machine_name"
      class="text-xs text-muted-foreground"
      data-testid="analytics-machines-best-label"
    >
      <!-- TODO i18n -->
      Best machine: <span class="font-medium text-foreground">{{ data.kpis.best_machine_name }}</span>
    </div>

    <!-- Toggle / action row -->
    <div
      class="flex flex-wrap items-center gap-2 rounded-md border bg-card p-2 shadow-sm"
      data-testid="analytics-machines-toolbar"
    >
      <label class="inline-flex h-9 items-center gap-2 rounded-md border bg-background px-3 text-xs">
        <input v-model="showMap" type="checkbox" class="size-3.5" />
        <!-- TODO i18n -->
        <span class="text-muted-foreground">Show map</span>
      </label>
      <label class="inline-flex h-9 items-center gap-2 rounded-md border bg-background px-3 text-xs">
        <input v-model="showHeatmaps" type="checkbox" class="size-3.5" />
        <!-- TODO i18n -->
        <span class="text-muted-foreground">Show heatmaps</span>
      </label>
      <button
        type="button"
        class="ml-auto h-9 rounded-md bg-primary px-4 text-xs font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
        :disabled="!canCompare"
        data-testid="analytics-machines-compare-btn"
        @click="openCompare"
      >
        <!-- TODO i18n -->
        Compare ({{ selectedIds.length }})
      </button>
    </div>

    <!-- Geo map -->
    <AnalyticsGeoMap
      v-if="data && showMap"
      :machines="data.machines"
    />

    <!-- Machine card grid -->
    <div
      v-if="data?.machines?.length"
      class="grid gap-3 md:grid-cols-2 lg:grid-cols-3"
      data-testid="analytics-machines-grid"
    >
      <div
        v-for="m in data.machines"
        :key="m.id"
        class="flex flex-col gap-2 rounded-xl border bg-card p-3 shadow-xs"
        data-testid="analytics-machines-card"
      >
        <div class="flex items-start justify-between gap-2">
          <div class="truncate text-sm font-medium" :title="m.name">{{ m.name }}</div>
          <span
            class="shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide"
            :class="statusBadgeClass(m.current_online)"
          >
            <!-- TODO i18n -->
            {{ m.current_online ? 'online' : 'offline' }}
          </span>
        </div>
        <div class="grid grid-cols-2 gap-x-2 gap-y-0.5 text-xs text-muted-foreground tabular-nums">
          <!-- TODO i18n: metric labels -->
          <div>Revenue</div>
          <div class="text-right text-foreground">{{ fmtCurrency(m.revenue) }}</div>
          <div>Units</div>
          <div class="text-right text-foreground">{{ fmtNumber(m.units) }}</div>
          <div>Conversion</div>
          <div class="text-right text-foreground">{{ fmtPercent(m.conversion_pct) }}</div>
          <div>Last sale</div>
          <div class="text-right text-foreground">{{ fmtLastSale(m.last_sale_gap_minutes) }}</div>
        </div>

        <!-- Compare checkbox -->
        <label class="mt-1 inline-flex items-center gap-2 text-xs">
          <input
            type="checkbox"
            class="size-3.5"
            :checked="isSelected(m.id)"
            :disabled="!isSelected(m.id) && selectedIds.length >= 4"
            data-testid="analytics-machines-compare-checkbox"
            @change="toggleSelected(m.id)"
          />
          <!-- TODO i18n -->
          <span class="text-muted-foreground">Compare</span>
        </label>

        <!-- Inline hour heatmap (when toggle is on) -->
        <AnalyticsHeatmap
          v-if="showHeatmaps && data?.heatmaps?.[m.id]"
          :rows="hourCellsFor(m.id)"
          dimension="hour"
        />
      </div>
    </div>

    <!-- Empty state -->
    <div
      v-else-if="data && !loading"
      class="rounded-xl border border-dashed bg-muted/30 p-12 text-center text-sm text-muted-foreground"
    >
      <!-- TODO i18n -->
      No machines match the current filters.
    </div>

    <!-- Loading / error -->
    <!-- TODO i18n: status strings hardcoded -->
    <div v-if="loading" class="text-sm text-muted-foreground">Loading…</div>
    <div v-if="error" class="text-sm text-destructive">{{ error }}</div>

    <!-- Compare sheet -->
    <AnalyticsCompareSheet
      v-if="data"
      v-model:open="compareOpen"
      :machine-ids="selectedIds"
      :machines="data.machines"
    />
  </div>
</template>
