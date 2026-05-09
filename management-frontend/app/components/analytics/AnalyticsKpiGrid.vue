<!--
  AnalyticsKpiGrid
  ----------------
  Responsive grid of 1–4 KPI cards. Layout breakpoints:
    mobile  -> 1 column
    tablet  -> 2 columns (md:)
    desktop -> 4 columns (lg:)

  Each KPI is { label, value, delta?, format }. `delta` is a percentage
  number; null/undefined hides the pill. Sign drives green/red color so the
  caller doesn't need to know our color tokens.

  Style mirrors SectionCards.vue's card chrome (rounded-xl border bg-card)
  but stays presentational — no sparklines / no slot trickery. Wired to
  formatCurrency from @/lib/utils for `format: 'currency'` so the Analytics
  page renders EUR identically to the dashboard.

  TODO i18n: no user-visible literals to translate beyond what the caller
  passes via `label` (which the page should already i18n at its layer).
-->
<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'

interface Kpi {
  label: string
  value: number
  /** percentage change vs comparison period; null/undefined hides the pill */
  delta?: number | null
  format: 'currency' | 'number' | 'percent'
}

defineProps<{ kpis: Kpi[] }>()

function formatValue(v: number, fmt: 'currency' | 'number' | 'percent'): string {
  if (fmt === 'currency') return formatCurrency(v)
  if (fmt === 'percent') return `${v.toFixed(1)}%`
  return new Intl.NumberFormat().format(v)
}

function deltaClass(d: number | null | undefined): string {
  if (d == null) return 'text-muted-foreground'
  return d >= 0
    ? 'text-green-600 dark:text-green-400'
    : 'text-red-600 dark:text-red-400'
}

function formatDelta(d: number | null | undefined): string {
  if (d == null) return ''
  const sign = d >= 0 ? '+' : ''
  return `${sign}${d.toFixed(1)}%`
}
</script>

<template>
  <div
    class="grid gap-4 md:grid-cols-2 lg:grid-cols-4"
    data-testid="analytics-kpi-grid"
  >
    <div
      v-for="(k, i) in kpis"
      :key="i"
      class="rounded-xl border bg-card p-4 shadow-xs"
      data-testid="analytics-kpi-card"
    >
      <div class="text-xs font-medium text-muted-foreground">{{ k.label }}</div>
      <div class="mt-1 text-2xl font-semibold tabular-nums">
        {{ formatValue(k.value, k.format) }}
      </div>
      <div
        v-if="k.delta != null"
        class="mt-1 text-xs font-medium tabular-nums"
        :class="deltaClass(k.delta)"
      >
        {{ formatDelta(k.delta) }}
      </div>
    </div>
  </div>
</template>
