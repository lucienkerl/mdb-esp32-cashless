<script setup lang="ts">
import {
  IconRefresh,
  IconTag,
  IconBuildingStore,
  IconAlertCircle,
  IconSettings,
  IconExternalLink,
  IconCheck,
  IconDeviceMobile,
  IconPin,
  IconPinnedOff,
  IconArchive,
  IconArchiveOff,
  IconBuildingWarehouse,
  IconBox,
  IconPlug,
  IconCalendarClock,
  IconCircleCheck,
} from '@tabler/icons-vue'
import Badge from '@/components/ui/badge/Badge.vue'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import DealKeywordList from '@/components/DealKeywordList.vue'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import type { DedupedDeal } from '@/composables/useDeals'
import { timeAgo, formatCurrency } from '@/lib/utils'
import { classifyDeal, marginDelta, type DealVerdict, type PurchaseSummary } from '~/lib/purchaseComparison'
import { compareByValidity, dealValidityInfo, groupByValidity, type DealValidityInfo } from '~/lib/dealValidity'

definePageMeta({ middleware: 'auth' })

const { t, locale } = useI18n()
const { role } = useOrganization()
const {
  deals,
  loading,
  error,
  fromCache,
  noProviders,
  dealsEnabled,
  lastFetchedAt,
  loadSettings,
  fetchDeals,
  totalDeals,
  uniqueRetailers,
  avgDiscount,
  archivedCount,
  activeDeals,
  archivedDeals,
  visibleActiveDeals,
  suppressedActiveDeals,
  ekSummaries,
  dealEk,
  fetchEkSummaries,
  fetchUserStates,
  archiveDeal,
  unarchiveDeal,
  pinDeal,
  unpinDeal,
  userStateError,
  fetchNewDealKeys,
  isNew,
} = useDeals()

// "+ EK erfassen" modal
const ekModalProductId = ref<string | null>(null)
const ekModalOpen = ref(false)
function openEkModal(productId: string) { ekModalProductId.value = productId; ekModalOpen.value = true }
async function onEkSaved() { await fetchEkSummaries() }

// Card pill: best verdict → { label, cls } or null
function ekPill(deal: DedupedDeal): { label: string; cls: string } | null {
  const ek = dealEk(deal)
  if (!ek.bestVerdict) return null
  const best = ek.perProduct.find((p) => p.verdict === ek.bestVerdict)
  const pct = best?.deltaPct != null ? Math.abs(Math.round(best.deltaPct)) : null
  switch (ek.bestVerdict) {
    case 'good_best':
    case 'good':    return { cls: 'text-green-600 dark:text-green-400', label: pct != null ? t('deals.ekCheaperPct', { pct }) : t('deals.ekCheaper') }
    case 'similar': return { cls: 'text-amber-600 dark:text-amber-400', label: t('deals.ekSimilar') }
    case 'worse':   return { cls: 'text-red-600 dark:text-red-400', label: pct != null ? t('deals.ekWorsePct', { pct }) : t('deals.ekWorse') }
    default:        return null
  }
}

// Detail: per-product comparison for the selected deal — computed ONCE per render,
// keyed by product id (avoids re-running classifyDeal repeatedly in the template).
const detailComparisons = computed<Record<string, { summary: PurchaseSummary | null; verdict: DealVerdict; marginDelta: { currentPct: number; dealPct: number } | null }>>(() => {
  const out: Record<string, { summary: PurchaseSummary | null; verdict: DealVerdict; marginDelta: { currentPct: number; dealPct: number } | null }> = {}
  const d = selectedDeal.value
  if (!d) return out
  const dealGross = d.primary.deal_price
  for (const p of d.matchedProducts) {
    const summary = ekSummaries.value[p.id] ?? null
    const cmp = classifyDeal(dealGross, summary)
    const md = (cmp.verdict === 'good' || cmp.verdict === 'good_best') && dealGross != null && summary
      ? marginDelta(p.sellprice, dealGross, summary)
      : null
    out[p.id] = { summary, verdict: cmp.verdict, marginDelta: md }
  }
  return out
})

const lastFetchLabel = computed(() => {
  if (!lastFetchedAt.value) return null
  return timeAgo(new Date(lastFetchedAt.value), t)
})

const searchQuery = ref('')
// Default to validity so "can I buy this today?" is answered before anything
// else — upcoming offers were too easy to mistake for current ones.
const groupBy = ref<'validity' | 'retailer' | 'none'>('validity')
const listMode = ref<'active' | 'archived'>('active')

// Detail sheet state
const selectedDeal = ref<DedupedDeal | null>(null)
const sheetOpen = ref(false)

interface ProductStockTotals {
  warehouseQty: number
  trayStock: number
  trayCapacity: number
}

const productStock = ref<Map<string, ProductStockTotals>>(new Map())
const productStockLoading = ref(false)

const supabase = useSupabaseClient()

async function loadProductStock(productIds: string[]) {
  const missing = productIds.filter((id) => !productStock.value.has(id))
  if (missing.length === 0) return
  productStockLoading.value = true
  try {
    const [batchesRes, traysRes] = await Promise.all([
      supabase
        .from('warehouse_stock_batches')
        .select('product_id, quantity')
        .in('product_id', missing)
        .gt('quantity', 0),
      supabase
        .from('machine_trays')
        .select('product_id, current_stock, capacity')
        .in('product_id', missing),
    ])

    const next = new Map(productStock.value)
    for (const id of missing) {
      next.set(id, { warehouseQty: 0, trayStock: 0, trayCapacity: 0 })
    }
    for (const row of ((batchesRes.data ?? []) as Array<{ product_id: string; quantity: number }>)) {
      const entry = next.get(row.product_id)
      if (entry) entry.warehouseQty += row.quantity ?? 0
    }
    for (const row of ((traysRes.data ?? []) as Array<{ product_id: string; current_stock: number; capacity: number }>)) {
      const entry = next.get(row.product_id)
      if (entry) {
        entry.trayStock += row.current_stock ?? 0
        entry.trayCapacity += row.capacity ?? 0
      }
    }
    productStock.value = next
  } finally {
    productStockLoading.value = false
  }
}

