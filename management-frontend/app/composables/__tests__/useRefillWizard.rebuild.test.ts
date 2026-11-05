import { describe, it, expect, vi, beforeEach } from 'vitest'
import { ref as vueRef, computed as vueComputed } from 'vue'

// Change note in the refill tour: every planned slot adds its units to the
// normal packing list (one line per machine and product, one tick for refill
// and rebuild), leaves the normal refill, and is quit via apply_slot_change
// BEFORE the normal refill RPC runs. Their leftovers are booked back once, at
// the end of the tour.

;(globalThis as any).ref = vueRef
;(globalThis as any).computed = vueComputed

const { rpcCalls, inserts, applySlotChange, fetchOpenRequests } = vi.hoisted(() => ({
  rpcCalls: [] as { fn: string; args: any }[],
  inserts: [] as { table: string; row: any }[],
  applySlotChange: vi.fn(async (_input: unknown): Promise<{ request_status: string }> => ({ request_status: 'done' })),
  fetchOpenRequests: vi.fn(),
}))

const env = vi.hoisted(() => ({
  machines: [{ id: 'm1', name: 'M1' }] as { id: string; name: string }[],
  extraTrays: [] as any[],
  stock: [{ product_id: 'cola', quantity: 30 }] as { product_id: string; quantity: number }[],
  requestStatus: 'open',
  applyError: null as string | null,
}))

const TRAYS = [
  { id: 't11', machine_id: 'm1', item_number: 11, product_id: 'cola', capacity: 10, current_stock: 2, min_stock: 0, fill_when_below: 5, products: { name: 'Cola', image_path: null, sellprice: 2 } },
  { id: 't12', machine_id: 'm1', item_number: 12, product_id: 'schorle', capacity: 10, current_stock: 8, min_stock: 0, fill_when_below: 0, products: { name: 'Schorle', image_path: null, sellprice: 1.8 } },
]

function query(data: unknown, table = '') {
  const q: any = {
    select: () => q, eq: () => q, in: () => q, gt: () => q, order: () => q, maybeSingle: () => q,
    insert: (row: unknown) => { inserts.push({ table, row }); return Promise.resolve({ error: null }) },
    then: (res: (v: unknown) => unknown) => Promise.resolve({ data, error: null }).then(res),
  }
  return q
}
const supabase = {
  from: (table: string) => query(
    table === 'vendingMachine' ? env.machines
      : table === 'machine_trays' ? [...TRAYS, ...env.extraTrays]
        : table === 'warehouse_stock_batches' ? env.stock
          : table === 'slot_change_requests' ? [{ status: env.requestStatus }]
            : table === 'warehouses' ? { name: 'Lager' } : [],
    table,
  ),
  rpc: (fn: string, args: any) => {
    rpcCalls.push({ fn, args })
    if (fn === 'refill_machine_trays') {
      return Promise.resolve({ data: args.p_trays.map((t: any) => ({ tray_id: t.tray_id, old_stock: 2, new_stock: 2 + t.fill_amount, fill_amount: t.fill_amount, was_already_applied: false })), error: null })
    }
    return Promise.resolve({ data: [], error: null })
  },
  auth: { getSession: async () => ({ data: { session: { user: { id: 'u1', email: 'a@b.c', user_metadata: {} } } } }) },
}

vi.mock('#imports', async () => {
  const vue = await import('vue')
  return { ...vue, useSupabaseClient: () => supabase }
})
vi.mock('../useOrganization', () => ({ useOrganization: () => ({ organization: vueRef({ id: 'c1' }) }) }))
vi.mock('../useWarehouse', () => ({ useWarehouse: () => ({ fetchOrderedProductIds: async () => [] }) }))
vi.mock('../useSlotChangeRequests', () => ({
  useSlotChangeRequests: () => ({ fetchOpenRequests, applySlotChange, suggestExpiry: async () => '2026-12-01' }),
}))

import { useRefillWizard } from '../useRefillWizard'

