<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import SectionCards from "@/components/SectionCards.vue"
import ChartAreaInteractive from "@/components/ChartAreaInteractive.vue"
import { dailySeries, type DailyBucket } from "~/lib/barChart"
import { useLocalStorage } from "@vueuse/core"
import DashboardTopProducts from "@/components/DashboardTopProducts.vue"
import DashboardMachineList from "@/components/DashboardMachineList.vue"
import DashboardRecentSales from "@/components/DashboardRecentSales.vue"
import DashboardActivityFeed from "@/components/DashboardActivityFeed.vue"
import type { DashboardMachine } from "@/components/DashboardMachineList.vue"
import type { RecentSale } from "@/components/DashboardRecentSales.vue"
import type { ActivityEntry } from "@/components/DashboardActivityFeed.vue"
import type { TopProduct } from "@/components/DashboardTopProducts.vue"
import { IconAlertTriangle, IconSparkles, IconRefresh, IconLoader2, IconTag } from '@tabler/icons-vue'
import { useInsights, sortedRecommendations, priorityVariant, recommendationTypeLabel } from '@/composables/useInsights'
import { expirationStatus } from '@/composables/useWarehouse'
import { getProductImageUrl } from '@/composables/useProducts'
import { buildWarehouseStockInfo, computeStockHealthPerMachine, countMachineStockBuckets } from '@/lib/stock-health'
import { timeAgo } from '@/lib/utils'
import { summarizeFleet } from "@/lib/connectivity"

const { t } = useI18n()
const supabase = useSupabaseClient()
const { fetchOrganization } = useOrganization()
const { onResume } = useAppResume()

// ── KPI state ─────────────────────────────────────────────────────────────────
const todaySales = ref(0)
const todaySalesCount = ref(0)
const yesterdayRevenue = ref(0)
const yesterdaySalesCount = ref(0)
const weekSales = ref(0)
const weekSalesCount = ref(0)
const lastWeekSales = ref(0)
const lastWeekSalesCount = ref(0)
const monthSales = ref(0)
const monthSalesCount = ref(0)
const lastMonthSales = ref(0)
const lastMonthSalesCount = ref(0)
// Every machine's device (null = machine without a device) — the whole fleet,
// not just the six machines the list shows.
type FleetEmbedded = { id: string; status: string | null; status_at: string | null; online_since: string | null; mdb_diagnostics: unknown } | null
const fleetDevices = ref<FleetEmbedded[]>([])
const conn = useConnectivity()
const fleet = computed(() => summarizeFleet(fleetDevices.value.map(e => conn.of(e))))
const fleetDetails = computed(() => {
  const f = fleet.value
  const readerInactive = fleetDevices.value.filter(e => conn.of(e).reader === 'inactive').length
  const parts = [t('connectivity.fleet.onlineOf', { online: f.online, devices: f.devices })]
  if (f.offline) parts.push(t('connectivity.fleet.offline', { count: f.offline }))
  if (f.stale) parts.push(t('connectivity.fleet.stale', { count: f.stale }))
  if (readerInactive) parts.push(t('connectivity.fleet.readerInactive', { count: readerInactive }, readerInactive))
  return parts.join(' · ')
})
const totalMachines = ref(0)
const stockCritical = ref(0)
const stockLow = ref(0)
const stockFill = ref(0)
const stockSwap = ref(0)
const warehouseBelowMin = ref(0)
const warehouseExpiringSoon = ref(0)
const newDealsCount = ref(0)

const machinesNeedingRefill = ref(0)

// ── Company insights ──────────────────────────────────────────────────────────
const { companyData: companyInsights, companyLoading, companyError, fetchCompanyInsights, history: companyHistory, historyLoading: companyHistoryLoading, fetchHistory: fetchCompanyHistory } = useInsights()
const companyInsightsExpanded = ref(false)

// On mount: load latest from history (DB read, no Anthropic call) + full history list
onMounted(async () => {
  await fetchCompanyHistory()
  // Show the most recent history entry as the current result
  if (companyHistory.value.length > 0) {
    const latest = companyHistory.value[0]
    companyInsights.value = {
      generated_at: latest.generated_at,
      period_days: latest.period_days,
      type: 'company',
      recommendations: latest.recommendations ?? [],
      summary: latest.summary ?? '',
      trends: latest.trends ?? null,
      cached: true,
    }
  }
})

function generateCompanyInsights() {
  fetchCompanyInsights()
}

function refreshCompanyInsights() {
  fetchCompanyInsights(30, true)
}

const companyHistoryExpanded = ref<string | null>(null)
function toggleCompanyHistoryEntry(id: string) {
  companyHistoryExpanded.value = companyHistoryExpanded.value === id ? null : id
}

