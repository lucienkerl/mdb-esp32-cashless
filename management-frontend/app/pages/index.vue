<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import ChartAreaInteractive from "@/components/ChartAreaInteractive.vue"
import SectionCards from "@/components/SectionCards.vue"
import DashboardMachineList from "@/components/DashboardMachineList.vue"
import DashboardActivityFeed from "@/components/DashboardActivityFeed.vue"
import type { DashboardMachine } from "@/components/DashboardMachineList.vue"
import type { ActivityEntry } from "@/components/DashboardActivityFeed.vue"
import { expirationStatus } from '@/composables/useWarehouse'

const supabase = useSupabaseClient()
const { fetchOrganization } = useOrganization()
const { onResume } = useAppResume()

// ── KPI state ─────────────────────────────────────────────────────────────────
const todaySales = ref(0)
const todaySalesCount = ref(0)
const yesterdayRevenue = ref(0)
const weekSales = ref(0)
const lastWeekSales = ref(0)
const monthSales = ref(0)
const lastMonthSales = ref(0)
const machinesOnline = ref(0)
const totalMachines = ref(0)
const stockCritical = ref(0)
const stockLow = ref(0)
const warehouseBelowMin = ref(0)
const warehouseExpiringSoon = ref(0)

// ── Chart + sections ──────────────────────────────────────────────────────────
const salesChartData = ref<{ date: Date; total: number }[]>([])
const dashboardMachines = ref<DashboardMachine[]>([])
const recentActivity = ref<ActivityEntry[]>([])

