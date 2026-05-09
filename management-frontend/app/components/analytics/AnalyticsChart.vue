<!--
  AnalyticsChart
  --------------
  Generic chart wrapper around ChartAreaInteractive.vue. The underlying chart
  only consumes `{ date: Date; total: number }[]`, so this wrapper does the
  shape transform for callers that have their data keyed by arbitrary fields
  (e.g. `bucket_ts`, `revenue_cents`, etc.).

  v1 scope:
    - data / xKey / yKey transform → ChartAreaInteractive
    - title / description pass-through
    - loading skeleton (h-[300px] muted block)

  TODO: secondary axis (Phase 3b) — `secondaryYKey` and `compareData` are
  accepted props but not rendered. Chunk 4 will implement dual-axis charts
  for richer visualizations (e.g. revenue + paxcounter overlay).

  TODO i18n: no user-visible literals here. Title/description are pass-through.
-->
<script setup lang="ts">
import ChartAreaInteractive from '@/components/ChartAreaInteractive.vue'

const props = defineProps<{
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
}>()

const transformed = computed(() =>
  props.data.map((d) => ({
    date: typeof d[props.xKey] === 'string' ? new Date(d[props.xKey]) : d[props.xKey],
    total: Number(d[props.yKey] ?? 0),
  })),
)
</script>

<template>
  <div data-testid="analytics-chart">
    <div
      v-if="loading"
      class="h-[300px] animate-pulse rounded-xl bg-muted"
      data-testid="analytics-chart-skeleton"
    />
    <ChartAreaInteractive
      v-else
      :data="transformed"
      :title="title"
      :description="description"
    />
  </div>
</template>
