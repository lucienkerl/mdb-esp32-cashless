<!--
  TabOperations
  -------------
  Operations workbench for the Analytics dashboard (Task 4.5 / Phase 4).

  Layout:
    1. Pre-migration banner — visible only when filter.from precedes the
       2026-05-09 stockout-events migration. Older windows have no
       analytics.stockout_events rows so the panel data is partial.
    2. KPI grid (stockout hours, lost revenue, refill tour count, avg cover
       days). Pulled straight from data.kpis.
    3. Stockout events list — sorted by lost_revenue desc, capped at 50
       so a 14-day fleet-wide window doesn't dump 500+ rows. Each row shows
       the product, machine, started→ended span, duration, and EUR estimate.
    4. Refill tours collapsed by ISO date. Click a day header to expand the
       individual tours (user, started_at, duration, machine count, units).
       Days are sorted newest-first, tours within a day also newest-first.
    5. Stock cover days table — sorted by cover_days asc so red rows surface
       first. Cells red if <3, yellow if <7, plain otherwise; null cover
       (no velocity) renders as muted "—".

  Data source: analytics_operations RPC (see Chunk 2 migration). Returns
  { kpis, stockout_events[], refill_tours[], stock_cover[] }. We fetch once
  per filter-change and slice/sort locally.
-->
<script setup lang="ts">
import { ref, watch, computed, onMounted } from 'vue'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'
import { useAnalyticsData } from '@/composables/useAnalyticsData'
import { useOrganization } from '@/composables/useOrganization'
import { formatCurrency } from '@/lib/utils'

const { t } = useI18n()

// Stockout-events foundation landed in 20260509000000; before that, the
// analytics.stockout_events table has zero rows and the RPC silently
// returns empty arrays. We surface that as a banner instead of letting
// the empty list be misread as "everything was healthy".
const STOCKOUT_DATA_AVAILABLE_FROM = '2026-05-09T00:00:00.000Z'

interface StockoutEvent {
  id: string
  machine_id: string
  machine_name: string
  tray_id: string
  item_number: number
  product_id: string | null
  product_name: string | null
  started_at: string
  ended_at: string | null
  duration_seconds: number
  lost_units_estimated: number
  lost_revenue_estimated: number
}

interface RefillTourMachine {
  machine_id: string
  machine_name: string
  items_added: number
}

interface RefillTour {
  tour_id: string
  started_at: string
  ended_at: string
  duration_minutes: number
  user_display: string | null
  machines_count: number
  units_added: number
  machines: RefillTourMachine[]
}

interface StockCoverRow {
  tray_id: string
  machine_id: string
  machine_name: string
  item_number: number
  product_id: string | null
  product_name: string | null
  current_stock: number
  velocity: number
  cover_days: number | null
}

interface OperationsResponse {
  version: number
  kpis: {
    stockout_hours: number
    lost_revenue: number
    refill_tour_count: number
    avg_stock_cover_days: number | null
  }
  stockout_events: StockoutEvent[]
  refill_tours: RefillTour[]
  stock_cover: StockCoverRow[]
}

const { filter } = useAnalyticsFilters()
const { fetch, loading, error } = useAnalyticsData()
const { organization } = useOrganization()

const data = ref<OperationsResponse | null>(null)

async function load() {
  if (!organization.value?.id) return
  data.value = (await fetch('operations', filter.value, organization.value.id)) as
    | OperationsResponse
    | null
}

onMounted(load)
watch(filter, load, { deep: true })

// True when the user is asking about a window that begins before the
// stockout-events foundation existed. The banner warns the data is
// incomplete; the actual lists still render whatever the RPC returns.
const showPreMigrationBanner = computed<boolean>(() => {
  return new Date(filter.value.from) < new Date(STOCKOUT_DATA_AVAILABLE_FROM)
})

// Human-readable date for the pre-migration banner. Uses the user's locale
// formatter so the banner reads naturally in either de or en (e.g. de:
// "09.05.2026", en: "5/9/2026"). Computed once since the date is fixed.
const stockoutAvailableFromLabel = computed(() =>
  new Date(STOCKOUT_DATA_AVAILABLE_FROM).toLocaleDateString(),
)

// Stockouts get sorted by EUR estimate desc — the operator cares about
// "what cost me the most money", not chronological order. Top 50 cap
// keeps the DOM bounded; a 14-day fleet window can produce hundreds.
const sortedStockouts = computed<StockoutEvent[]>(() => {
  const arr = data.value?.stockout_events ?? []
  return [...arr].sort(
    (a, b) =>
      Number(b.lost_revenue_estimated ?? 0) - Number(a.lost_revenue_estimated ?? 0),
  )
})