// ── Sparkline data for KPI card backgrounds ─────────────────────────────────
const todaySparkline = ref<number[]>([])
const weekSparkline = ref<number[]>([])
const monthSparkline = ref<number[]>([])

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
        if (saleDate >= weekStart) weekSales.value += price
        if (saleDate >= monthStart) monthSales.value += price

        // Update chart data
        const day = saleDate.toISOString().slice(0, 10)
        const existing = salesChartData.value.find(
          (d) => d.date.toISOString().slice(0, 10) === day
        )
        if (existing) {
          existing.total += price
          salesChartData.value = [...salesChartData.value]
        } else {
          salesChartData.value = [
            ...salesChartData.value,
            { date: new Date(day), total: price },
          ].sort((a, b) => a.date.getTime() - b.date.getTime())
        }

        // Update machine revenue in list
        if (sale.machine_id) {
          const m = dashboardMachines.value.find(dm => dm.id === sale.machine_id)
          if (m && saleDate >= todayStart) {
            m.today_revenue += price
            m.last_sale_at = sale.created_at
          }
        }
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
  const thirtyDaysAgo = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString()

  const [
    todaySalesRes,
    yesterdaySalesRes,
    weekSalesRes,
    lastWeekSalesRes,
    monthSalesRes,
    lastMonthSalesRes,
    machinesRes,
    salesHistoryRes,
    activityRes,
  ] = await Promise.all([
    supabase.from('sales').select('item_price').gte('created_at', todayStart),
    supabase.from('sales').select('item_price').gte('created_at', yesterdayStart).lt('created_at', todayStart),
    supabase.from('sales').select('item_price').gte('created_at', weekStart),
    supabase.from('sales').select('item_price').gte('created_at', lastWeekStart).lt('created_at', weekStart),
    supabase.from('sales').select('item_price').gte('created_at', thisMonthStart),
    supabase.from('sales').select('item_price').gte('created_at', lastMonthStart).lt('created_at', thisMonthStart),
    supabase.from('vendingMachine').select('id, name, embedded, embeddeds(id, status)'),
    supabase.from('sales').select('created_at, item_price').gte('created_at', thirtyDaysAgo),
    (supabase as any).from('activity_log').select('*').order('created_at', { ascending: false }).limit(8),
  ])

  // ── Revenue KPIs ────────────────────────────────────────────────────────────
  const sumPrices = (rows: any[] | null) => (rows ?? []).reduce((s: number, r: any) => s + (r.item_price ?? 0), 0)

  todaySales.value = sumPrices(todaySalesRes.data)
  todaySalesCount.value = (todaySalesRes.data ?? []).length
  yesterdayRevenue.value = sumPrices(yesterdaySalesRes.data)
  weekSales.value = sumPrices(weekSalesRes.data)
  lastWeekSales.value = sumPrices(lastWeekSalesRes.data)
  monthSales.value = sumPrices(monthSalesRes.data)
  lastMonthSales.value = sumPrices(lastMonthSalesRes.data)

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
    const [todayMachineRes, traysRes, ...lastSaleResults] = await Promise.all([
      supabase.from('sales').select('machine_id, item_price').in('machine_id', machineIds).gte('created_at', todayStart),
      supabase.from('machine_trays').select('machine_id, capacity, current_stock, min_stock').in('machine_id', machineIds),
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

    // Stock health per machine
    const trayRows = (traysRes.data ?? []) as {
      machine_id: string; capacity: number; current_stock: number; min_stock: number
    }[]
    const stockMap = new Map<string, { total: number; low: number; empty: number; totalStock: number; totalCapacity: number }>()
    for (const tray of trayRows) {
      if (!tray.machine_id) continue
      let entry = stockMap.get(tray.machine_id)
      if (!entry) {
        entry = { total: 0, low: 0, empty: 0, totalStock: 0, totalCapacity: 0 }
        stockMap.set(tray.machine_id, entry)
      }
      entry.total++
      entry.totalStock += tray.current_stock
      entry.totalCapacity += tray.capacity
      if (tray.current_stock === 0) entry.empty++
      else if (tray.min_stock > 0 && tray.current_stock <= tray.min_stock) entry.low++
    }

    // Count stock alerts
    let critCount = 0
    let lowCount = 0
    for (const [, stock] of stockMap) {
      if (stock.empty > 0) critCount++
      else if (stock.low > 0) lowCount++
    }
    stockCritical.value = critCount
    stockLow.value = lowCount

    // Build dashboard machine list (sorted by stock urgency)
    const healthOrder: Record<string, number> = { critical: 0, low: 1, ok: 2 }
    dashboardMachines.value = machines.map(m => {
      const stock = stockMap.get(m.id)
      const health: 'ok' | 'low' | 'critical' = stock
        ? (stock.empty > 0 ? 'critical' : (stock.low > 0 ? 'low' : 'ok'))
        : 'ok'
      const pct = stock && stock.totalCapacity > 0
        ? Math.round((stock.totalStock / stock.totalCapacity) * 100)
        : 100
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

  // ── Sales chart + sparklines ────────────────────────────────────────────────
  const allSales = (salesHistoryRes.data ?? []) as { created_at: string; item_price: number }[]
  const byDay: Record<string, number> = {}
  for (const sale of allSales) {
    const day = new Date(sale.created_at).toISOString().slice(0, 10)
    byDay[day] = (byDay[day] ?? 0) + (sale.item_price ?? 0)
  }
  salesChartData.value = Object.entries(byDay)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, total]) => ({ date: new Date(date), total }))

  // Today sparkline: hourly buckets (24 hours)
  const todayBuckets = new Array(24).fill(0)
  const todayDate = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  for (const sale of allSales) {
    const d = new Date(sale.created_at)
    if (d >= todayDate) {
      todayBuckets[d.getHours()] += sale.item_price ?? 0
    }
  }
  todaySparkline.value = todayBuckets

  // Week sparkline: daily buckets (7 days)
  const weekBuckets = new Array(7).fill(0)
  const weekDate = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000)
  for (const sale of allSales) {
    const d = new Date(sale.created_at)
    if (d >= weekDate) {
      const dayIdx = Math.floor((d.getTime() - weekDate.getTime()) / (24 * 60 * 60 * 1000))
      if (dayIdx >= 0 && dayIdx < 7) weekBuckets[dayIdx] += sale.item_price ?? 0
    }
  }
  weekSparkline.value = weekBuckets

  // Month sparkline: daily buckets (30 days) — reuse byDay
  const monthBuckets: number[] = []
  for (let i = 29; i >= 0; i--) {
    const d = new Date(now.getTime() - i * 24 * 60 * 60 * 1000)
    const key = d.toISOString().slice(0, 10)
    monthBuckets.push(byDay[key] ?? 0)
  }
  monthSparkline.value = monthBuckets

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
        <!-- KPI Cards -->
        <SectionCards
          :today-sales="todaySales"
          :today-sales-count="todaySalesCount"
          :yesterday-revenue="yesterdayRevenue"
          :week-sales="weekSales"
          :last-week-sales="lastWeekSales"
          :month-sales="monthSales"
          :last-month-sales="lastMonthSales"
          :stock-critical="stockCritical"
          :stock-low="stockLow"
          :warehouse-below-min="warehouseBelowMin"
          :warehouse-expiring-soon="warehouseExpiringSoon"
          :today-sparkline="todaySparkline"
          :week-sparkline="weekSparkline"
          :month-sparkline="monthSparkline"
        />

        <!-- Chart + Machines side by side -->
        <div class="grid grid-cols-1 gap-4 px-4 lg:grid-cols-2 lg:px-6">
          <ChartAreaInteractive :data="salesChartData" />
          <DashboardMachineList :machines="dashboardMachines" />
        </div>

        <!-- Activity Feed -->
        <div class="px-4 lg:px-6">
          <DashboardActivityFeed :entries="recentActivity" />
        </div>
      </div>
    </div>
  </div>
</template>