function openDetail(deal: DedupedDeal) {
  selectedDeal.value = deal
  sheetOpen.value = true
  const ids = [
    ...deal.matchedProducts.map((p) => p.id),
    ...deal.matchedKeywords.flatMap((k) => k.products.map((p) => p.id)),
  ]
  if (ids.length > 0) void loadProductStock(ids)
}

function matchesSearch(d: DedupedDeal, q: string): boolean {
  if (!q) return true
  const hay = [
    d.primary.deal_title,
    d.retailer,
    ...d.matchedProducts.map((p) => p.name),
    ...d.matchedKeywords.map((k) => k.label ?? ''),
    ...d.matchedKeywords.flatMap((k) => k.products.map((p) => p.name)),
  ].join(' ').toLowerCase()
  return hay.includes(q)
}

const filteredDeals = computed<DedupedDeal[]>(() => {
  const source = listMode.value === 'archived' ? archivedDeals.value : visibleActiveDeals.value
  const q = searchQuery.value.trim().toLowerCase()
  if (!q) return source
  return source.filter((d) => matchesSearch(d, q))
})

/**
 * Pinned deals always show up first as a dedicated group, regardless of the
 * retailer/ungrouped toggle. Within the remaining groups the unpinned deals
 * are grouped normally so they don't show up twice.
 *
 * In the Archived view the pinned group is omitted — the user is explicitly
 * reviewing archived items there, and we don't double-flag pinned+archived.
 */
interface DealGroup {
  key: string
  label: string
  pinned: boolean
  deals: DedupedDeal[]
  /** Set for groups produced by the validity grouping (header styling). */
  validity?: 'now' | 'upcoming' | 'expired'
  /** Secondary header text, e.g. "in 3 days" for an upcoming start day. */
  sublabel?: string
}

function validityOf(deal: DedupedDeal): DealValidityInfo {
  return dealValidityInfo(deal.primary.valid_from, deal.primary.valid_until)
}

/** Stable sort: valid-today first, then upcoming by start day. */
function sortByValidity(list: DedupedDeal[]): DedupedDeal[] {
  return [...list].sort((a, b) => compareByValidity(validityOf(a), validityOf(b)))
}

const groupedFiltered = computed<DealGroup[]>(() => {
  const result: DealGroup[] = []
  const source = filteredDeals.value
  const isActive = listMode.value === 'active'

  const pinnedDeals = sortByValidity(isActive ? source.filter((d) => d.pinned) : [])
  const rest = sortByValidity(isActive ? source.filter((d) => !d.pinned) : source)

  if (pinnedDeals.length > 0) {
    result.push({
      key: '__pinned__',
      label: t('deals.pinnedGroup'),
      pinned: true,
      deals: pinnedDeals,
    })
  }

  if (groupBy.value === 'validity') {
    for (const section of groupByValidity(rest, validityOf)) {
      result.push({
        key: `__validity_${section.key}`,
        label: section.kind === 'now'
          ? t('deals.validNowGroup')
          : section.kind === 'expired'
            ? t('deals.expiredGroup')
            : t('deals.validFromDate', { date: formatDealDay(section.from!) }),
        sublabel: section.kind === 'upcoming' && section.startsInDays != null
          ? startsInLabel(section.startsInDays)
          : undefined,
        pinned: false,
        deals: section.items,
        validity: section.kind,
      })
    }
  } else if (groupBy.value === 'none') {
    if (rest.length > 0) {
      result.push({
        key: '__all__',
        label: t('deals.ungrouped'),
        pinned: false,
        deals: rest,
      })
    }
  } else {
    const byRetailer = new Map<string, DedupedDeal[]>()
    for (const deal of rest) {
      const existing = byRetailer.get(deal.retailer) ?? []
      existing.push(deal)
      byRetailer.set(deal.retailer, existing)
    }
    for (const [key, deals] of byRetailer) {
      result.push({ key, label: key, pinned: false, deals })
    }
  }

  return result
})

onMounted(async () => {
  await loadSettings()
  if (dealsEnabled.value) {
    await Promise.all([fetchUserStates(), fetchDeals(), fetchNewDealKeys()])
    await fetchEkSummaries()
  }
})

async function refresh() {
  await Promise.all([fetchUserStates(), fetchDeals(true), fetchNewDealKeys()])
  await fetchEkSummaries()
}

// ── Action handlers (keep detail sheet state in sync after mutation) ──────
async function toggleArchive(deal: DedupedDeal, e?: Event) {
  e?.stopPropagation()
  if (deal.archived) {
    await unarchiveDeal(deal.retailer, deal.offer_id)
  } else {
    await archiveDeal(deal.retailer, deal.offer_id)
    // If archiving from the detail sheet, close it afterwards.
    if (selectedDeal.value?.key === deal.key && sheetOpen.value) {
      sheetOpen.value = false
    }
  }
}

async function togglePin(deal: DedupedDeal, e?: Event) {
  e?.stopPropagation()
  if (deal.pinned) {
    await unpinDeal(deal.retailer, deal.offer_id)
  } else {
    await pinDeal(deal.retailer, deal.offer_id)
  }
}

function formatDiscount(pct: number | null): string {
  if (pct == null) return ''
  return `-${Math.abs(pct)}%`
}

interface DealValidity {
  status: 'upcoming' | 'active' | 'expiring' | 'expired'
  label: string
  cls: string
  badgeCls: string
}

/** "Mo., 28.09." — weekday first, since "is it Monday already?" is the question. */
function formatDealDay(d: Date): string {
  return new Intl.DateTimeFormat(locale.value, { weekday: 'short', day: '2-digit', month: '2-digit' }).format(d)
}

/** "Montag, 28. September" for the detail sheet. */
function formatDealDayLong(d: Date): string {
  return new Intl.DateTimeFormat(locale.value, { weekday: 'long', day: 'numeric', month: 'long' }).format(d)
}

/** "morgen" / "in 3 Tagen". */
function startsInLabel(days: number): string {
  return t('deals.startsInRel', days)
}