// Group refill tours by ISO date (UTC slice). Each day is then sorted by
// started_at desc so the most recent tour appears first inside the group.
const refillToursByDay = computed<{ day: string; tours: RefillTour[] }[]>(() => {
  const tours = data.value?.refill_tours ?? []
  const byDay = new Map<string, RefillTour[]>()
  for (const t of tours) {
    const day = new Date(t.started_at).toISOString().slice(0, 10)
    if (!byDay.has(day)) byDay.set(day, [])
    byDay.get(day)!.push(t)
  }
  return Array.from(byDay.entries())
    .sort((a, b) => b[0].localeCompare(a[0]))
    .map(([day, dayTours]) => ({
      day,
      tours: [...dayTours].sort(
        (a, b) => new Date(b.started_at).getTime() - new Date(a.started_at).getTime(),
      ),
    }))
})

// Stock cover sorted ascending — red (<3) bubbles to the top so a refill
// planner can spot urgent trays at a glance. null cover_days lands at the
// bottom (treated as +Infinity) since "no velocity" isn't actionable.
const sortedStockCover = computed<StockCoverRow[]>(() => {
  const arr = data.value?.stock_cover ?? []
  return [...arr].sort((a, b) => {
    const ad = a.cover_days ?? Infinity
    const bd = b.cover_days ?? Infinity
    return ad - bd
  })
})

// Tailwind classes for the cover-days cell. <3 = red (urgent refill),
// <7 = yellow (refill within the week), otherwise foreground default.
function coverColorClass(coverDays: number | null): string {
  if (coverDays == null) return 'text-muted-foreground'
  if (coverDays < 3) return 'text-red-600 dark:text-red-400 font-medium'
  if (coverDays < 7) return 'text-yellow-600 dark:text-yellow-400'
  return 'text-foreground'
}

// Per-day expansion state. Keyed by ISO date so toggles survive a filter
// re-fetch (as long as the date is still in the result set).
const expandedDays = ref<Record<string, boolean>>({})
function toggleDay(day: string) {
  expandedDays.value[day] = !expandedDays.value[day]
}

function fmtDateTime(iso: string): string {
  return new Date(iso).toLocaleString()
}
function fmtDate(iso: string): string {
  return new Date(iso).toLocaleDateString()
}

// Compact duration display — seconds for quick blips, minutes mid-range,
// hours+minutes once we cross the hour mark. Floor everywhere because
// rounding 59.7s up to "1m" would mislead.
function fmtDuration(seconds: number): string {
  if (seconds < 60) return Math.floor(seconds) + 's'
  if (seconds < 3600) return Math.floor(seconds / 60) + 'm'
  return Math.floor(seconds / 3600) + 'h ' + Math.floor((seconds % 3600) / 60) + 'm'
}
</script>