// ── Chart + sections ──────────────────────────────────────────────────────────
const dailySalesChart7 = ref<DailyBucket[]>([])
const dailySalesChart30 = ref<DailyBucket[]>([])
// 7 or 30 days in the dashboard chart; remembered per browser.
const chartDays = useLocalStorage<7 | 30>('dashboard-chart-days', 7, { initOnMounted: true })
const dailySalesChart = computed(() => (chartDays.value === 30 ? dailySalesChart30.value : dailySalesChart7.value))
const topProducts = ref<TopProduct[]>([])
const dashboardMachines = ref<DashboardMachine[]>([])
const recentSales = ref<RecentSale[]>([])
const recentActivity = ref<ActivityEntry[]>([])


// Re-fetch all dashboard data when app resumes from background (iOS PWA etc.)
onResume(() => loadDashboard())
usePullToRefresh(() => loadDashboard())

// Track realtime channel for cleanup
let realtimeChannel: ReturnType<typeof supabase.channel> | null = null
onUnmounted(() => { if (realtimeChannel) supabase.removeChannel(realtimeChannel) })

onMounted(async () => {
  await fetchOrganization()
  await loadDashboard()

  // Subscribe to live updates
  const channel = supabase
    .channel('dashboard-realtime')
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'sales' },
      (payload) => {
        const sale = payload.new as Record<string, any>
        const price = sale.item_price ?? 0

        // Update KPI totals
        const saleDate = new Date(sale.created_at)
        const now = new Date()
        const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        const weekStart = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000)
        const monthStart = new Date(now.getFullYear(), now.getMonth(), 1)

        if (saleDate >= todayStart) {
          todaySales.value += price
          todaySalesCount.value += 1
        }
        if (saleDate >= weekStart) { weekSales.value += price; weekSalesCount.value += 1 }
        if (saleDate >= monthStart) { monthSales.value += price; monthSalesCount.value += 1 }

        // Update machine revenue in list
        if (sale.machine_id) {
          const m = dashboardMachines.value.find(dm => dm.id === sale.machine_id)
          if (m && saleDate >= todayStart) {
            m.today_revenue += price
            m.last_sale_at = sale.created_at
          }
        }

        // Prepend to recent sales (resolve product name async)
        const newSale: RecentSale = {
          id: sale.id,
          created_at: sale.created_at,
          item_price: price,
          item_number: sale.item_number ?? 0,
          channel: sale.channel ?? '',
          machine_name: sale.machine_id
            ? (dashboardMachines.value.find(dm => dm.id === sale.machine_id)?.name ?? null)
            : null,
          product_id: sale.product_id ?? null,
          product_name: null,
          product_image_url: null,
        }
        // Resolve product: prefer snapshotted product_id from trigger, fallback to tray
        const productId = sale.product_id
        if (productId) {
          supabase
            .from('products')
            .select('name, image_path')
            .eq('id', productId)
            .maybeSingle()
            .then(({ data: p }) => {
              if (p) {
                newSale.product_name = (p as any).name
                newSale.product_image_url = (p as any).image_path ? getProductImageUrl((p as any).image_path) : null
                recentSales.value = [...recentSales.value]
              }
            })
        } else if (sale.machine_id && sale.item_number != null) {
          // Fallback for old sales or edge cases where trigger didn't stamp product_id
          supabase
            .from('machine_trays')
            .select('product_id, products(name, image_path)')
            .eq('machine_id', sale.machine_id)
            .eq('item_number', sale.item_number)
            .maybeSingle()
            .then(({ data }) => {
              const p = (data as any)?.products
              if (p) {
                newSale.product_name = p.name
                newSale.product_image_url = p.image_path ? getProductImageUrl(p.image_path) : null
                newSale.product_id = (data as any)?.product_id ?? null
                recentSales.value = [...recentSales.value]
              }
            })
        }
        recentSales.value.unshift(newSale)
        if (recentSales.value.length > 10) recentSales.value.pop()
      }
    )
    .on(
      'postgres_changes',
      { event: 'UPDATE', schema: 'public', table: 'embeddeds' },
      (payload) => {
        // Heartbeats only move status_at, so every update counts, not just status changes.
        const updated = payload.new as Record<string, any> | undefined
        if (!updated?.id) return
        const apply = (e: NonNullable<FleetEmbedded>) => {
          e.status = updated.status ?? e.status
          e.status_at = updated.status_at ?? e.status_at
          if (updated.online_since !== undefined) e.online_since = updated.online_since
          if (updated.mdb_diagnostics !== undefined) e.mdb_diagnostics = updated.mdb_diagnostics
        }
        const fe = fleetDevices.value.find(e => e?.id === updated.id)
        if (fe) apply(fe)
        const m = dashboardMachines.value.find(dm => dm.embedded?.id === updated.id)
        if (m?.embedded) apply(m.embedded)
      }
    )
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'vendingMachine' },
      () => {
        totalMachines.value++
      }
    )
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'activity_log' },
      (payload) => {
        const entry = payload.new as ActivityEntry
        const userDisplay = (entry.metadata as any)?._user_display
          || (entry.metadata as any)?._user_email
          || 'System'
        recentActivity.value.unshift({ ...entry, user_display: userDisplay })
        if (recentActivity.value.length > 8) recentActivity.value.pop()
      }
    )
    .subscribe((_status, err) => {
      if (err) console.error('[realtime] dashboard channel error:', err)
    })

  realtimeChannel = channel
})

