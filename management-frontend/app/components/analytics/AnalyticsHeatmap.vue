<!--
  AnalyticsHeatmap
  ----------------
  1D heatmap strip for time-of-day or day-of-week analytics.

  Used by the Sales tab when the dimension switcher is on `hour` (24 cells)
  or `dow` (7 cells). Each cell is colored by relative revenue intensity
  against the strip's max — empty buckets get a near-flat fill so the grid
  shape always reads at a glance, even when only a couple of hours have
  sales.

  For `hour`, missing hours are padded out to a complete 0–23 strip so the
  layout is stable across filter changes. The grid uses `grid-cols-12` so
  hours wrap into 2 rows on every viewport (12+12 reads cleaner than 24
  thin columns on mobile). For `dow`, rows arrive as 1–7 (ISODOW) and we
  sort by key.

  TODO i18n: title strings ("Revenue by hour of day" / "Revenue by day of
  week") are hardcoded; add analytics.heatmap.* keys in a follow-up.
-->
<script setup lang="ts">
import { computed } from 'vue'
import { formatCurrency } from '@/lib/utils'

interface HeatmapRow {
  key: any
  label: string
  revenue: number
  units: number
}

const props = defineProps<{
  rows: HeatmapRow[]
  dimension: 'hour' | 'dow'
}>()

const maxRevenue = computed(() => Math.max(1, ...props.rows.map((r) => r.revenue ?? 0)))

function intensity(revenue: number): number {
  return Math.min(1, (revenue ?? 0) / maxRevenue.value)
}

function cellStyle(revenue: number) {
  const i = intensity(revenue)
  // Fade from a near-transparent base to a saturated indigo so empty cells
  // still register as part of the grid while busy cells dominate visually.
  const alpha = i === 0 ? 0.05 : 0.15 + i * 0.65
  return { backgroundColor: `rgba(99, 102, 241, ${alpha})` }
}

const cells = computed<HeatmapRow[]>(() => {
  if (props.dimension === 'hour') {
    const byHour = new Map<number, HeatmapRow>(
      props.rows.map((r) => [Number(r.key), r]),
    )
    return Array.from({ length: 24 }, (_, h) =>
      byHour.get(h) ?? {
        key: h,
        label: String(h).padStart(2, '0') + ':00',
        revenue: 0,
        units: 0,
      },
    )
  }
  // dow: rows arrive as ISODOW 1..7, render in order.
  return [...props.rows].sort((a, b) => Number(a.key) - Number(b.key))
})

const gridStyle = computed(() => ({
  gridTemplateColumns:
    props.dimension === 'hour'
      ? 'repeat(12, minmax(0, 1fr))'
      : 'repeat(7, minmax(0, 1fr))',
}))
</script>

<template>
  <div class="rounded-xl border bg-card p-4" data-testid="analytics-heatmap">
    <h3 class="mb-3 text-sm font-medium">
      <!-- TODO i18n -->
      {{ dimension === 'hour' ? 'Revenue by hour of day' : 'Revenue by day of week' }}
    </h3>
    <div class="grid gap-1" :style="gridStyle">
      <div
        v-for="cell in cells"
        :key="String(cell.key)"
        class="flex aspect-square flex-col items-center justify-center rounded-md border text-[10px] tabular-nums"
        :style="cellStyle(cell.revenue)"
        :title="`${cell.label}: ${formatCurrency(cell.revenue)} (${cell.units} units)`"
      >
        <span class="font-medium">{{ cell.label }}</span>
        <span class="text-[9px] text-muted-foreground">{{ formatCurrency(cell.revenue) }}</span>
      </div>
    </div>
  </div>
</template>
