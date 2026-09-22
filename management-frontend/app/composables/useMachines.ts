import { ref, useState, useSupabaseClient } from '#imports'
import { buildWarehouseStockInfo, classifyTrayStock, isProductRefillable } from '@/lib/stock-health'

interface Embedded {
  id: string
  status: string
  status_at: string
  subdomain: number
  mac_address?: string
  firmware_version?: string
  firmware_build_date?: string
  mdb_diagnostics?: Record<string, unknown> | null
  last_restart_reason?: string | null
  last_restart_at?: string | null
  online_since?: string | null
  name?: string | null
}

interface VendingMachine {
  id: string
  name: string
  location_lat: number | null
  location_lon: number | null
  embedded: string | null
  country_code: string | null
  public_listing?: boolean | null
  // NEW: structured address (added 2026-04-10)
  address_street: string | null
  address_house_number: string | null
  address_postal_code: string | null
  address_city: string | null
  formatted_address: string | null
  nayax_machine_id: string | null
  item_number_offset: number
  embeddeds: Embedded | null
  last_sale_at?: string | null
  last_sale_amount?: number | null
  last_sale_item_number?: number | null
  today_revenue?: number
  today_sales_count?: number
  yesterday_revenue?: number
  yesterday_sales_count?: number
  this_month_revenue?: number
  this_month_sales_count?: number
  last_month_revenue?: number
  last_month_sales_count?: number
  paxcounter_count?: number | null
  // Stock fields
  total_trays?: number
  low_trays?: number
  empty_trays?: number
  fill_trays?: number
  stock_health?: 'ok' | 'low' | 'fill' | 'critical'
  stock_percent?: number
  tray_summary?: { product_name: string; product_id: string | null; deficit: number; image_path: string | null; sellprice: number | null; in_stock: boolean; severity: 'critical' | 'low' | 'fill'; discontinued?: boolean }[]
  critical_product_ids?: Set<string>
  no_stock_trays?: number
  no_stock_summary?: { product_name: string; product_id: string | null; deficit: number; image_path: string | null; sellprice: number | null; in_stock: boolean; severity: 'critical' | 'low' | 'fill'; discontinued?: boolean }[]
}

interface PendingToken {
  id: string
  short_code: string
  name: string | null
  created_at: string
  expires_at: string
  device_only: boolean
}

export interface MachineSettingsPatch {
  location_lat: number | null
  location_lon: number | null
  address_street: string | null
  address_house_number: string | null
  address_postal_code: string | null
  address_city: string | null
  formatted_address: string | null
  country_code: string | null
  nayax_machine_id: string | null
  item_number_offset: number
}

/**
 * Location payload for createMachine(). Narrows location_lat/location_lon to
 * non-null since a machine is only created "with location" when a pin was placed.
 * nayax_machine_id is set later via Machine Settings, not at creation time.
 */
export type CreateMachineLocation = Omit<MachineSettingsPatch, 'location_lat' | 'location_lon' | 'nayax_machine_id' | 'item_number_offset'> & {
  location_lat: number
  location_lon: number
}

