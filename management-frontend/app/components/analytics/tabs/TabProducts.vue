<!--
  TabProducts
  -----------
  Product-velocity / status / mix-shift workbench (Task 4.2 / Phase 4).

  Layout:
    1. KPI grid (active / slow / discontinued / categories with sales)
    2. Sub-filter row: search input, category multi-select, status pills,
       slow-only toggle
    3. Mix-shift chart (v1: aggregated daily revenue across categories;
       Phase 4b will replace with stacked-area per category)
    4. Responsive product card grid with image thumbnail, name, status
       badge and the velocity / units / revenue / mix metrics

  Data source: analytics_products RPC (see Chunk 2 migration).
  Returns the full product set for the company in the date window — all
  search / category / status / slow filtering happens client-side, since
  the result set is bounded by `products` table size.
-->
<script setup lang="ts">
import { ref, watch, computed, onMounted } from 'vue'
import { useSupabaseClient } from '#imports'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'
import { useAnalyticsData } from '@/composables/useAnalyticsData'
import { useOrganization } from '@/composables/useOrganization'
import { getProductImageUrl } from '@/composables/useProducts'
import MultiSelectPill from '@/components/analytics/MultiSelectPill.vue'

type ProductStatus = 'active' | 'slow' | 'dead' | 'discontinued'
const STATUSES: readonly ProductStatus[] = ['active', 'slow', 'dead', 'discontinued'] as const

const { t } = useI18n()
const { filter } = useAnalyticsFilters()
const { fetch, loading, error } = useAnalyticsData()
const { organization } = useOrganization()
const supabase = useSupabaseClient()

const data = ref<any>(null)
const categories = ref<{ id: string; name: string }[]>([])

// Sub-filters: status/search/slow-only are client-side; categories
// is bound to the GLOBAL filter so the FilterBar's category pill and
// this tab's pill share one source of truth (the RPC already filters
// server-side by `filter.categories`).
const searchTerm = ref('')
const selectedStatuses = ref<ProductStatus[]>([])
const slowOnly = ref(false)

async function load() {
  if (!organization.value?.id) return
  data.value = await fetch('products', filter.value, organization.value.id)
}

onMounted(async () => {
  await load()
  if (organization.value?.id) {
    try {
      const { data: cats } = await supabase
        .from('product_category')
        .select('id, name')
        .eq('company', organization.value.id)
      categories.value = ((cats ?? []) as { id: string; name: string | null }[])
        .map((c) => ({ id: c.id, name: c.name ?? '(unnamed)' }))
        .sort((a, b) => a.name.localeCompare(b.name))
    } catch (err) {
      // Sub-filter is non-fatal — log and render with empty option list
      console.error('[TabProducts] failed to load categories:', err)
    }
  }
})
watch(filter, load, { deep: true })

// --- Filtering --------------------------------------------------------------
const filteredProducts = computed<any[]>(() => {
  let rows: any[] = data.value?.products ?? []
  if (searchTerm.value.trim()) {
    const q = searchTerm.value.trim().toLowerCase()
    rows = rows.filter((p) => (p.name ?? '').toLowerCase().includes(q))
  }
  // categories filtered server-side via filter.categories — no client-side pass needed
  if (selectedStatuses.value.length > 0) {
    const set = new Set(selectedStatuses.value)
    rows = rows.filter((p) => set.has(p.status))
  }
  if (slowOnly.value) {
    rows = rows.filter((p) => p.status === 'slow')
  }
  return rows
})

// --- Mix-shift series (v1: aggregated daily revenue) ------------------------
// TODO Phase 4b: render a true stacked-area chart with one band per category
// instead of summing across categories. AnalyticsChart only handles a single
// y-key today, so we collapse the dimension for the v1 visualization.
const dailyRevenue = computed<{ date: string; revenue: number }[]>(() => {
  const series: any[] = data.value?.mix_shift_series ?? []
  const byDate = new Map<string, number>()
  for (const r of series) {
    const d: string = r.date
    if (!d) continue
    byDate.set(d, (byDate.get(d) ?? 0) + Number(r.revenue || 0))
  }
  return Array.from(byDate.entries())
    .map(([date, revenue]) => ({ date, revenue }))
    .sort((a, b) => a.date.localeCompare(b.date))
})

// --- Option list for the category sub-filter -------------------------------
const categoryOptions = computed(() =>
  categories.value.map((c) => ({ value: c.id, label: c.name })),
)

// --- Status pills -----------------------------------------------------------
function toggleStatus(s: ProductStatus) {
  const i = selectedStatuses.value.indexOf(s)
  if (i >= 0) selectedStatuses.value.splice(i, 1)
  else selectedStatuses.value.push(s)
}

function isStatusActive(s: ProductStatus): boolean {
  return selectedStatuses.value.includes(s)
}

// --- Per-card display helpers ----------------------------------------------
function imgSrc(p: any): string | null {
  return p.image_path ? getProductImageUrl(p.image_path) : null
}

function statusBadgeClass(status: string): string {
  switch (status) {
    case 'active':       return 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300'
    case 'slow':         return 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300'
    case 'dead':         return 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'
    case 'discontinued': return 'bg-muted text-muted-foreground'
    default:             return 'bg-muted text-muted-foreground'
  }
}

const numberFmt = new Intl.NumberFormat()
const currencyFmt = new Intl.NumberFormat('de-DE', { style: 'currency', currency: 'EUR' })