// Amber (not blue) for "not yet valid": blue next to the green price read as
// "fine, go", which is exactly the misreading this badge has to prevent.
const UPCOMING_BADGE_CLS = 'bg-amber-100 text-amber-900 ring-1 ring-inset ring-amber-300 dark:bg-amber-950 dark:text-amber-200 dark:ring-amber-800'

function dealValidity(validFrom: string | null, validUntil: string | null): DealValidity {
  const info = dealValidityInfo(validFrom, validUntil)

  switch (info.status) {
    case 'upcoming':
      return {
        status: 'upcoming',
        label: t('deals.validFromDate', { date: formatDealDay(info.from!) }),
        cls: 'text-amber-700 dark:text-amber-300 font-medium',
        badgeCls: UPCOMING_BADGE_CLS,
      }
    case 'expired':
      return {
        status: 'expired',
        label: t('deals.expired'),
        cls: 'text-muted-foreground line-through',
        badgeCls: 'bg-muted text-muted-foreground',
      }
    case 'expiring':
      return {
        status: 'expiring',
        label: info.daysLeft === 0
          ? t('deals.lastDay')
          : t('deals.daysLeft', { days: info.daysLeft }),
        cls: 'text-orange-600 dark:text-orange-400 font-medium',
        badgeCls: 'bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200',
      }
    default:
      return {
        status: 'active',
        label: info.daysLeft != null ? t('deals.daysLeft', { days: info.daysLeft }) : t('deals.activeNow'),
        cls: 'text-green-600 dark:text-green-400',
        badgeCls: 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200',
      }
  }
}

/** Formatted "Mo., 28.09. – Sa., 03.10." for the detail sheet. */
function validityRange(validFrom: string | null, validUntil: string | null): string {
  const info = dealValidityInfo(validFrom, validUntil)
  const parts = [info.from, info.until].map((d) => (d ? formatDealDay(d) : ''))
  if (info.from && info.until) return `${parts[0]} – ${parts[1]}`
  if (info.from) return t('deals.validFromDate', { date: parts[0] })
  if (info.until) return t('deals.validUntilDate', { date: parts[1] })
  return ''
}

const upcomingCount = computed(() => visibleActiveDeals.value.filter((d) => validityOf(d).status === 'upcoming').length)

const selectedValidity = computed(() => selectedDeal.value
  ? dealValidityInfo(selectedDeal.value.primary.valid_from, selectedDeal.value.primary.valid_until)
  : null)

function confidenceLevel(c: number): { label: string; cls: string } {
  if (c >= 0.85) return { label: t('deals.matchHigh'), cls: 'text-green-600 dark:text-green-400' }
  if (c >= 0.65) return { label: t('deals.matchMedium'), cls: 'text-yellow-600 dark:text-yellow-400' }
  return { label: t('deals.matchLow'), cls: 'text-orange-600 dark:text-orange-400' }
}