export function useMachines() {
  const machines = useState<VendingMachine[]>('machines', () => [])
  const loading = ref(false)

  async function fetchMachines() {
    loading.value = true
    try {
      const supabase = useSupabaseClient()
      const { data, error } = await supabase
        .from('vendingMachine')
        .select(`
          id, name, location_lat, location_lon, embedded, country_code, public_listing,
          address_street, address_house_number, address_postal_code, address_city, formatted_address,
          nayax_machine_id, item_number_offset,
          embeddeds(id, status, status_at, subdomain, mac_address, firmware_version, firmware_build_date, mdb_diagnostics, last_restart_reason, last_restart_at, online_since)
        `)

      if (error) throw error
      machines.value = (data ?? []) as VendingMachine[]

      const machineIds = machines.value.map(m => m.id)

      if (machineIds.length === 0) {
        loading.value = false
        return
      }

      // Date boundaries
      const now = new Date()
      const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString()
      const yesterdayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1).toISOString()
      const thisMonthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString()
      const lastMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1).toISOString()

      // Batch queries in parallel — use machine_id instead of embedded_id
      const [todaySalesRes, yesterdaySalesRes, thisMonthSalesRes, lastMonthSalesRes, paxRes, traysRes, warehouseStockRes, ...lastSaleResults] = await Promise.all([
        // Today's sales
        supabase
          .from('sales')
          .select('machine_id, item_price')
          .in('machine_id', machineIds)
          .gte('created_at', todayStart),
        // Yesterday's sales
        supabase
          .from('sales')
          .select('machine_id, item_price')
          .in('machine_id', machineIds)
          .gte('created_at', yesterdayStart)
          .lt('created_at', todayStart),
        // This month's sales
        supabase
          .from('sales')
          .select('machine_id, item_price')
          .in('machine_id', machineIds)
          .gte('created_at', thisMonthStart),
        // Last month's sales
        supabase
          .from('sales')
          .select('machine_id, item_price')
          .in('machine_id', machineIds)
          .gte('created_at', lastMonthStart)
          .lt('created_at', thisMonthStart),
        // Latest paxcounter per machine
        supabase
          .from('paxcounter')
          .select('machine_id, count')
          .in('machine_id', machineIds)
          .order('created_at', { ascending: false }),
        // All tray data in one batch (with product names)
        supabase
          .from('machine_trays')
          .select('machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, sellprice, discontinued)')
          .in('machine_id', machineIds),
        // Warehouse stock for availability check
        supabase
          .from('warehouse_stock_batches')
          .select('product_id, quantity')
          .gt('quantity', 0),
        // Last sale per machine
        ...machines.value.map(m =>
          supabase
            .from('sales')
            .select('created_at, item_price, item_number')
            .eq('machine_id', m.id)
            .order('created_at', { ascending: false })
            .limit(1)
            .maybeSingle()
        ),
      ])

      // Aggregate today's sales per machine
      const todayMap = new Map<string, { revenue: number; count: number }>()
      const todayRows = (todaySalesRes.data ?? []) as { machine_id: string; item_price: number }[]
      for (const row of todayRows) {
        if (!row.machine_id) continue
        const entry = todayMap.get(row.machine_id) ?? { revenue: 0, count: 0 }
        entry.revenue += row.item_price ?? 0
        entry.count += 1
        todayMap.set(row.machine_id, entry)
      }

      // Aggregate yesterday's sales per machine
      const yesterdayMap = new Map<string, { revenue: number; count: number }>()
      const yesterdayRows = (yesterdaySalesRes.data ?? []) as { machine_id: string; item_price: number }[]
      for (const row of yesterdayRows) {
        if (!row.machine_id) continue
        const entry = yesterdayMap.get(row.machine_id) ?? { revenue: 0, count: 0 }
        entry.revenue += row.item_price ?? 0
        entry.count += 1
        yesterdayMap.set(row.machine_id, entry)
      }

      // Aggregate this month's sales per machine
      const thisMonthMap = new Map<string, { revenue: number; count: number }>()
      const thisMonthRows = (thisMonthSalesRes.data ?? []) as { machine_id: string; item_price: number }[]
      for (const row of thisMonthRows) {
        if (!row.machine_id) continue
        const entry = thisMonthMap.get(row.machine_id) ?? { revenue: 0, count: 0 }
        entry.revenue += row.item_price ?? 0
        entry.count += 1
        thisMonthMap.set(row.machine_id, entry)
      }

      // Aggregate last month's sales per machine
      const lastMonthMap = new Map<string, { revenue: number; count: number }>()
      const lastMonthRows = (lastMonthSalesRes.data ?? []) as { machine_id: string; item_price: number }[]
      for (const row of lastMonthRows) {
        if (!row.machine_id) continue
        const entry = lastMonthMap.get(row.machine_id) ?? { revenue: 0, count: 0 }
        entry.revenue += row.item_price ?? 0
        entry.count += 1
        lastMonthMap.set(row.machine_id, entry)
      }

      // Dedupe paxcounter to latest per machine
      const paxMap = new Map<string, number>()
      const paxRows = (paxRes.data ?? []) as { machine_id: string; count: number }[]
      for (const row of paxRows) {
        if (!row.machine_id) continue
        if (!paxMap.has(row.machine_id)) {
          paxMap.set(row.machine_id, row.count)
        }
      }

      // Aggregate warehouse stock per product
      const { warehouseStockMap, hasWarehouses } = buildWarehouseStockInfo(
        (warehouseStockRes.data ?? []) as { product_id: string; quantity: number }[],
      )

      // Apply last sale results
      for (let i = 0; i < machines.value.length; i++) {
        const machine = machines.value[i]!
        const saleData = lastSaleResults[i]?.data as { created_at: string; item_price: number; item_number: number } | null
        machine.last_sale_at = saleData?.created_at ?? null
        machine.last_sale_amount = saleData?.item_price ?? null
        machine.last_sale_item_number = saleData?.item_number ?? null
      }

      // Apply aggregated data to machines
      for (const machine of machines.value) {
        const todayStats = todayMap.get(machine.id)
        machine.today_revenue = todayStats?.revenue ?? 0
        machine.today_sales_count = todayStats?.count ?? 0
        const yesterdayStats = yesterdayMap.get(machine.id)
        machine.yesterday_revenue = yesterdayStats?.revenue ?? 0
        machine.yesterday_sales_count = yesterdayStats?.count ?? 0
        const thisMonthStats = thisMonthMap.get(machine.id)
        machine.this_month_revenue = thisMonthStats?.revenue ?? 0
        machine.this_month_sales_count = thisMonthStats?.count ?? 0
        const lastMonthStats = lastMonthMap.get(machine.id)
        machine.last_month_revenue = lastMonthStats?.revenue ?? 0
        machine.last_month_sales_count = lastMonthStats?.count ?? 0
        machine.paxcounter_count = paxMap.get(machine.id) ?? null
      }

      // Aggregate stock stats per machine
      const trayRows = (traysRes.data ?? []) as {
        machine_id: string
        item_number: number
        product_id: string | null
        capacity: number
        current_stock: number
        min_stock: number
        fill_when_below: number
        products: { name: string; image_path: string | null; sellprice: number | null } | null
      }[]

      const stockMap = new Map<string, {
        total: number
        refillableEmpty: number
        refillableLow: number
        refillableFill: number
        noStockCount: number
        totalStock: number
        totalCapacity: number
        deficits: Map<string, { product_name: string; product_id: string | null; deficit: number; image_path: string | null; sellprice: number | null; in_stock: boolean; severity: 'critical' | 'low' | 'fill'; discontinued?: boolean }>
        noStockDeficits: Map<string, { product_name: string; product_id: string | null; deficit: number; image_path: string | null; sellprice: number | null; in_stock: boolean; severity: 'critical' | 'low' | 'fill'; discontinued?: boolean }>
        criticalProductIds: Set<string>
        fillBelowPending: { product_id: string | null; capacity: number; current_stock: number; item_number: number; products: { name: string; image_path: string | null; sellprice: number | null; discontinued?: boolean } | null }[]
      }>()

      // Pass 1: count low/empty trays, split by warehouse availability
      for (const tray of trayRows) {
        if (!tray.machine_id) continue
        let entry = stockMap.get(tray.machine_id)
        if (!entry) {
          entry = { total: 0, refillableEmpty: 0, refillableLow: 0, refillableFill: 0, noStockCount: 0, totalStock: 0, totalCapacity: 0, deficits: new Map(), noStockDeficits: new Map(), criticalProductIds: new Set(), fillBelowPending: [] }
          stockMap.set(tray.machine_id, entry)
        }
        entry.total++
        entry.totalStock += tray.current_stock
        entry.totalCapacity += tray.capacity

        const state = classifyTrayStock(tray)
        const isLow = state === 'low'
        const isEmpty = state === 'critical'
        const isFillBelow = state === 'fill'

        if (isLow || isEmpty) {
          // Skip unassigned trays — nothing to refill
          if (tray.product_id == null) continue

          const refillable = isProductRefillable(tray.product_id, warehouseStockMap, hasWarehouses)
          const deficit = tray.capacity - tray.current_stock
          const productName = tray.products?.name ?? `Slot ${tray.item_number}`
          const imagePath = tray.products?.image_path ?? null
          const sellprice = tray.products?.sellprice ?? null
          const discontinued = tray.products?.discontinued ?? false
          const key = tray.product_id

          const severity = isEmpty ? 'critical' : 'low'
          if (refillable) {
            if (isEmpty) entry.refillableEmpty++
            else entry.refillableLow++
            const existing = entry.deficits.get(key)
            if (existing) {
              existing.deficit += deficit
              if (severity === 'critical') existing.severity = 'critical'
            } else {
              entry.deficits.set(key, { product_name: productName, product_id: tray.product_id, deficit, image_path: imagePath, sellprice, in_stock: true, severity, discontinued })
            }
            entry.criticalProductIds.add(tray.product_id)
          } else {
            entry.noStockCount++
            const existing = entry.noStockDeficits.get(key)
            if (existing) {
              existing.deficit += deficit
              if (severity === 'critical') existing.severity = 'critical'
            } else {
              entry.noStockDeficits.set(key, { product_name: productName, product_id: tray.product_id, deficit, image_path: imagePath, sellprice, in_stock: false, severity, discontinued })
            }
          }
        }

        if (isFillBelow) {
          entry.fillBelowPending.push(tray)
        }
      }

      // Pass 2: fold fill_when_below deficits in for every machine (not gated on
      // already having a low/empty tray — a fill-only machine must still surface)
      for (const [, entry] of stockMap) {
        for (const tray of entry.fillBelowPending) {
          if (tray.product_id == null) continue
          const deficit = tray.capacity - tray.current_stock
          if (deficit <= 0) continue
          const refillable = isProductRefillable(tray.product_id, warehouseStockMap, hasWarehouses)
          if (refillable) entry.refillableFill++
          const productName = tray.products?.name ?? `Slot ${tray.item_number}`
          const imagePath = tray.products?.image_path ?? null
          const sellprice = tray.products?.sellprice ?? null
          const discontinued = tray.products?.discontinued ?? false
          const key = tray.product_id
          const targetMap = refillable ? entry.deficits : entry.noStockDeficits
          const existing = targetMap.get(key)
          if (existing) {
            existing.deficit += deficit
            // Don't downgrade severity — fill is lowest priority
          } else {
            targetMap.set(key, { product_name: productName, product_id: tray.product_id, deficit, image_path: imagePath, sellprice, in_stock: refillable, severity: 'fill', discontinued })
          }
        }
      }

      // Apply stock stats to machines
      for (const machine of machines.value) {
        const stock = stockMap.get(machine.id)
        if (stock) {
          machine.total_trays = stock.total
          machine.low_trays = stock.refillableLow + stock.refillableEmpty
          machine.empty_trays = stock.refillableEmpty
          machine.fill_trays = stock.refillableFill
          machine.stock_health = stock.refillableEmpty > 0
            ? 'critical'
            : stock.refillableLow > 0
              ? 'low'
              : stock.refillableFill > 0
                ? 'fill'
                : 'ok'
          machine.stock_percent = stock.totalCapacity > 0
            ? Math.round((stock.totalStock / stock.totalCapacity) * 100)
            : 0
          machine.tray_summary = Array.from(stock.deficits.values()).sort((a, b) => b.deficit - a.deficit)
          machine.critical_product_ids = stock.criticalProductIds
          machine.no_stock_trays = stock.noStockCount
          machine.no_stock_summary = Array.from(stock.noStockDeficits.values()).sort((a, b) => b.deficit - a.deficit)
        } else {
          machine.total_trays = 0
          machine.low_trays = 0
          machine.empty_trays = 0
          machine.fill_trays = 0
          machine.stock_health = 'ok'
          machine.stock_percent = 0
          machine.tray_summary = []
          machine.critical_product_ids = new Set()
          machine.no_stock_trays = 0
          machine.no_stock_summary = []
        }
      }

      // Sort machines by stock urgency: critical > low > ok, then by low_trays desc
      const healthOrder: Record<string, number> = { critical: 0, low: 1, fill: 2, ok: 3 }
      machines.value.sort((a, b) => {
        const ha = healthOrder[a.stock_health ?? 'ok']
        const hb = healthOrder[b.stock_health ?? 'ok']
        if (ha !== hb) return ha - hb
        return (b.low_trays ?? 0) - (a.low_trays ?? 0)
      })
    } finally {
      loading.value = false
    }
  }

  async function fetchUnassignedEmbeddeds() {
    const supabase = useSupabaseClient()

    const [allRes, assignedRes] = await Promise.all([
      supabase
        .from('embeddeds')
        .select('id, mac_address, subdomain, status, status_at, firmware_version, firmware_build_date, name'),
      supabase
        .from('vendingMachine')
        .select('embedded')
        .not('embedded', 'is', null),
    ])

    const assignedIds = new Set(
      (assignedRes.data ?? []).map((m: any) => m.embedded).filter(Boolean)
    )

    return ((allRes.data ?? []) as Embedded[]).filter(e => !assignedIds.has(e.id))
  }

  async function swapDevice(machineId: string, newEmbeddedId: string | null) {
    const supabase = useSupabaseClient()

    if (newEmbeddedId) {
      // Unassign this device from any other machine first
      await supabase
        .from('vendingMachine')
        .update({ embedded: null } as any)
        .eq('embedded', newEmbeddedId)
    }

    // Assign to target machine (or detach if null)
    const { error } = await supabase
      .from('vendingMachine')
      .update({ embedded: newEmbeddedId } as any)
      .eq('id', machineId)

    if (error) throw error
    await fetchMachines()
  }

  function subscribeToStatusUpdates() {
    const supabase = useSupabaseClient()
    const channel = supabase
      .channel('machines-realtime')
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'embeddeds' },
        (payload) => {
          const updated = payload.new as Embedded
          const machine = machines.value.find(m => m.embeddeds?.id === updated.id)
          if (machine && machine.embeddeds) {
            machine.embeddeds.status = updated.status
            machine.embeddeds.status_at = updated.status_at
            if (updated.firmware_version) {
              machine.embeddeds.firmware_version = updated.firmware_version
            }
            if (updated.firmware_build_date) {
              machine.embeddeds.firmware_build_date = updated.firmware_build_date
            }
            if (updated.mdb_diagnostics !== undefined) {
              machine.embeddeds.mdb_diagnostics = updated.mdb_diagnostics
            }
            if (updated.last_restart_reason !== undefined) {
              machine.embeddeds.last_restart_reason = updated.last_restart_reason
            }
            if (updated.last_restart_at !== undefined) {
              machine.embeddeds.last_restart_at = updated.last_restart_at
            }
            if (updated.online_since !== undefined) {
              machine.embeddeds.online_since = updated.online_since
            }
          }
        }
      )
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'vendingMachine' },
        () => {
          fetchMachines()
        }
      )
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'vendingMachine' },
        (payload) => {
          const updated = payload.new as Record<string, any>
          const machine = machines.value.find(m => m.id === updated.id)
          if (machine) {
            machine.name = updated.name
            machine.location_lat = updated.location_lat
            machine.location_lon = updated.location_lon
            machine.country_code = updated.country_code ?? null
            machine.address_street = updated.address_street ?? null
            machine.address_house_number = updated.address_house_number ?? null
            machine.address_postal_code = updated.address_postal_code ?? null
            machine.address_city = updated.address_city ?? null
            machine.formatted_address = updated.formatted_address ?? null
            // If embedded link changed, re-fetch to get the joined data
            if (machine.embedded !== updated.embedded) {
              fetchMachines()
            }
          }
        }
      )
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'sales' },
        (payload) => {
          const sale = payload.new as Record<string, any>
          const machine = machines.value.find(m => m.id === sale.machine_id)
          if (machine) {
            machine.last_sale_at = sale.created_at
            machine.last_sale_amount = sale.item_price
            machine.last_sale_item_number = sale.item_number ?? null

            // Update today's stats if the sale is from today
            const saleDate = new Date(sale.created_at)
            const now = new Date()
            if (
              saleDate.getFullYear() === now.getFullYear() &&
              saleDate.getMonth() === now.getMonth() &&
              saleDate.getDate() === now.getDate()
            ) {
              machine.today_revenue = (machine.today_revenue ?? 0) + (sale.item_price ?? 0)
              machine.today_sales_count = (machine.today_sales_count ?? 0) + 1
            }
          }
        }
      )
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'machine_trays' },
        () => {
          fetchMachines()
        }
      )
      .subscribe((_status, err) => {
        if (err) console.error('[realtime] machines channel error:', err)
      })

    return () => supabase.removeChannel(channel)
  }

  async function createMachine(
    name: string,
    companyId: string,
    location?: CreateMachineLocation,
  ): Promise<void> {
    const supabase = useSupabaseClient()
    const insertRow: Record<string, any> = { name, company: companyId }
    if (location) {
      insertRow.location_lat = location.location_lat
      insertRow.location_lon = location.location_lon
      insertRow.address_street = location.address_street
      insertRow.address_house_number = location.address_house_number
      insertRow.address_postal_code = location.address_postal_code
      insertRow.address_city = location.address_city
      insertRow.formatted_address = location.formatted_address
      insertRow.country_code = location.country_code
    }
    const { error } = await supabase.from('vendingMachine').insert(insertRow)
    if (error) throw error
    await fetchMachines()
  }

  async function updateMachineSettings(machineId: string, patch: MachineSettingsPatch): Promise<void> {
    const supabase = useSupabaseClient()
    const { error } = await supabase
      .from('vendingMachine')
      .update(patch as any)
      .eq('id', machineId)
    if (error) throw error
    // Optimistically update the local cache so the list re-renders without
    // waiting for the realtime subscription to fire.
    const machine = machines.value.find(m => m.id === machineId)
    if (machine) {
      machine.location_lat = patch.location_lat
      machine.location_lon = patch.location_lon
      machine.country_code = patch.country_code
      machine.address_street = patch.address_street
      machine.address_house_number = patch.address_house_number
      machine.address_postal_code = patch.address_postal_code
      machine.address_city = patch.address_city
      machine.formatted_address = patch.formatted_address
      machine.nayax_machine_id = patch.nayax_machine_id
      machine.item_number_offset = patch.item_number_offset
    }
  }

  const pendingTokens = useState<PendingToken[]>('pending-tokens', () => [])

  async function fetchPendingTokens() {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase
      .from('device_provisioning')
      .select('id, short_code, name, created_at, expires_at, device_only')
      .is('used_at', null)
      .order('created_at', { ascending: false })
    if (error) throw error
    pendingTokens.value = (data ?? []) as PendingToken[]
  }

  async function deletePendingToken(id: string) {
    const supabase = useSupabaseClient()
    const { error } = await supabase
      .from('device_provisioning')
      .delete()
      .eq('id', id)
    if (error) throw error
    await fetchPendingTokens()
  }

  return {
    machines, loading, fetchMachines, fetchUnassignedEmbeddeds, swapDevice, subscribeToStatusUpdates,
    createMachine, updateMachineSettings,
    pendingTokens, fetchPendingTokens, deletePendingToken,
  }
}