// The 30-day chart and the top products both read every sale of the last 30
// days. Paged, because PostgREST caps a response at max_rows (1000) and a busy
// fleet passes that in 30 days: the chart would silently lose its oldest days.
async function fetchLast30DaysSales(since: string) {
  const PAGE = 1000
  const rows: { item_price: number; created_at: string; machine_id: string | null; item_number: number; product_id: string | null }[] = []
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from('sales')
      .select('item_price, created_at, machine_id, item_number, product_id')
      .gte('created_at', since)
      .order('id', { ascending: true })
      .range(from, from + PAGE - 1)
    if (error) return { data: rows.length ? rows : null, error }
    rows.push(...((data ?? []) as typeof rows))
    if (!data || data.length < PAGE) return { data: rows, error: null }
  }
}

async function loadDashboard() {
  const now = new Date()
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString()
  const yesterdayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1).toISOString()
  const weekStart = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString()
  const lastWeekStart = new Date(now.getTime() - 14 * 24 * 60 * 60 * 1000).toISOString()
  const thisMonthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString()
  const lastMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1).toISOString()
  const last30DaysStart = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString()
  const [
    todaySalesRes,
    yesterdaySalesRes,
    weekSalesRes,
    lastWeekSalesRes,
    monthSalesRes,
    lastMonthSalesRes,
    top30DaysSalesRes,
    machinesRes,
    recentSalesRes,
    activityRes,
  ] = await Promise.all([
    supabase.from('sales').select('item_price').gte('created_at', todayStart),
    supabase.from('sales').select('item_price').gte('created_at', yesterdayStart).lt('created_at', todayStart),
    supabase.from('sales').select('item_price, created_at').gte('created_at', weekStart),
    supabase.from('sales').select('item_price').gte('created_at', lastWeekStart).lt('created_at', weekStart),
    supabase.from('sales').select('item_price').gte('created_at', thisMonthStart),
    supabase.from('sales').select('item_price').gte('created_at', lastMonthStart).lt('created_at', thisMonthStart),
    fetchLast30DaysSales(last30DaysStart),
    supabase.from('vendingMachine').select('id, name, embedded, embeddeds(id, status, status_at, online_since, mdb_diagnostics)'),
    supabase.from('sales').select('id, created_at, item_price, item_number, channel, machine_id, product_id, products(name, image_path)').order('created_at', { ascending: false }).limit(10),
    (supabase as any).from('activity_log').select('*').order('created_at', { ascending: false }).limit(8),
  ])

  // ── Revenue KPIs ────────────────────────────────────────────────────────────
  const sumPrices = (rows: any[] | null) => (rows ?? []).reduce((s: number, r: any) => s + (r.item_price ?? 0), 0)

  todaySales.value = sumPrices(todaySalesRes.data)
  todaySalesCount.value = (todaySalesRes.data ?? []).length
  yesterdayRevenue.value = sumPrices(yesterdaySalesRes.data)
  yesterdaySalesCount.value = (yesterdaySalesRes.data ?? []).length
  weekSales.value = sumPrices(weekSalesRes.data)
  weekSalesCount.value = (weekSalesRes.data ?? []).length
  lastWeekSales.value = sumPrices(lastWeekSalesRes.data)
  lastWeekSalesCount.value = (lastWeekSalesRes.data ?? []).length
  monthSales.value = sumPrices(monthSalesRes.data)
  monthSalesCount.value = (monthSalesRes.data ?? []).length
  lastMonthSales.value = sumPrices(lastMonthSalesRes.data)
  lastMonthSalesCount.value = (lastMonthSalesRes.data ?? []).length

  // ── 7-day sales chart ──────────────────────────────────────────────────────
  // Local calendar days, zero days included (dailySeries).
  const last30 = top30DaysSalesRes.data ?? []
  dailySalesChart7.value = dailySeries(
    (weekSalesRes.data ?? []) as { item_price: number; created_at: string }[], 7, now)
  dailySalesChart30.value = dailySeries(last30, 30, now)

  // ── Top products (30 days) ─────────────────────────────────────────────────
  {
    const top30DaysSalesData = (top30DaysSalesRes.data ?? []) as { item_price: number; machine_id: string | null; item_number: number; product_id: string | null }[]

    // Fallback: tray lookup only for sales without snapshotted product_id
    const salesWithoutProduct = top30DaysSalesData.filter(s => !s.product_id && s.machine_id)
    const machineIdsForProducts = [...new Set(salesWithoutProduct.map(s => s.machine_id!))]

    let trayProductLookup = new Map<string, { product_id: string; name: string }>()
    if (machineIdsForProducts.length > 0) {
      const { data: trays } = await supabase
        .from('machine_trays')
        .select('machine_id, item_number, product_id, products(name)')
        .in('machine_id', machineIdsForProducts)
      for (const t of (trays ?? []) as { machine_id: string; item_number: number; product_id: string; products: { name: string } | null }[]) {
        if (t.products && t.product_id) {
          trayProductLookup.set(`${t.machine_id}:${t.item_number}`, { product_id: t.product_id, name: t.products.name })
        }
      }
    }

    // Batch fetch product names for sales that have product_id but no inline join
    const productIdsFromSales = [...new Set(top30DaysSalesData.filter(s => s.product_id).map(s => s.product_id!))]
    let productNameMap = new Map<string, string>()
    if (productIdsFromSales.length > 0) {
      const { data: products } = await supabase
        .from('products')
        .select('id, name')
        .in('id', productIdsFromSales)
      for (const p of (products ?? []) as { id: string; name: string }[]) {
        productNameMap.set(p.id, p.name)
      }
    }

    // Aggregate by product — prefer snapshotted product_id, fallback to tray lookup
    const productAgg = new Map<string, { name: string; units: number; revenue: number }>()
    for (const s of top30DaysSalesData) {
      let pid: string | null = s.product_id
      let pname: string | null = pid ? (productNameMap.get(pid) ?? null) : null

      // Fallback to tray lookup for old sales without product_id
      if (!pid && s.machine_id) {
        const trayInfo = trayProductLookup.get(`${s.machine_id}:${s.item_number}`)
        if (trayInfo) { pid = trayInfo.product_id; pname = trayInfo.name }
      }
      if (!pid || !pname) continue

      const existing = productAgg.get(pid) ?? { name: pname, units: 0, revenue: 0 }
      existing.units += 1
      existing.revenue += s.item_price ?? 0
      productAgg.set(pid, existing)
    }

    // Sort by revenue desc, take top 5
    topProducts.value = [...productAgg.entries()]
      .sort((a, b) => b[1].revenue - a[1].revenue)
      .slice(0, 5)
      .map(([id, data]) => ({
        product_id: id,
        name: data.name,
        units_sold: data.units,
        total_revenue: data.revenue,
      }))
  }

  // ── Machines ────────────────────────────────────────────────────────────────
  const machines = (machinesRes.data ?? []) as {
    id: string; name: string; embedded: string | null
    embeddeds: { id: string; status: string | null; status_at: string | null; online_since: string | null; mdb_diagnostics: unknown } | null
  }[]
  totalMachines.value = machines.length
  fleetDevices.value = machines.map(m => (m.embeddeds ? { ...m.embeddeds } : null))

  // ── Per-machine today's revenue + last sale ─────────────────────────────────
  const machineIds = machines.map(m => m.id)
  let todayPerMachine = new Map<string, { revenue: number; count: number }>()
  let lastSalePerMachine = new Map<string, string>()

  // Reset the stock buckets — a fleet that lost its last machine must clear them.
  stockCritical.value = 0
  stockLow.value = 0
  stockFill.value = 0
  stockSwap.value = 0
  machinesNeedingRefill.value = 0

  if (machineIds.length > 0) {
    const [todayMachineRes, traysRes, warehouseStockRes, ...lastSaleResults] = await Promise.all([
      supabase.from('sales').select('machine_id, item_price').in('machine_id', machineIds).gte('created_at', todayStart),
      supabase.from('machine_trays').select('machine_id, product_id, capacity, current_stock, min_stock, fill_when_below').in('machine_id', machineIds),
      supabase.from('warehouse_stock_batches').select('product_id, quantity').gt('quantity', 0),
      ...machines.map(m =>
        supabase.from('sales').select('created_at').eq('machine_id', m.id).order('created_at', { ascending: false }).limit(1).maybeSingle()
      ),
    ])

    // Today's revenue per machine
    for (const row of (todayMachineRes.data ?? []) as { machine_id: string; item_price: number }[]) {
      if (!row.machine_id) continue
      const entry = todayPerMachine.get(row.machine_id) ?? { revenue: 0, count: 0 }
      entry.revenue += row.item_price ?? 0
      entry.count += 1
      todayPerMachine.set(row.machine_id, entry)
    }

    // Last sale per machine
    for (let i = 0; i < machines.length; i++) {
      const saleData = lastSaleResults[i]?.data as { created_at: string } | null
      if (saleData) lastSalePerMachine.set(machines[i]!.id, saleData.created_at)
    }

    // Stock health per machine (warehouse-aware)
    const trayRows = (traysRes.data ?? []) as {
      machine_id: string; product_id: string | null; capacity: number; current_stock: number; min_stock: number; fill_when_below: number
    }[]
    const { warehouseStockMap, hasWarehouses } = buildWarehouseStockInfo(
      (warehouseStockRes.data ?? []) as { product_id: string; quantity: number }[],
    )
    const stockMap = computeStockHealthPerMachine(trayRows, warehouseStockMap, hasWarehouses)

    // Count stock alerts (refillable + swap). One bucket per machine, so the
    // banner can never claim more machines than the fleet has.
    const buckets = countMachineStockBuckets(stockMap.values())
    stockCritical.value = buckets.critical
    stockLow.value = buckets.low
    stockFill.value = buckets.fill
    stockSwap.value = buckets.swap
    machinesNeedingRefill.value = buckets.needingAttention

    // Build dashboard machine list (sorted by stock urgency)
    const healthOrder: Record<string, number> = { critical: 0, low: 1, fill: 2, ok: 3 }
    dashboardMachines.value = machines.map(m => {
      const stock = stockMap.get(m.id)
      const health = stock?.health ?? 'ok'
      const pct = stock?.percent ?? 100
      const dm: DashboardMachine = {
        id: m.id,
        name: m.name,
        embedded: m.embeddeds ? { ...m.embeddeds } : null,
        today_revenue: todayPerMachine.get(m.id)?.revenue ?? 0,
        stock_health: health,
        stock_percent: pct,
        last_sale_at: lastSalePerMachine.get(m.id) ?? null,
      }
      return dm
    }).sort((a, b) => {
      // Connectivity problems first, then stock urgency.
      const ca = conn.of(a.embedded).needsAttention ? 0 : 1
      const cb = conn.of(b.embedded).needsAttention ? 0 : 1
      if (ca !== cb) return ca - cb
      const ha = healthOrder[a.stock_health] ?? 3
      const hb = healthOrder[b.stock_health] ?? 3
      if (ha !== hb) return ha - hb
      return b.today_revenue - a.today_revenue
    }).slice(0, 6)
  }

  // ── Warehouse alerts ────────────────────────────────────────────────────────
  const [minStockRes, batchesRes] = await Promise.all([
    supabase.from('product_min_stock').select('product_id, min_quantity'),
    supabase.from('warehouse_stock_batches').select('product_id, quantity, expiration_date').gt('quantity', 0),
  ])

  if (minStockRes.data && batchesRes.data) {
    // Sum warehouse stock per product
    const warehouseStock = new Map<string, number>()
    let expiringSoon = 0
    for (const batch of batchesRes.data as { product_id: string; quantity: number; expiration_date: string | null }[]) {
      warehouseStock.set(batch.product_id, (warehouseStock.get(batch.product_id) ?? 0) + batch.quantity)
      if (batch.expiration_date) {
        const status = expirationStatus(batch.expiration_date)
        if (status === 'critical' || status === 'warning') expiringSoon++
      }
    }

    // Count products below min
    let belowMin = 0
    for (const rule of minStockRes.data as { product_id: string; min_quantity: number }[]) {
      const current = warehouseStock.get(rule.product_id) ?? 0
      if (current < rule.min_quantity) belowMin++
    }
    warehouseBelowMin.value = belowMin
    warehouseExpiringSoon.value = expiringSoon
  }

  // ── Recent sales ───────────────────────────────────────────────────────────
  const rawSales = (recentSalesRes.data ?? []) as {
    id: string; created_at: string; item_price: number; item_number: number
    channel: string; machine_id: string | null; product_id: string | null
    products: { name: string; image_path: string | null } | null
  }[]

  // Build machine name map from already-fetched machines
  const machineNameMap = new Map<string, string>()
  for (const m of machines) machineNameMap.set(m.id, m.name)

  // Fallback: resolve product via machine_trays only for old sales without product_id
  const salesWithoutProduct = rawSales.filter(s => !s.product_id && s.machine_id)
  const saleMachineIds = [...new Set(salesWithoutProduct.map(s => s.machine_id!))]
  let trayProductMap = new Map<string, { product_id: string | null; name: string; image_path: string | null }>()
  if (saleMachineIds.length > 0) {
    const { data: trayData } = await supabase
      .from('machine_trays')
      .select('machine_id, item_number, product_id, products(name, image_path)')
      .in('machine_id', saleMachineIds)
    for (const t of (trayData ?? []) as { machine_id: string; item_number: number; product_id: string | null; products: { name: string; image_path: string | null } | null }[]) {
      if (t.products) trayProductMap.set(`${t.machine_id}:${t.item_number}`, { product_id: t.product_id, name: t.products.name, image_path: t.products.image_path })
    }
  }

  recentSales.value = rawSales.map(s => {
    // Prefer product from snapshotted FK join, fallback to tray lookup for old sales
    const trayFallback = !s.product_id && s.machine_id ? trayProductMap.get(`${s.machine_id}:${s.item_number}`) : null
    const productName = s.products?.name ?? trayFallback?.name ?? null
    const productImagePath = s.products?.image_path ?? trayFallback?.image_path ?? null
    const productId = s.product_id ?? trayFallback?.product_id ?? null
    return {
      id: s.id,
      created_at: s.created_at,
      item_price: s.item_price,
      item_number: s.item_number,
      channel: s.channel,
      machine_name: s.machine_id ? (machineNameMap.get(s.machine_id) ?? null) : null,
      product_id: productId,
      product_name: productName,
      product_image_url: productImagePath ? getProductImageUrl(productImagePath) : null,
    }
  })

  // ── Activity feed ───────────────────────────────────────────────────────────
  recentActivity.value = ((activityRes.data ?? []) as ActivityEntry[]).map(e => ({
    ...e,
    user_display: (e.metadata as any)?._user_display
      || (e.metadata as any)?._user_email
      || (e.user_id ? e.user_id.slice(0, 8) : 'System'),
  }))

  // ── New deals (inbox count for the banner) ──────────────────────────────────
  // RPC returns 0 when deals are off / nothing new; tolerate its absence on
  // backends where the migration hasn't been applied yet.
  try {
    const { data: newDeals, error: newDealsErr } = await (supabase as any).rpc('get_new_deals_count')
    if (!newDealsErr && typeof newDeals === 'number') newDealsCount.value = newDeals
  } catch { /* RPC not deployed yet */ }
}
</script>