function highlightTokens(text: string, tokens: string[] | null): { text: string; matched: boolean }[] {
  if (!tokens || tokens.length === 0) return [{ text, matched: false }]

  const lower = text.toLowerCase()
  const segments: { start: number; end: number }[] = []

  for (const token of tokens) {
    let pos = 0
    while (pos < lower.length) {
      const idx = lower.indexOf(token.toLowerCase(), pos)
      if (idx === -1) break
      segments.push({ start: idx, end: idx + token.length })
      pos = idx + token.length
    }
  }

  if (segments.length === 0) return [{ text, matched: false }]

  segments.sort((a, b) => a.start - b.start)
  const merged: typeof segments = [segments[0]]
  for (let i = 1; i < segments.length; i++) {
    const last = merged[merged.length - 1]
    if (segments[i].start <= last.end) {
      last.end = Math.max(last.end, segments[i].end)
    } else {
      merged.push(segments[i])
    }
  }

  const result: { text: string; matched: boolean }[] = []
  let cursor = 0
  for (const seg of merged) {
    if (cursor < seg.start) {
      result.push({ text: text.slice(cursor, seg.start), matched: false })
    }
    result.push({ text: text.slice(seg.start, seg.end), matched: true })
    cursor = seg.end
  }
  if (cursor < text.length) {
    result.push({ text: text.slice(cursor), matched: false })
  }
  return result
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <div class="flex items-center justify-between">
      <h1 class="text-2xl font-semibold">{{ t('deals.title') }}</h1>
      <div class="flex items-center gap-2">
        <button
          v-if="dealsEnabled"
          :disabled="loading"
          class="inline-flex h-9 items-center gap-2 rounded-md border px-3 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
          @click="refresh()"
        >
          <IconRefresh class="size-4" :class="{ 'animate-spin': loading }" />
          {{ t('deals.refresh') }}
        </button>
      </div>
    </div>

    <!-- Feature not enabled -->
    <div v-if="!dealsEnabled" class="flex flex-col items-center justify-center gap-4 rounded-xl border bg-card p-12 text-center">
      <IconTag class="size-12 text-muted-foreground" />
      <div>
        <h2 class="text-lg font-semibold">{{ t('deals.notEnabled') }}</h2>
        <p class="mt-1 text-sm text-muted-foreground">{{ t('deals.notEnabledDescription') }}</p>
      </div>
      <NuxtLink
        v-if="role === 'admin'"
        to="/settings"
        class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
      >
        <IconSettings class="size-4" />
        {{ t('deals.goToSettings') }}
      </NuxtLink>
    </div>

    <!-- Enabled: show deals -->
    <template v-else>
      <Tabs default-value="deals" class="w-full">
        <TabsList>
          <TabsTrigger value="deals">{{ t('deals.title') }}</TabsTrigger>
          <TabsTrigger value="keywords">{{ t('deals.keywords.tabLabel') }}</TabsTrigger>
        </TabsList>

        <TabsContent value="deals" class="space-y-6">
          <!-- Error -->
          <div v-if="error" class="flex items-center gap-2 rounded-lg border border-destructive/50 bg-destructive/10 px-4 py-3 text-sm text-destructive">
            <IconAlertCircle class="size-4 shrink-0" />
            {{ error }}
          </div>
          <div
            v-if="userStateError"
            class="flex items-center gap-2 rounded-lg border border-destructive/50 bg-destructive/10 px-4 py-3 text-sm text-destructive"
          >
            <IconAlertCircle class="size-4 shrink-0" />
            <span class="min-w-0 flex-1 break-words">{{ userStateError }}</span>
          </div>

          <!-- KPI Cards -->
          <div class="grid grid-cols-2 gap-4 md:grid-cols-4">
            <div class="rounded-xl border bg-card p-4 shadow-sm">
              <p class="text-sm text-muted-foreground">{{ t('deals.totalDeals') }}</p>
              <p class="mt-1 text-2xl font-bold">{{ totalDeals }}</p>
              <p v-if="upcomingCount > 0" class="mt-0.5 text-xs font-medium text-amber-700 dark:text-amber-300">
                {{ t('deals.upcomingCountHint', { n: upcomingCount }) }}
              </p>
            </div>
            <div class="rounded-xl border bg-card p-4 shadow-sm">
              <p class="text-sm text-muted-foreground">{{ t('deals.retailers') }}</p>
              <p class="mt-1 text-2xl font-bold">{{ uniqueRetailers }}</p>
            </div>
            <div class="rounded-xl border bg-card p-4 shadow-sm">
              <p class="text-sm text-muted-foreground">{{ t('deals.avgDiscount') }}</p>
              <p class="mt-1 text-2xl font-bold">{{ avgDiscount ? `-${avgDiscount}%` : '—' }}</p>
            </div>
            <div class="rounded-xl border bg-card p-4 shadow-sm">
              <p class="text-sm text-muted-foreground">{{ t('deals.lastFetched') }}</p>
              <p class="mt-1 text-sm font-medium">
                {{ lastFetchLabel ?? '—' }}
              </p>
              <p v-if="fromCache" class="mt-0.5 text-xs text-muted-foreground">{{ t('deals.cached') }}</p>
            </div>
          </div>

          <!-- Active / Archived toggle -->
          <div class="flex flex-wrap items-center gap-2">
            <div class="flex gap-1 rounded-md border p-0.5">
              <button
                class="rounded-sm px-3 py-1 text-sm font-medium transition-colors"
                :class="listMode === 'active' ? 'bg-primary text-primary-foreground shadow-sm' : 'hover:bg-muted'"
                @click="listMode = 'active'"
              >
                {{ t('deals.activeTab') }}
              </button>
              <button
                class="inline-flex items-center gap-1.5 rounded-sm px-3 py-1 text-sm font-medium transition-colors"
                :class="listMode === 'archived' ? 'bg-primary text-primary-foreground shadow-sm' : 'hover:bg-muted'"
                @click="listMode = 'archived'"
              >
                <IconArchive class="size-3.5" />
                {{ t('deals.archivedTab') }}
                <Badge v-if="archivedCount > 0" variant="secondary" class="ml-1">{{ archivedCount }}</Badge>
              </button>
            </div>
          </div>

          <!-- Search & Grouping Controls -->
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
            <input
              v-model="searchQuery"
              type="text"
              :placeholder="t('deals.searchPlaceholder')"
              class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring sm:max-w-xs"
            />
            <div class="flex gap-1 rounded-md border p-0.5">
              <button
                class="rounded-sm px-3 py-1 text-sm font-medium transition-colors"
                :class="groupBy === 'validity' ? 'bg-primary text-primary-foreground shadow-sm' : 'hover:bg-muted'"
                @click="groupBy = 'validity'"
              >
                {{ t('deals.byValidity') }}
              </button>
              <button
                class="rounded-sm px-3 py-1 text-sm font-medium transition-colors"
                :class="groupBy === 'retailer' ? 'bg-primary text-primary-foreground shadow-sm' : 'hover:bg-muted'"
                @click="groupBy = 'retailer'"
              >
                {{ t('deals.byRetailer') }}
              </button>
              <button
                class="rounded-sm px-3 py-1 text-sm font-medium transition-colors"
                :class="groupBy === 'none' ? 'bg-primary text-primary-foreground shadow-sm' : 'hover:bg-muted'"
                @click="groupBy = 'none'"
              >
                {{ t('deals.ungrouped') }}
              </button>
            </div>
          </div>

          <!-- Loading skeleton -->
          <div v-if="loading && deals.length === 0" class="space-y-4">
            <div v-for="i in 3" :key="i" class="h-24 animate-pulse rounded-xl border bg-muted" />
          </div>

          <!-- No deal-source provider configured -->
          <div
            v-else-if="!loading && noProviders"
            class="flex flex-col items-center justify-center gap-3 rounded-xl border border-dashed bg-card p-12 text-center"
          >
            <IconPlug class="size-10 text-muted-foreground" />
            <div>
              <h2 class="text-base font-semibold">{{ t('deals.noProvidersTitle') }}</h2>
              <p class="mt-1 text-sm text-muted-foreground">{{ t('deals.noProvidersDescription') }}</p>
            </div>
            <NuxtLink
              v-if="role === 'admin'"
              to="/settings/extensions/deal-source"
              class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
            >
              <IconPlug class="size-4" />
              {{ t('deals.noProvidersAction') }}
            </NuxtLink>
          </div>

          <!-- Empty state -->
          <div
            v-else-if="!loading && filteredDeals.length === 0"
            class="flex flex-col items-center justify-center gap-3 rounded-xl border bg-card p-12 text-center"
          >
            <component :is="listMode === 'archived' ? IconArchive : IconTag" class="size-10 text-muted-foreground" />
            <p class="text-sm text-muted-foreground">
              {{ listMode === 'archived' ? t('deals.noArchived') : t('deals.noDeals') }}
            </p>
          </div>

          <!-- Deal groups -->
          <div v-else class="space-y-6">
            <div
              v-for="group in groupedFiltered"
              :key="group.key"
              class="space-y-3"
            >
              <!-- Pinned group has its own distinctive header with a pin icon. -->
              <div
                v-if="group.pinned"
                class="flex items-center gap-2 border-b border-primary/30 pb-2"
              >
                <IconPin class="size-5 text-primary" />
                <h2 class="text-lg font-semibold text-primary">{{ group.label }}</h2>
                <Badge variant="default">{{ group.deals.length }}</Badge>
              </div>
              <!-- Validity headers: "valid now" vs. one per upcoming start day. -->
              <div
                v-else-if="group.validity"
                class="flex flex-wrap items-center gap-x-2 gap-y-1 border-b pb-2"
                :class="group.validity === 'upcoming' ? 'border-amber-300 dark:border-amber-800' : 'border-border'"
              >
                <IconCircleCheck v-if="group.validity === 'now'" class="size-5 text-green-600 dark:text-green-400" />
                <IconCalendarClock v-else-if="group.validity === 'upcoming'" class="size-5 text-amber-600 dark:text-amber-400" />
                <IconAlertCircle v-else class="size-5 text-muted-foreground" />
                <h2
                  class="text-lg font-semibold first-letter:uppercase"
                  :class="{ 'text-amber-800 dark:text-amber-200': group.validity === 'upcoming' }"
                >
                  {{ group.label }}
                </h2>
                <span v-if="group.sublabel" class="text-sm text-amber-700 dark:text-amber-300">{{ group.sublabel }}</span>
                <Badge variant="secondary">{{ group.deals.length }}</Badge>
              </div>
              <!-- Retailer header (only shown when grouped by retailer). -->
              <div
                v-else-if="groupBy === 'retailer' && group.key !== '__all__'"
                class="flex items-center gap-2"
              >
                <IconBuildingStore class="size-5 text-muted-foreground" />
                <h2 class="text-lg font-semibold">{{ group.label }}</h2>
                <Badge variant="secondary">{{ group.deals.length }}</Badge>
              </div>

              <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                <div
                  v-for="deal in group.deals"
                  :key="deal.key"
                  class="group relative flex gap-3 rounded-xl border bg-card p-4 text-left shadow-sm transition-colors hover:bg-muted/50"
                  :class="{
                    'ring-1 ring-primary/40': deal.pinned,
                    'border-dashed border-amber-400 bg-amber-50/50 dark:border-amber-700 dark:bg-amber-950/20': validityOf(deal).status === 'upcoming',
                  }"
                >
                  <!-- Pinned marker (top-left) -->
                  <div
                    v-if="deal.pinned"
                    class="absolute -left-1 -top-1 flex size-6 items-center justify-center rounded-full bg-primary text-primary-foreground shadow"
                    :title="t('deals.pinned')"
                  >
                    <IconPin class="size-3" />
                  </div>
                  <!-- New (unhandled) marker — stays until pinned/archived. -->
                  <div
                    v-else-if="isNew(deal)"
                    class="absolute -left-1 -top-1 z-10 rounded-full bg-emerald-500 px-1.5 py-0.5 text-[10px] font-bold uppercase leading-none tracking-wide text-white shadow"
                    :title="t('deals.newTooltip')"
                  >
                    {{ t('deals.new') }}
                  </div>

                  <!-- Quick actions (top-right). On touch devices opacity-100 always;
                       on desktop fade in on hover/focus to keep the card clean. -->
                  <div class="absolute right-2 top-2 z-10 flex gap-1 opacity-100 transition-opacity sm:opacity-0 sm:group-hover:opacity-100 sm:focus-within:opacity-100">
                    <button
                      type="button"
                      class="inline-flex size-8 items-center justify-center rounded-md border bg-card/90 shadow-sm backdrop-blur transition-colors hover:bg-muted"
                      :class="{ 'border-primary text-primary': deal.pinned }"
                      :title="deal.pinned ? t('deals.unpin') : t('deals.pin')"
                      @click.stop="togglePin(deal, $event)"
                    >
                      <IconPinnedOff v-if="deal.pinned" class="size-4" />
                      <IconPin v-else class="size-4" />
                    </button>
                    <button
                      type="button"
                      class="inline-flex size-8 items-center justify-center rounded-md border bg-card/90 shadow-sm backdrop-blur transition-colors hover:bg-muted"
                      :title="deal.archived ? t('deals.unarchive') : t('deals.archive')"
                      @click.stop="toggleArchive(deal, $event)"
                    >
                      <IconArchiveOff v-if="deal.archived" class="size-4" />
                      <IconArchive v-else class="size-4" />
                    </button>
                  </div>

                  <!-- Card body (click to open detail) -->
                  <button
                    type="button"
                    class="flex min-w-0 flex-1 gap-3 text-left"
                    @click="openDetail(deal)"
                  >
                    <!-- Deal image -->
                    <div class="shrink-0">
                      <img
                        v-if="deal.primary.image_url || deal.primary.image_url_large"
                        :src="deal.primary.image_url ?? deal.primary.image_url_large!"
                        :alt="deal.primary.deal_title"
                        class="size-16 rounded-lg bg-muted object-cover"
                        loading="lazy"
                      />
                      <div v-else class="flex size-16 items-center justify-center rounded-lg bg-muted">
                        <IconTag class="size-6 text-muted-foreground" />
                      </div>
                    </div>

                    <!-- Deal info -->
                    <div class="min-w-0 flex-1">
                      <!-- Not valid yet: first thing on the card, so nobody drives there for nothing. -->
                      <div
                        v-if="validityOf(deal).status === 'upcoming'"
                        class="mb-1.5 inline-flex max-w-full items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold"
                        :class="UPCOMING_BADGE_CLS"
                      >
                        <IconCalendarClock class="size-3.5 shrink-0" />
                        <span class="truncate">
                          {{ dealValidity(deal.primary.valid_from, deal.primary.valid_until).label }}
                          · {{ startsInLabel(validityOf(deal).startsInDays!) }}
                        </span>
                      </div>
                      <div class="flex items-start justify-between gap-2 pr-16">
                        <p class="line-clamp-2 text-sm font-medium leading-tight">
                          {{ deal.primary.deal_title }}
                        </p>
                        <Badge v-if="deal.primary.discount_pct" variant="destructive" class="shrink-0">
                          {{ formatDiscount(deal.primary.discount_pct) }}
                        </Badge>
                      </div>

                      <p class="mt-1 text-xs text-muted-foreground">{{ deal.retailer }}</p>

                      <!-- Matched products / keyword groups summary -->
                      <div class="mt-2 flex flex-wrap gap-1">
                        <Badge
                          v-for="kw in deal.matchedKeywords"
                          :key="kw.id"
                          variant="secondary"
                          class="gap-1"
                        >
                          <IconTag class="size-3" />
                          {{ kw.label ?? kw.matched_term ?? t('deals.keywords.tabLabel') }}
                        </Badge>
                        <Badge
                          v-if="deal.matchedProducts.length === 1"
                          variant="outline"
                          class="truncate max-w-[14rem]"
                        >
                          {{ deal.matchedProducts[0].name }}
                        </Badge>
                        <Badge
                          v-else-if="deal.matchedProducts.length > 1"
                          variant="outline"
                        >
                          {{ t('deals.matchedProductCount', { n: deal.matchedProducts.length }) }}
                        </Badge>
                      </div>

                      <!-- Price row -->
                      <div class="mt-2 flex items-center gap-2">
                        <span
                          v-if="deal.primary.deal_price != null"
                          class="text-sm font-bold"
                          :class="validityOf(deal).status === 'upcoming' ? 'text-foreground' : 'text-green-600 dark:text-green-400'"
                        >
                          {{ deal.primary.deal_price.toFixed(2) }}&euro;
                        </span>
                        <span v-if="ekPill(deal)" :class="ekPill(deal)!.cls" class="ml-2 text-xs font-medium">
                          {{ ekPill(deal)!.label }}
                        </span>
                        <span v-if="deal.primary.regular_price != null" class="text-xs text-muted-foreground line-through">
                          {{ deal.primary.regular_price.toFixed(2) }}&euro;
                        </span>
                        <span
                          v-if="deal.primary.requires_app"
                          class="inline-flex items-center gap-0.5 rounded-full bg-purple-100 px-1.5 py-0.5 text-[10px] font-medium text-purple-800 dark:bg-purple-900 dark:text-purple-200"
                        >
                          <IconDeviceMobile class="size-2.5" />
                          App
                        </span>
                      </div>

                      <!-- Validity & confidence -->
                      <div class="mt-1 flex items-center gap-2 text-[11px]">
                        <span
                          v-if="validityOf(deal).status !== 'upcoming'"
                          class="inline-flex rounded-full px-1.5 py-0.5 text-[10px] font-medium"
                          :class="dealValidity(deal.primary.valid_from, deal.primary.valid_until).badgeCls"
                        >
                          {{ dealValidity(deal.primary.valid_from, deal.primary.valid_until).label }}
                        </span>
                        <span :class="confidenceLevel(deal.primary.confidence).cls">
                          {{ Math.round(deal.primary.confidence * 100) }}% {{ t('deals.match') }}
                        </span>
                      </div>
                    </div>
                  </button>
                </div>
              </div>
            </div>
          </div>

          <details v-if="listMode !== 'archived' && suppressedActiveDeals.length" class="mt-4 rounded-md border px-3 py-2 text-sm">
            <summary class="cursor-pointer select-none text-muted-foreground">
              {{ t('deals.ekHiddenCount', { n: suppressedActiveDeals.length }) }} · {{ t('deals.ekShow') }}
            </summary>
            <ul class="mt-2 space-y-1">
              <li v-for="deal in suppressedActiveDeals" :key="deal.key" class="flex items-center gap-2">
                <span class="flex-1 truncate">{{ deal.primary.deal_title }} · {{ deal.retailer }}</span>
                <span class="text-red-600 dark:text-red-400">{{ t('deals.ekLikelyMismatch') }}</span>
                <button type="button" class="text-primary hover:underline" @click="openDetail(deal)">{{ t('common.details') }}</button>
              </li>
            </ul>
          </details>
        </TabsContent>

        <TabsContent value="keywords">
          <DealKeywordList />
        </TabsContent>
      </Tabs>
    </template>

    <!-- ─── Detail Sheet ────────────────────────────────────────────── -->
    <Sheet v-model:open="sheetOpen">
      <SheetContent class="w-full overflow-y-auto px-5 sm:max-w-md sm:px-6">
        <SheetHeader>
          <SheetTitle>{{ t('deals.detailTitle') }}</SheetTitle>
          <SheetDescription>{{ selectedDeal?.retailer }}</SheetDescription>
        </SheetHeader>

        <div v-if="selectedDeal" class="mt-5 space-y-5">
          <!-- Action row: pin / archive -->
          <div class="flex gap-2">
            <button
              type="button"
              class="inline-flex flex-1 items-center justify-center gap-1.5 rounded-lg border px-3 py-2 text-xs font-medium transition-colors hover:bg-muted sm:text-sm"
              :class="{ 'border-primary bg-primary/10 text-primary': selectedDeal.pinned }"
              @click="togglePin(selectedDeal)"
            >
              <IconPinnedOff v-if="selectedDeal.pinned" class="size-3.5" />
              <IconPin v-else class="size-3.5" />
              {{ selectedDeal.pinned ? t('deals.unpin') : t('deals.pin') }}
            </button>
            <button
              type="button"
              class="inline-flex flex-1 items-center justify-center gap-1.5 rounded-lg border px-3 py-2 text-xs font-medium transition-colors hover:bg-muted sm:text-sm"
              @click="toggleArchive(selectedDeal)"
            >
              <IconArchiveOff v-if="selectedDeal.archived" class="size-3.5" />
              <IconArchive v-else class="size-3.5" />
              {{ selectedDeal.archived ? t('deals.unarchive') : t('deals.archive') }}
            </button>
          </div>

          <!-- Hero: image + price overlay -->
          <div class="relative h-36 overflow-hidden rounded-xl border sm:h-44">
            <div
              v-if="selectedDeal.primary.image_url_large"
              class="absolute inset-0 scale-125 bg-cover bg-center opacity-40 blur-xl"
              :style="{ backgroundImage: `url(${selectedDeal.primary.image_url_large})` }"
            />
            <div v-else class="absolute inset-0 bg-muted" />
            <img
              v-if="selectedDeal.primary.image_url_large"
              :src="selectedDeal.primary.image_url_large"
              :alt="selectedDeal.primary.deal_title"
              class="relative size-full object-contain"
              loading="lazy"
            />
            <div v-else class="flex h-32 items-center justify-center">
              <IconTag class="size-10 text-muted-foreground" />
            </div>
            <div v-if="selectedDeal.primary.deal_price != null" class="absolute bottom-2 right-2 flex items-center gap-1.5 rounded-lg bg-black/70 px-2.5 py-1 backdrop-blur-sm">
              <span class="text-base font-bold text-green-400">
                {{ selectedDeal.primary.deal_price.toFixed(2) }}&euro;
              </span>
              <span v-if="selectedDeal.primary.regular_price != null" class="text-xs text-white/60 line-through">
                {{ selectedDeal.primary.regular_price.toFixed(2) }}&euro;
              </span>
              <Badge v-if="selectedDeal.primary.discount_pct" variant="destructive" class="px-1.5 py-0 text-[10px]">
                {{ formatDiscount(selectedDeal.primary.discount_pct) }}
              </Badge>
            </div>
          </div>

          <!-- Not valid yet: explicit callout right under the hero, above the title. -->
          <div
            v-if="selectedValidity?.status === 'upcoming'"
            class="flex items-start gap-3 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2.5 text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100"
          >
            <IconCalendarClock class="mt-0.5 size-5 shrink-0 text-amber-600 dark:text-amber-400" />
            <div class="text-sm">
              <p class="font-semibold">{{ t('deals.notYetValidTitle') }}</p>
              <p>
                {{ t('deals.notYetValidBody', {
                  date: formatDealDayLong(selectedValidity.from!),
                  rel: startsInLabel(selectedValidity.startsInDays!),
                }) }}
              </p>
            </div>
          </div>

          <!-- Title + badges row -->
          <div class="space-y-2.5">
            <h3 class="text-sm font-semibold leading-snug sm:text-base">
              {{ selectedDeal.primary.deal_title }}
            </h3>

            <div class="flex flex-wrap items-center gap-1.5">
              <span
                v-if="selectedDeal.primary.valid_from || selectedDeal.primary.valid_until"
                class="inline-flex rounded-full px-2 py-0.5 text-[11px] font-medium"
                :class="dealValidity(selectedDeal.primary.valid_from, selectedDeal.primary.valid_until).badgeCls"
              >
                {{ dealValidity(selectedDeal.primary.valid_from, selectedDeal.primary.valid_until).label }}
              </span>
              <span v-if="selectedDeal.primary.valid_from || selectedDeal.primary.valid_until" class="text-xs text-muted-foreground">
                {{ validityRange(selectedDeal.primary.valid_from, selectedDeal.primary.valid_until) }}
              </span>
              <span v-if="selectedDeal.primary.requires_app" class="inline-flex items-center gap-0.5 rounded-full bg-purple-100 px-2 py-0.5 text-[11px] font-medium text-purple-800 dark:bg-purple-900 dark:text-purple-200">
                <IconDeviceMobile class="size-3" />
                App
              </span>
            </div>
          </div>

          <!-- App required notice -->
          <div v-if="selectedDeal.primary.requires_app" class="flex items-center gap-2 rounded-lg border border-purple-200 bg-purple-50 px-3 py-2 dark:border-purple-800 dark:bg-purple-950">
            <IconDeviceMobile class="size-4 shrink-0 text-purple-600 dark:text-purple-400" />
            <p class="text-xs text-purple-800 dark:text-purple-200">
              {{ t('deals.requiresApp', { retailer: selectedDeal.retailer }) }}
            </p>
          </div>

          <!-- External links -->
          <div class="flex gap-2">
            <a
              v-if="selectedDeal.primary.source_url"
              :href="selectedDeal.primary.source_url"
              target="_blank"
              rel="noopener"
              class="inline-flex flex-1 items-center justify-center gap-1.5 rounded-lg border px-3 py-2 text-xs font-medium transition-colors hover:bg-muted sm:text-sm"
            >
              <IconExternalLink class="size-3.5" />
              {{ t('deals.viewProspekt') }}
            </a>
            <a
              v-if="selectedDeal.primary.external_url"
              :href="selectedDeal.primary.external_url"
              target="_blank"
              rel="noopener"
              class="inline-flex flex-1 items-center justify-center gap-1.5 rounded-lg border px-3 py-2 text-xs font-medium transition-colors hover:bg-muted sm:text-sm"
            >
              <IconExternalLink class="size-3.5" />
              {{ t('deals.viewAllOffers', { retailer: selectedDeal.retailer }) }}
            </a>
          </div>

          <!-- Matched keyword groups -->
          <div
            v-if="selectedDeal.matchedKeywords.length > 0"
            class="space-y-2 rounded-xl border bg-card p-4"
          >
            <h4 class="text-xs font-semibold">{{ t('deals.matchedKeywords') }}</h4>
            <div v-for="kw in selectedDeal.matchedKeywords" :key="kw.id" class="space-y-1.5">
              <div class="flex items-center gap-2">
                <Badge variant="secondary" class="gap-1">
                  <IconTag class="size-3" />
                  {{ kw.label ?? kw.matched_term ?? t('deals.keywords.tabLabel') }}
                </Badge>
                <span v-if="kw.matched_term" class="text-xs text-muted-foreground">
                  {{ t('deals.keywords.matchedVia', { term: kw.matched_term }) }}
                </span>
              </div>
              <ul v-if="kw.products.length > 0" class="ml-1 space-y-1">
                <li v-for="p in kw.products" :key="p.id" class="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                  <NuxtLink :to="`/products/${p.id}`" class="hover:underline">{{ p.name }}</NuxtLink>
                  <span class="flex items-center gap-1.5 text-[10px]">
                    <span
                      :class="[
                        'inline-flex items-center gap-0.5 rounded-full px-1.5 py-0.5 font-medium tabular-nums',
                        (productStock.get(p.id)?.warehouseQty ?? 0) > 0
                          ? 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200'
                          : 'bg-muted text-muted-foreground',
                      ]"
                      :title="t('deals.stockWarehouse')"
                    >
                      <IconBuildingWarehouse class="size-2.5" />
                      {{ productStock.get(p.id)?.warehouseQty ?? 0 }}
                    </span>
                    <span
                      :class="[
                        'inline-flex items-center gap-0.5 rounded-full px-1.5 py-0.5 font-medium tabular-nums',
                        (productStock.get(p.id)?.trayStock ?? 0) > 0
                          ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200'
                          : 'bg-muted text-muted-foreground',
                      ]"
                      :title="t('deals.stockMachines')"
                    >
                      <IconBox class="size-2.5" />
                      {{ productStock.get(p.id)?.trayStock ?? 0 }}<template v-if="(productStock.get(p.id)?.trayCapacity ?? 0) > 0">/{{ productStock.get(p.id)!.trayCapacity }}</template>
                    </span>
                  </span>
                </li>
              </ul>
              <p v-else class="text-xs italic text-muted-foreground">
                {{ t('deals.keywords.noLinkedProducts') }}
              </p>
            </div>
          </div>

          <!-- Matched products (fuzzy-name matches) -->
          <div
            v-if="selectedDeal.matchedProducts.length > 0"
            class="space-y-3 rounded-xl border bg-card p-4"
          >
            <div class="flex items-center justify-between">
              <h4 class="text-xs font-semibold">
                {{ selectedDeal.matchedProducts.length === 1
                  ? t('deals.yourProduct')
                  : t('deals.matchedProductsTitle', { n: selectedDeal.matchedProducts.length })
                }}
              </h4>
              <span :class="confidenceLevel(selectedDeal.primary.confidence).cls" class="text-xs font-medium">
                {{ Math.round(selectedDeal.primary.confidence * 100) }}% {{ confidenceLevel(selectedDeal.primary.confidence).label }}
              </span>
            </div>

            <ul class="space-y-1.5">
              <li v-for="p in selectedDeal.matchedProducts" :key="p.id" class="flex flex-wrap items-center justify-between gap-2">
                <NuxtLink :to="`/products/${p.id}`" class="min-w-0 flex-1 truncate text-xs hover:underline">
                  <template v-for="(seg, idx) in highlightTokens(p.name, selectedDeal.primary.matched_tokens)" :key="idx">
                    <mark v-if="seg.matched" class="rounded-sm bg-green-200 px-0.5 dark:bg-green-900">{{ seg.text }}</mark>
                    <span v-else>{{ seg.text }}</span>
                  </template>
                </NuxtLink>
                <span class="flex items-center gap-1.5 shrink-0">
                  <span
                    :class="[
                      'inline-flex items-center gap-0.5 rounded-full px-1.5 py-0.5 text-[10px] font-medium tabular-nums',
                      (productStock.get(p.id)?.warehouseQty ?? 0) > 0
                        ? 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200'
                        : 'bg-muted text-muted-foreground',
                    ]"
                    :title="t('deals.stockWarehouse')"
                  >
                    <IconBuildingWarehouse class="size-2.5" />
                    {{ productStock.get(p.id)?.warehouseQty ?? 0 }}
                  </span>
                  <span
                    :class="[
                      'inline-flex items-center gap-0.5 rounded-full px-1.5 py-0.5 text-[10px] font-medium tabular-nums',
                      (productStock.get(p.id)?.trayStock ?? 0) > 0
                        ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200'
                        : 'bg-muted text-muted-foreground',
                    ]"
                    :title="t('deals.stockMachines')"
                  >
                    <IconBox class="size-2.5" />
                    {{ productStock.get(p.id)?.trayStock ?? 0 }}<template v-if="(productStock.get(p.id)?.trayCapacity ?? 0) > 0">/{{ productStock.get(p.id)!.trayCapacity }}</template>
                  </span>
                  <span v-if="p.sellprice != null" class="text-[10px] text-muted-foreground">
                    {{ p.sellprice.toFixed(2) }}&euro;
                  </span>
                  <span :class="confidenceLevel(p.confidence).cls" class="text-[10px] font-medium tabular-nums">
                    {{ Math.round(p.confidence * 100) }}%
                  </span>
                </span>
                <div class="mt-1 w-full text-xs">
                  <template v-if="detailComparisons[p.id]?.summary?.ek_count">
                    <span class="text-muted-foreground">
                      {{ t('deals.ekVsUsual', {
                        deal: formatCurrency(selectedDeal.primary.deal_price ?? 0, locale),
                        ek: formatCurrency(detailComparisons[p.id]!.summary!.newest_gross ?? 0, locale),
                      }) }}
                    </span>
                    <span v-if="detailComparisons[p.id]?.marginDelta" class="block text-muted-foreground">
                      {{ t('deals.ekMarginEffect', {
                        from: detailComparisons[p.id]!.marginDelta!.currentPct.toFixed(0),
                        to: detailComparisons[p.id]!.marginDelta!.dealPct.toFixed(0),
                      }) }}
                    </span>
                  </template>
                  <button v-else type="button" class="text-primary hover:underline" @click.stop="openEkModal(p.id)">
                    {{ t('deals.ekNone') }} · {{ t('deals.ekAdd') }}
                  </button>
                </div>
              </li>
            </ul>

            <!-- Matched tokens chips -->
            <div v-if="selectedDeal.primary.matched_tokens?.length" class="flex flex-wrap gap-1 border-t pt-2">
              <span
                v-for="token in selectedDeal.primary.matched_tokens"
                :key="token"
                class="inline-flex items-center gap-0.5 rounded-full bg-green-100 px-1.5 py-0.5 text-[10px] font-medium text-green-800 dark:bg-green-900 dark:text-green-200"
              >
                <IconCheck class="size-2.5" />
                {{ token }}
              </span>
            </div>
          </div>
        </div>
      </SheetContent>
    </Sheet>

    <ProductFormModal v-model:open="ekModalOpen" :product-id="ekModalProductId" @saved="onEkSaved" />
  </div>
</template>
