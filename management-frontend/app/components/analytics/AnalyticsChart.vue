<!--
  AnalyticsChart
  --------------
  Generic chart wrapper. Two render modes:
    - chartType: 'bar' (default) → wraps ChartAreaInteractive.vue, which
      consumes `{ date: Date; total: number }[]`. We do the shape transform
      for callers that have their data keyed by arbitrary fields
      (e.g. `bucket_ts`, `revenue_cents`, etc.).
    - chartType: 'scatter' → inline SVG scatter plot. Used by TabConversion
      to plot pax (x) vs sales (y) per machine. Intentionally minimal:
      basic axes, dots with native <title> tooltips, optional horizontal
      reference line. No brushing, no axis labels per data type, no rich
      tooltips — Phase 4b will iterate.

  v1 scope:
    - data / xKey / yKey transform → ChartAreaInteractive (bar mode)
    - inline SVG dots (scatter mode) — uses computed scales over the data
    - title / description pass-through
    - loading skeleton (h-[300px] muted block)

  TODO: secondary axis (Phase 3b) — `secondaryYKey` and `compareData` are
  accepted props but not rendered. Chunk 4 will implement dual-axis charts
  for richer visualizations (e.g. revenue + paxcounter overlay).

  TODO Phase 4b: scatter chart could grow tooltips, brushing, axis labels
  per data type (e.g. format y as % when conversion-keyed), and a true
  diagonal reference line for "ideal conversion" (y = avgConv * x).

  TODO i18n: empty-state literal "No data" hardcoded. Title/description are
  pass-through.
-->
<script setup lang="ts">
import ChartAreaInteractive from '@/components/ChartAreaInteractive.vue'

const props = withDefaults(
  defineProps<{
    data: any[]
    xKey: string
    yKey: string
    /** TODO: secondary axis (Phase 3b) — not rendered in v1 */
    secondaryYKey?: string
    /** TODO: compare period overlay (Phase 3b) — not rendered in v1 */
    compareData?: any[]
    title?: string
    description?: string
    loading?: boolean
    /** Chart variant — 'bar' delegates to ChartAreaInteractive, 'scatter' renders inline SVG. */
    chartType?: 'bar' | 'scatter'
    /**
     * Optional horizontal reference line for scatter mode (e.g. fleet-avg
     * value on the y-axis). Ignored for bar charts. Skipped if null.
     * TODO Phase 4b: support diagonal reference (y = ratio * x) for true
     * "fleet-avg conversion" overlay on a pax×sales scatter.
     */
    referenceY?: number | null
  }>(),
  {
    chartType: 'bar',
    referenceY: null,
  },
)

const transformed = computed(() =>
  props.data.map((d) => ({
    date: typeof d[props.xKey] === 'string' ? new Date(d[props.xKey]) : d[props.xKey],
    total: Number(d[props.yKey] ?? 0),
  })),
)

const isScatter = computed(() => props.chartType === 'scatter')

// Scatter-mode geometry. SVG uses a 600×300 viewBox stretched to container
// width via preserveAspectRatio="none". 40px left padding for the y-axis,
// 20px right, 30px top, 20px bottom — leaves a 540×250 plot area.
const xVals = computed(() => props.data.map((d) => Number(d[props.xKey] ?? 0)))
const yVals = computed(() => props.data.map((d) => Number(d[props.yKey] ?? 0)))
const xMax = computed(() => Math.max(1, ...xVals.value))
const yMax = computed(() => Math.max(1, ...yVals.value))

interface ScatterPoint {
  cx: number
  cy: number
  label: string
  rawX: number
  rawY: number
}

const points = computed<ScatterPoint[]>(() =>
  props.data.map((d, i) => ({
    cx: 40 + (xVals.value[i]! / xMax.value) * 540,
    cy: 280 - (yVals.value[i]! / yMax.value) * 250,
    label: String(d.label ?? d.name ?? ''),
    rawX: xVals.value[i]!,
    rawY: yVals.value[i]!,
  })),
)

const refLineY = computed<number | null>(() => {
  if (props.referenceY == null) return null
  return 280 - (Number(props.referenceY) / yMax.value) * 250
})
</script>

<template>
  <div data-testid="analytics-chart">
    <!-- Loading skeleton (shared across modes) -->
    <div
      v-if="loading"
      class="h-[300px] animate-pulse rounded-xl bg-muted"
      data-testid="analytics-chart-skeleton"
    />

    <!-- Scatter mode: inline SVG -->
    <div
      v-else-if="isScatter"
      class="rounded-xl border bg-card p-4"
      data-testid="analytics-scatter-chart"
    >
      <h3 v-if="title" class="mb-3 text-sm font-medium">{{ title }}</h3>
      <p v-if="description" class="mb-3 text-xs text-muted-foreground">{{ description }}</p>
      <svg
        v-if="data.length"
        viewBox="0 0 600 300"
        class="h-[300px] w-full"
        preserveAspectRatio="none"
      >
        <!-- Axes -->
        <line x1="40" y1="280" x2="580" y2="280" stroke="currentColor" stroke-opacity="0.3" />
        <line x1="40" y1="30" x2="40" y2="280" stroke="currentColor" stroke-opacity="0.3" />

        <!-- Reference line (horizontal, y-only). TODO Phase 4b: diagonal. -->
        <line
          v-if="refLineY != null"
          x1="40"
          :y1="refLineY"
          x2="580"
          :y2="refLineY"
          stroke="hsl(var(--primary))"
          stroke-dasharray="4 4"
          stroke-opacity="0.5"
        />

        <!-- Dots -->
        <circle
          v-for="(pt, i) in points"
          :key="i"
          :cx="pt.cx"
          :cy="pt.cy"
          r="5"
          fill="hsl(var(--primary))"
          fill-opacity="0.6"
          stroke="hsl(var(--primary))"
          stroke-opacity="0.9"
        >
          <title>{{ pt.label }}: {{ pt.rawX }} / {{ pt.rawY }}</title>
        </circle>

        <!-- Axis tick labels (corners only — keeps the v1 minimal). -->
        <text x="40" y="295" fill="currentColor" fill-opacity="0.6" font-size="10">0</text>
        <text
          x="580"
          y="295"
          fill="currentColor"
          fill-opacity="0.6"
          font-size="10"
          text-anchor="end"
        >
          {{ xMax }}
        </text>
        <text
          x="36"
          y="282"
          fill="currentColor"
          fill-opacity="0.6"
          font-size="10"
          text-anchor="end"
        >
          0
        </text>
        <text
          x="36"
          y="34"
          fill="currentColor"
          fill-opacity="0.6"
          font-size="10"
          text-anchor="end"
        >
          {{ yMax }}
        </text>
      </svg>
      <div
        v-else
        class="flex h-[300px] items-center justify-center text-sm text-muted-foreground"
      >
        <!-- TODO i18n -->
        No data
      </div>
    </div>

    <!-- Bar mode (default): delegate to ChartAreaInteractive -->
    <ChartAreaInteractive
      v-else
      :data="transformed"
      :title="title"
      :description="description"
    />
  </div>
</template>