function fmtVelocity(v: number | null | undefined): string {
  return `${(Number(v ?? 0)).toFixed(2)}/d`
}
function fmtNumber(v: number | null | undefined): string {
  return numberFmt.format(Number(v ?? 0))
}
function fmtCurrency(v: number | null | undefined): string {
  return currencyFmt.format(Number(v ?? 0))
}
function fmtPercent(v: number | null | undefined): string {
  return `${Number(v ?? 0).toFixed(1)}%`
}
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- KPI Grid -->
    <AnalyticsKpiGrid
      v-if="data"
      :kpis="[
        { label: t('analytics.kpi.active'),              value: data.kpis.active_count,           format: 'number' },
        { label: t('analytics.kpi.slowMovers'),          value: data.kpis.slow_mover_count,       format: 'number' },
        { label: t('analytics.kpi.discontinued'),        value: data.kpis.discontinued_count,     format: 'number' },
        { label: t('analytics.kpi.categoriesWithSales'), value: data.kpis.categories_with_sales,  format: 'number' },
      ]"
    />

    <!-- Sub-filter row -->
    <div
      class="flex flex-wrap items-center gap-2 rounded-md border bg-card p-2 shadow-sm"
      data-testid="analytics-products-subfilters"
    >
      <!-- Search input -->
      <input
        v-model="searchTerm"
        type="text"
        :placeholder="t('analytics.searchProducts')"
        class="flex h-9 w-full max-w-xs rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        data-testid="analytics-products-search"
      />

      <!-- Categories multi-select -->
      <MultiSelectPill
        v-model="filter.categories"
        :options="categoryOptions"
        :placeholder="t('analytics.categories')"
        :search-placeholder="t('analytics.searchCategories')"
        :max-visible-badges="2"
        testid="analytics-products-categories"
      />

      <!-- Status pills -->
      <div class="flex items-center gap-1" data-testid="analytics-products-status">
        <button
          v-for="s in STATUSES"
          :key="s"
          type="button"
          class="rounded-full border px-3 py-1 text-xs font-medium transition-colors"
          :class="isStatusActive(s)
            ? 'bg-primary text-primary-foreground border-primary'
            : 'hover:bg-muted'"
          @click="toggleStatus(s)"
        >
          {{ t('analytics.' + s) }}
        </button>
      </div>

      <!-- Slow-only toggle -->
      <label
        class="inline-flex h-9 items-center gap-2 rounded-md border bg-background px-3 text-xs"
        data-testid="analytics-products-slow-only"
      >
        <input v-model="slowOnly" type="checkbox" class="size-3.5" />
        <span class="text-muted-foreground">{{ t('analytics.slowMoversOnly') }}</span>
      </label>
    </div>

    <!-- Mix-shift chart (v1: aggregated daily revenue) -->
    <!-- TODO Phase 4b: stacked-area visualization per category -->
    <AnalyticsChart
      v-if="dailyRevenue.length"
      :data="dailyRevenue"
      x-key="date"
      y-key="revenue"
      :title="t('analytics.sales.mixShift')"
    />

    <!-- Product card grid -->
    <div
      v-if="filteredProducts.length"
      class="grid gap-3 md:grid-cols-2 lg:grid-cols-3"
      data-testid="analytics-products-grid"
    >
      <div
        v-for="p in filteredProducts"
        :key="p.id"
        class="flex gap-3 rounded-xl border bg-card p-3 shadow-xs"
        data-testid="analytics-products-card"
      >
        <!-- Image -->
        <div class="size-16 shrink-0 overflow-hidden rounded-md border bg-muted">
          <img
            v-if="imgSrc(p)"
            :src="imgSrc(p) ?? undefined"
            :alt="p.name"
            class="size-full object-cover"
            loading="lazy"
          />
          <div
            v-else
            class="flex size-full items-center justify-center text-[10px] uppercase text-muted-foreground"
          >
            {{ t('analytics.noImage') }}
          </div>
        </div>

        <!-- Body -->
        <div class="flex min-w-0 flex-1 flex-col gap-1">
          <div class="flex items-start justify-between gap-2">
            <div class="truncate text-sm font-medium">{{ p.name }}</div>
            <span
              class="shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide"
              :class="statusBadgeClass(p.status)"
            >
              {{ t('analytics.' + p.status) }}
            </span>
          </div>
          <div class="grid grid-cols-2 gap-x-2 gap-y-0.5 text-xs text-muted-foreground tabular-nums">
            <div>{{ t('analytics.revenue') }}</div>
            <div class="text-right text-foreground">{{ fmtCurrency(p.revenue) }}</div>
            <div>{{ t('analytics.velocity') }}</div>
            <div class="text-right text-foreground">{{ fmtVelocity(p.velocity) }}</div>
            <div>{{ t('analytics.units') }}</div>
            <div class="text-right text-foreground">{{ fmtNumber(p.units) }}</div>
            <div>{{ t('analytics.mix') }}</div>
            <div class="text-right text-foreground">{{ fmtPercent(p.mix_pct) }}</div>
          </div>
        </div>
      </div>
    </div>

    <!-- Empty state -->
    <div
      v-else-if="data && !loading"
      class="rounded-xl border border-dashed bg-muted/30 p-12 text-center text-sm text-muted-foreground"
    >
      {{ t('analytics.noProductsMatch') }}
    </div>

    <!-- Loading / error -->
    <div v-if="loading" class="text-sm text-muted-foreground">{{ t('analytics.loading') }}</div>
    <div v-if="error" class="text-sm text-destructive">{{ error }}</div>
  </div>
</template>