<template>
  <div class="flex flex-col gap-4" data-testid="analytics-tab-operations">
    <!-- Pre-migration banner -->
    <div
      v-if="showPreMigrationBanner"
      class="rounded-xl border border-yellow-300 bg-yellow-50 p-3 text-sm text-yellow-900 dark:border-yellow-900/40 dark:bg-yellow-900/20 dark:text-yellow-200"
      data-testid="analytics-operations-pre-migration-banner"
    >
      {{ t('analytics.operations.stockoutsBeforeBanner', { date: stockoutAvailableFromLabel }) }}
    </div>

    <!-- KPI grid -->
    <AnalyticsKpiGrid
      v-if="data"
      :kpis="[
        { label: t('analytics.kpi.stockoutHours'), value: Number(data.kpis.stockout_hours ?? 0),       format: 'number' },
        { label: t('analytics.kpi.lostRevenue'),   value: Number(data.kpis.lost_revenue ?? 0),         format: 'currency' },
        { label: t('analytics.kpi.refillTours'),   value: Number(data.kpis.refill_tour_count ?? 0),    format: 'number' },
        { label: t('analytics.kpi.avgCoverDays'),  value: Number(data.kpis.avg_stock_cover_days ?? 0), format: 'number' },
      ]"
    />

    <!-- Stockout events -->
    <div
      v-if="data"
      class="rounded-xl border bg-card overflow-hidden"
      data-testid="analytics-operations-stockouts"
    >
      <div class="border-b px-4 py-3">
        <h3 class="text-sm font-medium">
          {{ t('analytics.stockoutsTitle') }}
        </h3>
        <p class="mt-1 text-xs text-muted-foreground">
          {{ t('analytics.stockoutsSorted') }}
        </p>
      </div>
      <div v-if="!sortedStockouts.length" class="p-4 text-sm text-muted-foreground">
        {{ t('analytics.stockoutsEmpty') }}
      </div>
      <div v-else class="divide-y">
        <div
          v-for="ev in sortedStockouts.slice(0, 50)"
          :key="ev.id"
          class="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm"
        >
          <div class="flex flex-col">
            <span class="font-medium">{{ ev.product_name ?? ('#' + ev.item_number) }}</span>
            <span class="text-xs text-muted-foreground">
              {{ ev.machine_name }} · {{ fmtDateTime(ev.started_at) }} → {{ ev.ended_at ? fmtDateTime(ev.ended_at) : t('analytics.ongoing') }}
            </span>
          </div>
          <div class="flex items-center gap-3 tabular-nums text-xs">
            <span class="text-muted-foreground">{{ fmtDuration(ev.duration_seconds) }}</span>
            <span class="text-red-600 dark:text-red-400 font-medium">{{ formatCurrency(ev.lost_revenue_estimated) }}</span>
          </div>
        </div>
        <div
          v-if="sortedStockouts.length > 50"
          class="px-4 py-2 text-xs text-muted-foreground text-center"
        >
          {{ t('analytics.showingTopOf', { shown: 50, total: sortedStockouts.length }) }}
        </div>
      </div>
    </div>

    <!-- Refill tours collapsed by day -->
    <div
      v-if="data"
      class="rounded-xl border bg-card overflow-hidden"
      data-testid="analytics-operations-refill-tours"
    >
      <div class="border-b px-4 py-3">
        <h3 class="text-sm font-medium">
          {{ t('analytics.refillToursTitle') }}
        </h3>
      </div>
      <div v-if="!refillToursByDay.length" class="p-4 text-sm text-muted-foreground">
        {{ t('analytics.refillToursEmpty') }}
      </div>
      <div v-else class="divide-y">
        <div v-for="group in refillToursByDay" :key="group.day">
          <button
            type="button"
            class="flex w-full items-center justify-between px-4 py-3 text-left text-sm transition-colors hover:bg-muted/40"
            @click="toggleDay(group.day)"
          >
            <span class="font-medium">{{ fmtDate(group.day) }}</span>
            <span class="flex items-center gap-3 text-xs text-muted-foreground tabular-nums">
              <span>{{ group.tours.length }} {{ t('analytics.tours') }}</span>
              <span>{{ group.tours.reduce((s, tr) => s + (tr.units_added ?? 0), 0) }} {{ t('analytics.items') }}</span>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="size-4 text-muted-foreground transition-transform"
                :class="{ 'rotate-180': expandedDays[group.day] }"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </span>
          </button>
          <div
            v-if="expandedDays[group.day]"
            class="border-t bg-muted/10 px-4 py-3 text-xs space-y-2"
          >
            <div
              v-for="tr in group.tours"
              :key="tr.tour_id"
              class="flex flex-wrap items-center justify-between gap-2"
            >
              <div class="flex flex-col">
                <span class="font-medium">{{ tr.user_display ?? '—' }}</span>
                <span class="text-muted-foreground">
                  {{ fmtDateTime(tr.started_at) }} · {{ tr.duration_minutes }}{{ t('analytics.minutes') }} · {{ tr.machines_count }} {{ t('analytics.machines') }}
                </span>
              </div>
              <span class="tabular-nums text-foreground">{{ tr.units_added ?? 0 }} {{ t('analytics.items') }}</span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Stock cover days table -->
    <div
      v-if="data"
      class="rounded-xl border bg-card overflow-hidden"
      data-testid="analytics-operations-stock-cover"
    >
      <div class="border-b px-4 py-3">
        <h3 class="text-sm font-medium">
          {{ t('analytics.stockCoverTitle') }}
        </h3>
        <p class="mt-1 text-xs text-muted-foreground">
          {{ t('analytics.stockCoverDescription') }}
        </p>
      </div>
      <div v-if="!sortedStockCover.length" class="p-4 text-sm text-muted-foreground">
        {{ t('analytics.stockCoverEmpty') }}
      </div>
      <div v-else class="divide-y text-sm">
        <div
          v-for="row in sortedStockCover.slice(0, 50)"
          :key="row.tray_id"
          class="grid grid-cols-[1fr_auto_auto] items-center gap-3 px-4 py-2"
        >
          <div class="min-w-0">
            <div class="truncate font-medium">{{ row.product_name ?? ('#' + row.item_number) }}</div>
            <div class="text-xs text-muted-foreground truncate">{{ row.machine_name }}</div>
          </div>
          <div class="text-right text-xs tabular-nums text-muted-foreground">
            {{ row.current_stock }} / {{ row.velocity }} {{ t('analytics.perDay') }}
          </div>
          <div
            class="text-right tabular-nums text-sm"
            :class="coverColorClass(row.cover_days)"
          >
            {{ row.cover_days == null ? '—' : row.cover_days + ' ' + t('analytics.daysSuffix') }}
          </div>
        </div>
        <div
          v-if="sortedStockCover.length > 50"
          class="px-4 py-2 text-xs text-muted-foreground text-center"
        >
          {{ t('analytics.showingTopOf', { shown: 50, total: sortedStockCover.length }) }}
        </div>
      </div>
    </div>

    <!-- Loading / error -->
    <div v-if="loading" class="text-sm text-muted-foreground">{{ t('analytics.loading') }}</div>
    <div v-if="error" class="text-sm text-destructive">{{ error }}</div>
  </div>
</template>