<template>
  <div class="flex flex-1 flex-col">
    <div class="@container/main flex flex-1 flex-col gap-2">
      <div class="flex flex-col gap-4 py-4 md:gap-6 md:py-6">
        <!-- Refill banner -->
        <NuxtLink
          v-if="machinesNeedingRefill > 0"
          to="/machines"
          class="mx-4 flex items-center justify-between gap-3 rounded-lg border border-red-500/20 bg-red-500/10 px-4 py-3 transition-colors hover:bg-red-500/15 lg:mx-6"
        >
          <div class="flex items-center gap-2 text-sm font-medium text-red-500">
            <IconAlertTriangle class="size-4 shrink-0" />
            {{ t('dashboard.refillBanner', machinesNeedingRefill) }}
          </div>
          <span class="shrink-0 text-xs font-medium text-red-500/70">{{ t('dashboard.viewMachines') }} →</span>
        </NuxtLink>

        <!-- Connectivity banner -->
        <NuxtLink
          v-if="fleet.attention > 0"
          to="/machines"
          class="mx-4 flex items-center justify-between gap-3 rounded-lg border border-red-500/20 bg-red-500/10 px-4 py-3 transition-colors hover:bg-red-500/15 lg:mx-6"
        >
          <div class="min-w-0">
            <div class="flex items-center gap-2 text-sm font-medium text-red-500">
              <IconAlertTriangle class="size-4 shrink-0" />
              {{ t('connectivity.fleet.attentionTitle', { count: fleet.attention }, fleet.attention) }}
            </div>
            <p class="mt-0.5 pl-6 text-xs text-muted-foreground">{{ fleetDetails }}</p>
          </div>
          <span class="shrink-0 text-xs font-medium text-red-500/70">{{ t('dashboard.viewMachines') }} →</span>
        </NuxtLink>

        <!-- New deals banner -->
        <NuxtLink
          v-if="newDealsCount > 0"
          to="/deals"
          class="mx-4 flex items-center justify-between gap-3 rounded-lg border border-emerald-500/20 bg-emerald-500/10 px-4 py-3 transition-colors hover:bg-emerald-500/15 lg:mx-6"
        >
          <div class="flex items-center gap-2 text-sm font-medium text-emerald-600 dark:text-emerald-400">
            <IconTag class="size-4 shrink-0" />
            {{ t('dashboard.newDealsBanner', newDealsCount) }}
          </div>
          <span class="shrink-0 text-xs font-medium text-emerald-600/70 dark:text-emerald-400/70">{{ t('dashboard.viewDeals') }} →</span>
        </NuxtLink>

        <!-- KPI Cards -->
        <SectionCards
          :today-sales="todaySales"
          :today-sales-count="todaySalesCount"
          :yesterday-revenue="yesterdayRevenue"
          :yesterday-sales-count="yesterdaySalesCount"
          :week-sales="weekSales"
          :week-sales-count="weekSalesCount"
          :last-week-sales="lastWeekSales"
          :last-week-sales-count="lastWeekSalesCount"
          :month-sales="monthSales"
          :month-sales-count="monthSalesCount"
          :last-month-sales="lastMonthSales"
          :last-month-sales-count="lastMonthSalesCount"
          :stock-critical="stockCritical"
          :stock-low="stockLow"
          :warehouse-below-min="warehouseBelowMin"
          :warehouse-expiring-soon="warehouseExpiringSoon"
        />

        <!-- Sales Chart + Top Products -->
        <div class="grid grid-cols-1 gap-4 px-4 lg:grid-cols-2 lg:px-6">
          <ChartAreaInteractive
            :data="dailySalesChart"
            :title="chartDays === 30 ? t('dashboard.salesLast30Days') : t('dashboard.salesLast7Days')"
            :description="t('dashboard.dailyRevenueOverview')"
          >
            <template #actions>
              <div role="radiogroup" :aria-label="t('dashboard.chartPeriod')" class="inline-flex rounded-lg bg-muted p-0.5 text-xs font-medium">
                <button
                  v-for="d in ([7, 30] as const)"
                  :key="d"
                  type="button"
                  role="radio"
                  :aria-checked="chartDays === d"
                  class="rounded-md px-2.5 py-1 transition-colors"
                  :class="chartDays === d ? 'bg-background text-foreground shadow-sm' : 'text-muted-foreground hover:text-foreground'"
                  @click="chartDays = d"
                >{{ d === 7 ? t('dashboard.chartDays7') : t('dashboard.chartDays30') }}</button>
              </div>
            </template>
          </ChartAreaInteractive>
          <DashboardTopProducts :products="topProducts" />
        </div>

        <!-- Company Insights -->
        <div class="px-4 lg:px-6">
          <div class="rounded-xl border bg-card">
            <!-- Header (always visible, clickable to expand/collapse) -->
            <button
              class="flex w-full items-center justify-between px-4 py-3 text-left"
              @click="companyInsightsExpanded = !companyInsightsExpanded"
            >
              <div class="flex items-center gap-2">
                <IconSparkles class="size-4 text-primary" />
                <h3 class="text-sm font-medium">{{ t('dashboard.companyInsights') }}</h3>
                <span v-if="companyInsights?.cached" class="inline-flex items-center rounded-full bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
                  {{ t('machineDetail.aiCached') }}
                </span>
              </div>
              <div class="flex items-center gap-2">
                <button
                  v-if="companyInsights && !companyLoading"
                  class="inline-flex h-7 items-center gap-1.5 rounded-md border px-2 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                  @click.stop="refreshCompanyInsights"
                >
                  <IconRefresh class="size-3" />
                  {{ t('machineDetail.aiRefresh') }}
                </button>
                <svg
                  xmlns="http://www.w3.org/2000/svg" class="size-4 text-muted-foreground transition-transform"
                  :class="{ 'rotate-180': companyInsightsExpanded }"
                  viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
                ><polyline points="6 9 12 15 18 9"/></svg>
              </div>
            </button>

            <template v-if="companyInsightsExpanded">
              <!-- Loading -->
              <div v-if="companyLoading" class="flex items-center gap-2 border-t px-4 py-4 text-sm text-muted-foreground">
                <IconLoader2 class="size-4 animate-spin" />
                {{ t('dashboard.companyInsightsLoading') }}
              </div>

              <!-- Error -->
              <div v-else-if="companyError" class="border-t px-4 py-3">
                <p class="text-sm text-destructive">{{ companyError }}</p>
              </div>

              <!-- No insights yet — show generate button -->
              <div v-else-if="!companyInsights && !companyLoading" class="border-t px-4 py-4 text-center">
                <p class="mb-3 text-sm text-muted-foreground">{{ t('dashboard.companyInsightsEmpty') }}</p>
                <button
                  class="inline-flex h-8 items-center gap-1.5 rounded-md bg-primary px-4 text-xs font-medium text-primary-foreground shadow-sm transition-colors hover:bg-primary/90"
                  @click="generateCompanyInsights"
                >
                  <IconSparkles class="size-3" />
                  {{ t('dashboard.companyInsightsGenerate') }}
                </button>
              </div>

              <!-- Results -->
              <div v-else-if="companyInsights" class="border-t">
                <!-- Trends -->
                <div v-if="companyInsights.trends && (companyInsights.trends.revenue_change_pct !== null || companyInsights.trends.units_change_pct !== null)" class="flex flex-wrap gap-2 px-4 py-3">
                  <span
                    v-if="companyInsights.trends.revenue_change_pct !== null"
                    class="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium"
                    :class="companyInsights.trends.revenue_change_pct >= 0 ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300' : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'"
                  >
                    {{ companyInsights.trends.revenue_change_pct >= 0 ? '+' : '' }}{{ companyInsights.trends.revenue_change_pct }}%
                    {{ t('machineDetail.aiTrendRevenue', { days: companyInsights.period_days }) }}
                  </span>
                  <span
                    v-if="companyInsights.trends.units_change_pct !== null"
                    class="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium"
                    :class="companyInsights.trends.units_change_pct >= 0 ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300' : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'"
                  >
                    {{ companyInsights.trends.units_change_pct >= 0 ? '+' : '' }}{{ companyInsights.trends.units_change_pct }}%
                    {{ t('machineDetail.aiTrendUnits', { days: companyInsights.period_days }) }}
                  </span>
                </div>

                <!-- Recommendations -->
                <div v-if="sortedRecommendations(companyInsights.recommendations).length > 0" class="space-y-2 px-4 pb-3">
                  <div
                    v-for="(rec, idx) in sortedRecommendations(companyInsights.recommendations)"
                    :key="idx"
                    class="rounded-lg border p-3 space-y-1.5"
                  >
                    <div class="flex items-center gap-2 flex-wrap">
                      <Badge :variant="priorityVariant(rec.priority)" class="text-[10px]">{{ rec.priority }}</Badge>
                      <span class="text-[10px] text-muted-foreground">{{ t(recommendationTypeLabel(rec.type)) }}</span>
                    </div>
                    <p class="text-sm font-medium">{{ rec.title }}</p>
                    <p class="text-xs text-muted-foreground">{{ rec.detail }}</p>
                  </div>
                </div>

                <!-- Summary -->
                <div class="border-t px-4 py-3">
                  <p class="text-sm text-muted-foreground leading-relaxed">{{ companyInsights.summary }}</p>
                </div>

                <!-- Footer -->
                <div class="flex items-center gap-2 border-t px-4 py-2">
                  <p class="flex-1 text-xs text-muted-foreground">
                    {{ t('machineDetail.aiGenerated', { time: timeAgo(companyInsights.generated_at, t) }) }}
                  </p>
                </div>
              </div>

              <!-- History -->
              <div v-if="!companyLoading && !companyError" class="border-t px-4 py-3">
                <h4 class="mb-2 text-xs font-medium text-muted-foreground">{{ t('machineDetail.aiHistory') }}</h4>
                <div v-if="companyHistoryLoading" class="space-y-2">
                  <div v-for="i in 2" :key="i" class="h-10 animate-pulse rounded bg-muted" />
                </div>
                <div v-else-if="companyHistory.length === 0" class="text-xs text-muted-foreground">
                  {{ t('machineDetail.aiHistoryEmpty') }}
                </div>
                <div v-else class="space-y-1.5">
                  <div
                    v-for="entry in companyHistory"
                    :key="entry.id"
                    class="rounded-lg border"
                  >
                    <button
                      class="flex w-full items-center justify-between px-3 py-2 text-left text-xs transition-colors hover:bg-muted/50"
                      @click="toggleCompanyHistoryEntry(entry.id)"
                    >
                      <span class="text-muted-foreground">{{ new Date(entry.generated_at).toLocaleDateString() }}</span>
                      <div class="flex items-center gap-2">
                        <span class="text-[10px] text-muted-foreground">{{ (entry.recommendations ?? []).length }} {{ t('machineDetail.aiHistoryRecs') }}</span>
                        <svg
                          xmlns="http://www.w3.org/2000/svg" class="size-3 text-muted-foreground transition-transform"
                          :class="{ 'rotate-180': companyHistoryExpanded === entry.id }"
                          viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
                        ><polyline points="6 9 12 15 18 9"/></svg>
                      </div>
                    </button>
                    <div v-if="companyHistoryExpanded === entry.id" class="border-t px-3 py-2 space-y-1.5">
                      <p class="text-xs text-muted-foreground leading-relaxed">{{ entry.summary }}</p>
                      <div
                        v-for="(rec, idx) in sortedRecommendations(entry.recommendations ?? [])"
                        :key="idx"
                        class="flex items-start gap-1.5 text-[11px]"
                      >
                        <Badge :variant="priorityVariant(rec.priority)" class="mt-0.5 shrink-0 text-[9px]">{{ rec.priority }}</Badge>
                        <span class="text-muted-foreground">{{ rec.title }}</span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </template>
          </div>
        </div>

        <!-- Machines -->
        <div class="px-4 lg:px-6">
          <DashboardMachineList :machines="dashboardMachines" />
        </div>

        <!-- Recent Sales -->
        <div class="px-4 lg:px-6">
          <DashboardRecentSales :sales="recentSales" />
        </div>

        <!-- Activity Feed -->
        <div class="px-4 lg:px-6">
          <DashboardActivityFeed :entries="recentActivity" />
        </div>
      </div>
    </div>
  </div>
</template>