const ITEM = {
  id: 'i12', request_id: 'r1', tray_id: 't12', item_number: 12,
  from_product_id: 'schorle', to_product_id: 'cola', from_capacity: 10, to_capacity: 10,
  from_price: 1.8, to_price: 2, from_min_age: null as number | null, to_min_age: null as number | null, skip_count: 0, from_name: 'Schorle', to_name: 'Cola',
  from_image_path: null, to_image_path: null, from_image_url: null, to_image_url: null,
}

describe('refill tour with a change note', () => {
  beforeEach(() => {
    rpcCalls.length = 0
    inserts.length = 0
    applySlotChange.mockReset()
    applySlotChange.mockImplementation(async () => {
      if (env.applyError) throw new Error(env.applyError)
      return { request_status: 'done' }
    })
    env.machines = [{ id: 'm1', name: 'M1' }]
    env.extraTrays = []
    env.stock = [{ product_id: 'cola', quantity: 30 }]
    env.requestStatus = 'open'
    env.applyError = null
    fetchOpenRequests.mockResolvedValue(new Map([['m1', { id: 'r1', machine_id: 'm1', created_at: '', updated_at: '', note: null, items: [ITEM] }]]))
    try { localStorage.clear() } catch { /* ignore */ }
  })

  async function startedTour() {
    const w = useRefillWizard()
    await w.initTour()
    w.selectedWarehouseId.value = 'wh1'
    await w.loadWarehouseStock()
    return w
  }

  it('packs the rebuild on top of the normal refill and deducts once per product', async () => {
    const w = await startedTour()
    const machine = w.machines.value[0]!
    expect(machine.change_request?.items).toHaveLength(1)
    // Slot 12 is being rebuilt, so only cola's normal deficit (8) is listed
    expect(machine.tray_summary.map(i => [i.product_id, i.deficit])).toEqual([['cola', 8]])
    expect(w.rebuildNeeds('m1')).toEqual(new Map([['cola', 10]]))
    // Nothing is booked until cola is ticked as packed
    expect(w.rebuildCommitted('m1', 'cola')).toBe(0)

    // Refill and rebuild units of cola are one line with one tick
    expect(w.packLines(machine)).toEqual([
      expect.objectContaining({ product_id: 'cola', refill: 8, rebuild: 10, total: 18, slots: [12], ticked: false }),
    ])
    expect(w.combinedPackCards.value.map(c => [c.product_id, c.lines.map(l => [l.machine_id, l.total])])).toEqual([['cola', [['m1', 18]]]])
    expect(w.packBox.value).toEqual({ packed: 0, total: 18 })
    expect(w.openPackLines.value).toHaveLength(1)

    w.togglePacked('m1', machine.tray_summary[0]!)
    expect(w.rebuildCommitted('m1', 'cola')).toBe(10)
    expect(w.packLine(machine, 'cola')).toMatchObject({ ticked: true, refill: 8, rebuild: 10 })
    expect(w.packBox.value).toEqual({ packed: 18, total: 18 })
    expect(w.openPackLines.value).toEqual([])
    await w.startTour()

    const deductions = rpcCalls.filter(c => c.fn === 'deduct_warehouse_stock_fifo')
    expect(deductions.map(d => [d.args.p_product_id, d.args.p_quantity])).toEqual([['cola', 18]])
    // At the machine: the rebuilt slot is not part of the normal refill
    expect(w.currentTrays.value.map(t => t.id)).toEqual(['t11'])
    expect(w.currentRebuild.value.map(s => [s.item.id, s.removed, s.filled])).toEqual([['i12', 8, 10]])
  })

  it('quits the rebuild before the normal refill and books the old stock back at the end of the tour', async () => {
    const w = await startedTour()
    w.togglePacked('m1', w.machines.value[0]!.tray_summary[0]!)
    await w.startTour()

    expect(w.rebuildReady.value).toBe(false)
    w.setRebuildPriceSet('i12', true)
    w.setRebuildAction('i12', 'done')
    expect(w.rebuildLeftovers.value.map(l => [l.product_id, l.van, l.machine])).toEqual([['schorle', 0, 8]])

    await w.confirmMachineRefill()

    expect(applySlotChange).toHaveBeenCalledTimes(1)
    const input = applySlotChange.mock.calls[0]![0] as any
    expect(input.items).toEqual([{ item_id: 'i12', action: 'done', removed: 8, filled: 10, price_set: true, age_set: false }])
    // Nothing is booked at the machine: the old stock rides along in the van
    expect(input.leftovers).toEqual([])
    const refill = rpcCalls.find(c => c.fn === 'refill_machine_trays')!
    expect(refill.args.p_trays).toEqual([{ tray_id: 't11', fill_amount: 8 }])
    expect(w.tourLog.value[0]!.slots_rebuilt).toBe(1)
    // The history lists the rebuilt slot next to the refilled one
    expect(w.tourLog.value[0]!.total_added).toBe(18)
    const log = inserts.find(i => i.table === 'activity_log' && i.row.action === 'stock_refill_tour')!
    expect(log.row.metadata.products).toEqual([
      { product_id: 'cola', product_name: 'Cola', quantity: 8 },
      { product_id: 'cola', product_name: 'Cola', quantity: 10, item_number: 12, rebuild: true },
    ])
    expect(log.row.metadata.total_added).toBe(18)
    expect(log.row.metadata.trays_refilled).toBe(2)

    // End of the tour, back at the warehouse
    expect(w.currentStep.value).toBe('summary')
    expect(w.hasPendingLeftovers.value).toBe(true)
    await w.loadTourExpirySuggestions()
    expect(w.tourLeftoverRows.value).toEqual([expect.objectContaining({
      product_id: 'schorle', van: 0, machine: 8, destination: 'warehouse', expiration_date: '2026-12-01',
    })])
    w.setLeftoverCount('schorle', 'machine', 7)  // one was broken, counted at the warehouse
    expect(await w.returnTourLeftovers()).toBe(true)
    const ret = rpcCalls.find(c => c.fn === 'return_slot_change_leftovers')!
    expect(ret.args).toEqual({
      p_tour_id: expect.any(String),
      p_warehouse_id: 'wh1',
      p_leftovers: [{ product_id: 'schorle', van_qty: 0, machine_qty: 7, destination: 'warehouse', expiration_date: '2026-12-01', batch_number: 'Machine return' }],
    })
    expect(w.hasPendingLeftovers.value).toBe(false)
  })

  it('a product only the rebuild needs gets its own line in warehouse order', async () => {
    fetchOpenRequests.mockResolvedValue(new Map([['m1', { id: 'r1', machine_id: 'm1', created_at: '', updated_at: '', note: null, items: [
      { ...ITEM, to_product_id: 'mate', to_name: 'Mate' },
    ] }]]))
    const w = await startedTour()
    const machine = w.machines.value[0]!
    expect(w.packLines(machine).map(l => [l.product_id, l.refill_need, l.rebuild_need])).toEqual([['cola', 8, 0], ['mate', 0, 10]])
    expect(w.allLinesTicked(machine)).toBe(false)
    w.togglePacked('m1', machine.tray_summary[0]!)
    expect(w.allLinesTicked(machine)).toBe(false)
    w.toggleLine('m1', 'mate')
    expect(w.allLinesTicked(machine)).toBe(true)
    expect(w.combinedPackCards.value.map(c => c.product_id)).toEqual(['cola', 'mate'])
  })

  it('packing less takes it off the refill first', async () => {
    const w = await startedTour()
    const machine = w.machines.value[0]!
    w.togglePacked('m1', machine.tray_summary[0]!)
    expect(w.packLine(machine, 'cola')).toMatchObject({ total: 18, max_quantity: 18 })
    w.setLineQuantity('m1', 'cola', 13)
    expect(w.packLine(machine, 'cola')).toMatchObject({ refill: 3, rebuild: 10 })
    // Only half a spiral of the new product for now
    w.setLineQuantity('m1', 'cola', 5)
    expect(w.packLine(machine, 'cola')).toMatchObject({ refill: 0, rebuild: 5, shortfall: 13 })
    // Never more than the line needs, never below zero
    w.setLineQuantity('m1', 'cola', 99)
    expect(w.packLine(machine, 'cola')).toMatchObject({ refill: 8, rebuild: 10 })
    w.setLineQuantity('m1', 'cola', -1)
    expect(w.packLine(machine, 'cola')).toMatchObject({ refill: 0, rebuild: 0, ticked: true })
    w.setLineQuantity('m1', 'cola', 5)

    await w.startTour()
    const deductions = rpcCalls.filter(c => c.fn === 'deduct_warehouse_stock_fifo')
    expect(deductions.map(d => [d.args.p_product_id, d.args.p_quantity])).toEqual([['cola', 5]])
    // At the machine the fill suggestion follows what was packed
    expect(w.currentRebuild.value.map(s => [s.item.id, s.filled])).toEqual([['i12', 5]])
    expect(w.currentTrays.value).toEqual([])
  })

  it('caps the rebuild units at the warehouse stock', async () => {
    fetchOpenRequests.mockResolvedValue(new Map([['m1', { id: 'r1', machine_id: 'm1', created_at: '', updated_at: '', note: null, items: [
      { ...ITEM, to_product_id: 'mate', to_name: 'Mate' },
    ] }]]))
    const w = await startedTour()
    const machine = w.machines.value[0]!
    // No mate in the warehouse: the line stays, with nothing to pack
    expect(w.packLine(machine, 'mate')).toMatchObject({ max_quantity: 0, rebuild: 0, shortfall: 10, unavailable: false })
    w.setLineQuantity('m1', 'mate', 3)
    w.toggleLine('m1', 'mate')
    expect(w.rebuildCommitted('m1', 'mate')).toBe(0)
  })

  it('an unticked rebuild-only product is not booked out of the warehouse', async () => {
    fetchOpenRequests.mockResolvedValue(new Map([['m1', { id: 'r1', machine_id: 'm1', created_at: '', updated_at: '', note: null, items: [
      { ...ITEM, to_product_id: 'mate', to_name: 'Mate' },
    ] }]]))
    // 20 mate in the warehouse
    const w = await startedTour()
    w.warehouseStock.value = new Map([['cola', 30], ['mate', 20]])
    const machine = w.machines.value[0]!
    w.togglePacked('m1', machine.tray_summary[0]!)
    // The line still shows what would be packed
    expect(w.packLine(machine, 'mate')).toMatchObject({ rebuild_need: 10, rebuild: 10, ticked: false })
    expect(w.openPackLines.value.map(l => [l.product_id, l.total])).toEqual([['mate', 10]])
    expect(w.rebuildCommitted('m1', 'mate')).toBe(0)
    await w.startTour()
    const deductions = rpcCalls.filter(c => c.fn === 'deduct_warehouse_stock_fifo')
    expect(deductions.map(d => d.args.p_product_id)).toEqual(['cola'])
    // At the machine nothing comes from the van; the slot is still rebuilt
    expect(w.currentRebuild.value.map(s => [s.item.id, s.filled])).toEqual([['i12', 0]])
  })

  it('a ticked rebuild-only product is booked with the dialled amount', async () => {
    fetchOpenRequests.mockResolvedValue(new Map([['m1', { id: 'r1', machine_id: 'm1', created_at: '', updated_at: '', note: null, items: [
      { ...ITEM, to_product_id: 'mate', to_name: 'Mate' },
    ] }]]))
    const w = await startedTour()
    w.warehouseStock.value = new Map([['cola', 30], ['mate', 20]])
    w.setLineQuantity('m1', 'mate', 4)
    w.toggleLine('m1', 'mate')
    expect(w.rebuildCommitted('m1', 'mate')).toBe(4)
    await w.startTour()
    const deductions = rpcCalls.filter(c => c.fn === 'deduct_warehouse_stock_fifo')
    expect(deductions.map(d => [d.args.p_product_id, d.args.p_quantity])).toEqual([['mate', 4]])
  })

  it('lines get warehouse stock in the order they were ticked', async () => {
    env.machines = [{ id: 'm1', name: 'M1' }, { id: 'm2', name: 'M2' }]
    env.extraTrays = [{ id: 't21', machine_id: 'm2', item_number: 21, product_id: 'cola', capacity: 10, current_stock: 0, min_stock: 0, fill_when_below: 5, products: { name: 'Cola', image_path: null, sellprice: 2 } }]
    env.stock = [{ product_id: 'cola', quantity: 12 }]
    const w = await startedTour()
    const m1 = w.machines.value.find(m => m.id === 'm1')!
    const m2 = w.machines.value.find(m => m.id === 'm2')!

    // M2's refill is in the box first: M1 only gets what is left, rebuild first
    w.toggleLine('m2', 'cola')
    expect(w.packLine(m2, 'cola')).toMatchObject({ refill: 10, ticked: true })
    expect(w.packLine(m1, 'cola')).toMatchObject({ rebuild: 2, refill: 0, max_quantity: 2 })
    w.toggleLine('m1', 'cola')
    expect(w.packLine(m1, 'cola')).toMatchObject({ rebuild: 2, refill: 0, ticked: true })
    // A later tick never takes units away from a line already in the box
    expect(w.packLine(m2, 'cola')).toMatchObject({ refill: 10 })

    // The other way round: M1's rebuild and refill first
    w.toggleLine('m1', 'cola')
    w.toggleLine('m2', 'cola')
    w.toggleLine('m1', 'cola')
    expect(w.packLine(m1, 'cola')).toMatchObject({ rebuild: 10, refill: 2, ticked: true })
    expect(w.packLine(m2, 'cola')).toMatchObject({ refill: 0, unavailable: true })
  })

  it('every planned slot is packed: there is no decline at packing', async () => {
    const w = await startedTour()
    expect('toggleRebuildItem' in w).toBe(false)
    expect(w.rebuildNeeds('m1')).toEqual(new Map([['cola', 10]]))
    // A change note alone does not put the machine on the tour: its goods
    // have to be in the box.
    expect(w.hasAnyPackedItems()).toBe(false)
    w.toggleLine('m1', 'cola')
    expect(w.hasAnyPackedItems()).toBe(true)
  })

  it('a machine whose rebuild goods are not ticked stays off the tour', async () => {
    const w = await startedTour()
    await w.startTour()
    expect(w.machines.value).toEqual([])
  })

  it('skipping the machine leaves the slots open and returns the packed units at the end of the tour', async () => {
    const w = await startedTour()
    w.togglePacked('m1', w.machines.value[0]!.tray_summary[0]!)
    await w.startTour()
    await w.skipMachine()
    const input = applySlotChange.mock.calls[0]![0] as any
    expect(input.items[0]).toMatchObject({ item_id: 'i12', action: 'skip' })
    expect(input.leftovers).toEqual([])
    expect(w.tourLeftoverRows.value).toEqual([expect.objectContaining({ product_id: 'cola', van: 10, machine: 0 })])
  })

  it('a slot whose age limit changes can only be quit after the age setting is confirmed', async () => {
    fetchOpenRequests.mockResolvedValue(new Map([['m1', { id: 'r1', machine_id: 'm1', created_at: '', updated_at: '', note: null, items: [{ ...ITEM, to_min_age: 18 }] }]]))
    const w = await startedTour()
    w.togglePacked('m1', w.machines.value[0]!.tray_summary[0]!)
    await w.startTour()

    w.setRebuildPriceSet('i12', true)
    w.setRebuildAction('i12', 'done')
    expect(w.currentRebuild.value[0]!.action).toBeNull()
    w.setRebuildAgeSet('i12', true)
    w.setRebuildAction('i12', 'done')
    expect(w.currentRebuild.value[0]!.action).toBe('done')
    // Unticking it takes the slot back to undecided
    w.setRebuildAgeSet('i12', false)
    expect(w.currentRebuild.value[0]!.action).toBeNull()
    w.setRebuildAgeSet('i12', true)
    w.setRebuildAction('i12', 'done')

    await w.confirmMachineRefill()
    const input = applySlotChange.mock.calls[0]![0] as any
    expect(input.items[0]).toMatchObject({ item_id: 'i12', action: 'done', age_set: true })
  })

  it('a slot whose price changes can only be quit after the new price is confirmed', async () => {
    const w = await startedTour()
    w.togglePacked('m1', w.machines.value[0]!.tray_summary[0]!)
    await w.startTour()
    w.setRebuildAction('i12', 'done')
    expect(w.currentRebuild.value[0]!.action).toBeNull()
    w.setRebuildPriceSet('i12', true)
    w.setRebuildAction('i12', 'done')
    expect(w.currentRebuild.value[0]!.action).toBe('done')
    w.setRebuildPriceSet('i12', false)
    expect(w.currentRebuild.value[0]!.action).toBeNull()
  })

  it('a slot gets no more than the goods meant for the rebuild', async () => {
    const w = await startedTour()
    w.togglePacked('m1', w.machines.value[0]!.tray_summary[0]!)
    w.setLineQuantity('m1', 'cola', 6)  // 6 rebuild units, no refill
    await w.startTour()
    expect(w.maxRebuildFilled('i12')).toBe(6)
    w.setRebuildFilled('i12', 9)
    expect(w.currentRebuild.value[0]!.filled).toBe(6)
  })

  it('a slot loses the goods of a source slot that is skipped today', async () => {
    fetchOpenRequests.mockResolvedValue(new Map([['m1', { id: 'r1', machine_id: 'm1', created_at: '', updated_at: '', note: null, items: [
      // Schorle moves from slot 12 to slot 11, cola from 11 to 12
      { ...ITEM, id: 'i11', tray_id: 't11', item_number: 11, from_product_id: 'cola', to_product_id: 'schorle', from_name: 'Cola', to_name: 'Schorle', from_price: 2, to_price: 1.8 },
      ITEM,
    ] }]]))
    const w = await startedTour()
    for (const line of w.packLines(w.machines.value[0]!)) w.toggleLine('m1', line.product_id)
    await w.startTour()
    expect(w.skippedSourceSlots('i12')).toEqual([])
    const withSource = w.maxRebuildFilled('i12')
    w.setRebuildAction('i11', 'skip')
    expect(w.skippedSourceSlots('i12')).toEqual([11])
    // Only the packed units are left once the cola of slot 11 stays put.
    expect(w.maxRebuildFilled('i12')).toBeLessThan(withSource)
  })

  it('a change note withdrawn in the office is not rebuilt; its goods come back', async () => {
    env.requestStatus = 'withdrawn'
    const w = await startedTour()
    w.togglePacked('m1', w.machines.value[0]!.tray_summary[0]!)
    await w.startTour()
    expect(w.withdrawnRebuildMachines.value.has('m1')).toBe(true)
    expect(w.currentRebuild.value.map(s => [s.action, s.removed, s.filled])).toEqual([['skip', 0, 0]])
    expect(w.rebuildReady.value).toBe(true)
  })

  it('a change note withdrawn while at the machine does not block the tour', async () => {
    const w = await startedTour()
    w.togglePacked('m1', w.machines.value[0]!.tray_summary[0]!)
    await w.startTour()
    w.setRebuildPriceSet('i12', true)
    w.setRebuildAction('i12', 'done')
    env.applyError = 'change request is no longer open'
    await w.confirmMachineRefill()
    expect(applySlotChange).toHaveBeenCalledTimes(1)
    expect(w.confirmError.value).toBeNull()
    expect(w.rebuildWithdrawnNotice.value).toBe('M1')
    // The normal refill still ran; the rebuild units ride back
    expect(rpcCalls.find(c => c.fn === 'refill_machine_trays')!.args.p_trays).toEqual([{ tray_id: 't11', fill_amount: 8 }])
    expect(w.tourLog.value[0]!.slots_rebuilt).toBe(0)
    expect(w.tourLeftoverRows.value).toEqual([expect.objectContaining({ product_id: 'cola', van: 10, machine: 0 })])
  })
})
