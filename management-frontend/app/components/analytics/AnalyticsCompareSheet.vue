<!--
  AnalyticsCompareSheet
  ---------------------
  Side-panel sheet that compares 2-4 selected machines side-by-side
  (Task 4.3 / Phase 4).

  v1 simplification: instead of fetching `analytics_overview`-shape data per
  machine (which would mean N RPC calls), we reuse the rows the parent
  TabMachines already loaded from `analytics_machines`. The parent passes
  the full `machines` array plus the selected `machineIds`; we filter here.
  Phase 4b will fetch per-machine analytics_overview to render trend
  mini-charts inside each card.

  Layout: 2x2 grid (1 column on mobile, 2 columns at sm+) of compact KPI
  cards. Each card shows the machine name, revenue (large), units (smaller),
  a conversion-percent badge, and a "last sale Xh ago" line.

  Uses the shadcn `Sheet` family (Sheet / SheetContent / SheetHeader /
  SheetTitle) which wraps reka-ui's DialogRoot. We forward `open` /
  `update:open` so the parent owns the visibility state.
-->
<script setup lang="ts">
import { computed } from 'vue'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { formatCurrency } from '@/lib/utils'

interface CompareMachine {
  id: string
  name: string
  revenue: number
  units: number
  conversion_pct: number | null
  last_sale_gap_minutes: number | null
}

const props = defineProps<{
  open: boolean
  machineIds: string[]                 // 2-4 selected
  machines: CompareMachine[]           // already-loaded from analytics_machines
}>()

const emit = defineEmits<{
  'update:open': [value: boolean]
}>()

// Filter the parent's full machine list down to the selected IDs, preserving
// the order in which the user selected them (so the cards render in click
// order, not table order). If the parent passes a stale list, missing IDs
// silently drop out — the title already reflects the count.
const selected = computed<CompareMachine[]>(() => {
  const byId = new Map(props.machines.map((m) => [m.id, m]))
  return props.machineIds
    .map((id) => byId.get(id))
    .filter((m): m is CompareMachine => m != null)
})

function fmtConversion(v: number | null): string {
  return v == null ? '—' : `${v.toFixed(1)}%`
}

function fmtLastSale(minutes: number | null): string {
  // TODO i18n: relative-time strings hardcoded; reuse timeAgo from @/lib/utils
  // once we map gap-minutes → Date and feed it.
  if (minutes == null) return 'No sales yet'
  if (minutes < 60) return `${Math.round(minutes)}m ago`
  const hours = minutes / 60
  if (hours < 24) return `${hours.toFixed(1)}h ago`
  const days = hours / 24
  return `${days.toFixed(1)}d ago`
}

function conversionBadgeClass(v: number | null): string {
  if (v == null) return 'bg-muted text-muted-foreground'
  if (v >= 50) return 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300'
  if (v >= 25) return 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300'
  return 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'
}

function onUpdateOpen(v: boolean) {
  emit('update:open', v)
}
</script>

<template>
  <Sheet :open="props.open" @update:open="onUpdateOpen">
    <SheetContent
      side="right"
      class="w-full sm:max-w-2xl"
      data-testid="analytics-compare-sheet"
    >
      <SheetHeader>
        <SheetTitle>
          <!-- TODO i18n -->
          Compare machines ({{ selected.length }})
        </SheetTitle>
      </SheetHeader>

      <div
        v-if="selected.length"
        class="grid gap-3 p-4 sm:grid-cols-2"
        data-testid="analytics-compare-grid"
      >
        <div
          v-for="m in selected"
          :key="m.id"
          class="flex flex-col gap-2 rounded-xl border bg-card p-4 shadow-xs"
          data-testid="analytics-compare-card"
        >
          <div class="flex items-start justify-between gap-2">
            <div class="truncate text-sm font-medium" :title="m.name">{{ m.name }}</div>
            <span
              class="shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide tabular-nums"
              :class="conversionBadgeClass(m.conversion_pct)"
            >
              {{ fmtConversion(m.conversion_pct) }}
            </span>
          </div>
          <div class="text-2xl font-semibold tabular-nums">{{ formatCurrency(m.revenue) }}</div>
          <div class="text-xs text-muted-foreground tabular-nums">
            <!-- TODO i18n -->
            {{ m.units }} units
          </div>
          <div class="text-xs text-muted-foreground">
            <!-- TODO i18n -->
            Last sale: {{ fmtLastSale(m.last_sale_gap_minutes) }}
          </div>
        </div>
      </div>

      <!-- Empty state — should be unreachable since the parent disables the
           Compare button below 2 selections, but render something instead of
           an empty sheet for robustness. -->
      <div
        v-else
        class="p-8 text-center text-sm text-muted-foreground"
      >
        <!-- TODO i18n -->
        Select 2-4 machines to compare.
      </div>

      <!-- TODO Phase 4b: per-machine analytics_overview fetch for trend mini-charts -->
    </SheetContent>
  </Sheet>
</template>
