<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import SectionCards from "@/components/SectionCards.vue"
import ChartAreaInteractive from "@/components/ChartAreaInteractive.vue"
import CompanyInsights from "@/components/CompanyInsights.vue"
import DashboardTopProducts from "@/components/DashboardTopProducts.vue"
import DashboardMachineList from "@/components/DashboardMachineList.vue"
import DashboardRecentSales from "@/components/DashboardRecentSales.vue"
import DashboardActivityFeed from "@/components/DashboardActivityFeed.vue"
import type { DashboardMachine } from "@/components/DashboardMachineList.vue"
import type { RecentSale } from "@/components/DashboardRecentSales.vue"
import type { ActivityEntry } from "@/components/DashboardActivityFeed.vue"
import type { TopProduct } from "@/components/DashboardTopProducts.vue"
import { IconAlertTriangle } from '@tabler/icons-vue'
import { expirationStatus } from '@/composables/useWarehouse'
import { getProductImageUrl } from '@/composables/useProducts'
import { buildWarehouseStockInfo, computeStockHealthPerMachine } from '@/lib/stock-health'

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
const machinesOnline = ref(0)
const totalMachines = ref(0)
const stockCritical = ref(0)
const stockLow = ref(0)
const stockSwap = ref(0)
const warehouseBelowMin = ref(0)
const warehouseExpiringSoon = ref(0)

const machinesNeedingRefill = computed(() => stockCritical.value + stockLow.value + stockSwap.value)

// ── Chart + sections ──────────────────────────────────────────────────────────
const dailySalesChart = ref<{ date: Date; total: number }[]>([])
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
        const oldStatus = payload.old?.status
        const newStatus = payload.new?.status
        if (oldStatus === newStatus) return
        const isConnected = (s: string | undefined) => s != null && s !== 'offline'
        const wasConnected = isConnected(oldStatus)
        const nowConnected = isConnected(newStatus)
        if (!wasConnected && nowConnected) machinesOnline.value++
        if (wasConnected && !nowConnected) machinesOnline.value = Math.max(0, machinesOnline.value - 1)

        // Update machine list status
        const embeddedId = payload.new?.id
        if (embeddedId) {
          const m = dashboardMachines.value.find(dm => (dm as any)._embeddedId === embeddedId)
          if (m) m.status = newStatus
        }
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
    supabase.from('sales').select('item_price, machine_id, item_number, product_id').gte('created_at', last30DaysStart),
    supabase.from('vendingMachine').select('id, name, embedded, embeddeds(id, status)'),
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
  {
    const dailyMap = new Map<string, number>()
    for (const s of (weekSalesRes.data ?? []) as { item_price: number; created_at: string }[]) {
      const day = new Date(s.created_at).toISOString().slice(0, 10)
      dailyMap.set(day, (dailyMap.get(day) ?? 0) + (s.item_price ?? 0))
    }
    // Fill all 7 days (including zero days)
    const chartData: { date: Date; total: number }[] = []
    for (let i = 6; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i)
      const key = d.toISOString().slice(0, 10)
      chartData.push({ date: d, total: dailyMap.get(key) ?? 0 })
    }
    dailySalesChart.value = chartData
  }

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
    embeddeds: { id: string; status: string } | null
  }[]
  totalMachines.value = machines.length
  machinesOnline.value = machines.filter(m => m.embeddeds?.status && m.embeddeds.status !== 'offline').length

  // ── Per-machine today's revenue + last sale ─────────────────────────────────
  const machineIds = machines.map(m => m.id)
  let todayPerMachine = new Map<string, { revenue: number; count: number }>()
  let lastSalePerMachine = new Map<string, string>()

  if (machineIds.length > 0) {
    const [todayMachineRes, traysRes, warehouseStockRes, ...lastSaleResults] = await Promise.all([
      supabase.from('sales').select('machine_id, item_price').in('machine_id', machineIds).gte('created_at', todayStart),
      supabase.from('machine_trays').select('machine_id, product_id, capacity, current_stock, min_stock').in('machine_id', machineIds),
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
      machine_id: string; product_id: string | null; capacity: number; current_stock: number; min_stock: number
    }[]
    const { warehouseStockMap, hasWarehouses } = buildWarehouseStockInfo(
      (warehouseStockRes.data ?? []) as { product_id: string; quantity: number }[],
    )
    const stockMap = computeStockHealthPerMachine(trayRows, warehouseStockMap, hasWarehouses)

    // Count stock alerts (refillable + swap)
    let critCount = 0
    let lowCount = 0
    let swapCount = 0
    for (const [, stock] of stockMap) {
      if (stock.health === 'critical') critCount++
      else if (stock.health === 'low') lowCount++
      if (stock.health === 'ok' && stock.noStockEmptyCount > 0) swapCount++
    }
    stockCritical.value = critCount
    stockLow.value = lowCount
    stockSwap.value = swapCount

    // Build dashboard machine list (sorted by stock urgency)
    const healthOrder: Record<string, number> = { critical: 0, low: 1, ok: 2 }
    dashboardMachines.value = machines.map(m => {
      const stock = stockMap.get(m.id)
      const health = stock?.health ?? 'ok'
      const pct = stock?.percent ?? 100
      const dm: DashboardMachine & { _embeddedId?: string } = {
        id: m.id,
        name: m.name,
        status: m.embeddeds?.status ?? null,
        today_revenue: todayPerMachine.get(m.id)?.revenue ?? 0,
        stock_health: health,
        stock_percent: pct,
        last_sale_at: lastSalePerMachine.get(m.id) ?? null,
        _embeddedId: m.embeddeds?.id,
      }
      return dm
    }).sort((a, b) => {
      const ha = healthOrder[a.stock_health] ?? 2
      const hb = healthOrder[b.stock_health] ?? 2
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
            :title="t('dashboard.salesLast7Days')"
            :description="t('dashboard.dailyRevenueOverview')"
          />
          <DashboardTopProducts :products="topProducts" />
        </div>

        <!-- Company Insights -->
        <div class="px-4 lg:px-6">
          <CompanyInsights />
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
