import type { Ref } from 'vue'
import { useSupabaseClient } from '#imports'
import { buildWarehouseStockInfo, distributeAcrossSlots, groupNeedsRefill, groupTraysByProduct, isProductRefillable } from '@/lib/stock-health'
import { aggregateTourLeftovers, ageChanged, computeLeftovers, fillPlan, rebuildPackNeeds, sortPackRows, type ItemOutcome, type TourLeftover, type TourLeftoverEntry } from '@/lib/slotChange'
import { useOrganization } from './useOrganization'
import { useSlotChangeRequests, type SlotChangeItem, type SlotChangeLeftover, type SlotChangeRequest } from './useSlotChangeRequests'
import { useWarehouse } from './useWarehouse'
import { notesForPacking, useTourNotes, type TourNote } from './useTourNotes'

// ── Types ────────────────────────────────────────────────────────────────────

export type WizardStep = 'packing' | 'refill' | 'summary'

export interface RefillMachine {
  id: string
  name: string
  stock_health: 'ok' | 'low' | 'fill' | 'critical'
  stock_percent: number
  empty_trays: number
  low_trays: number
  total_trays: number
  tray_summary: RefillItem[]
  /** Open slot change request (pending items only), shown as a change note. */
  change_request?: SlotChangeRequest | null
}

export interface RefillItem {
  product_id: string | null
  product_name: string
  deficit: number
  image_path: string | null
  sellprice: number | null
  in_stock?: boolean
}

export type PickingMode = 'per-machine' | 'combined'

export interface CombinedPickItem {
  product_id: string
  product_name: string
  image_path: string | null
  sellprice: number | null
  total_deficit: number
  machines: { id: string; name: string; deficit: number }[]
}

export interface TrayForRefill {
  id: string
  item_number: number
  product_id: string | null
  product_name: string | null
  image_path: string | null
  sellprice: number | null
  capacity: number
  current_stock: number
  min_stock: number
  fill_when_below: number
  /** Amount the refiller will add (editable, defaults to packed amount or deficit) */
  fill_amount: number
}

export interface TourLogEntry {
  machine_id: string
  machine_name: string
  trays_refilled: number
  total_added: number
  skipped: boolean
  /** Slots switched to their new product at this stop. */
  slots_rebuilt?: number
}

/** One slot of the change note, as handled at the machine. */
export interface RebuildSlot {
  item: SlotChangeItem
  /** Stock in the slot right now (sales since packing already deducted). */
  live_stock: number
  /** Units of the old product taken out (editable, defaults to live_stock). */
  removed: number
  /** Units of the new product put in (editable, defaults to the fill plan). */
  filled: number
  filled_touched: boolean
  moved: number
  from_van: number
  action: 'done' | 'skip' | null
  price_set: boolean
  /** The machine's age setting was changed (required before 'done' when the restriction changes). */
  age_set: boolean
}

/** The slot gets a new price (a wrong price costs money at every sale). */
export function changesPrice(item: SlotChangeItem): boolean {
  return !!item.to_product_id && item.to_price != null && item.to_price !== item.from_price
}

/** Something must still be confirmed at the machine before the slot can be marked rebuilt: the new price, the age setting. */
export function needsConfirmation(slot: RebuildSlot): boolean {
  return (changesPrice(slot.item) && !slot.price_set) || (ageChanged(slot.item) && !slot.age_set)
}

/**
 * Everything one machine gets of one product on the packing list: the refill
 * of its slots and the units for its slot rebuilds, under one tick and one
 * amount ("3 refill + 5 rebuild slot 57").
 */
export interface PackLine {
  machine_id: string
  machine_name: string
  /** Product id (or the name for a slot without a product id). */
  product_id: string
  product_name: string
  image_path: string | null
  sellprice: number | null
  /** Units for the refill (0 when the warehouse has nothing left for it). */
  refill: number
  /** What the slots holding the product lack. */
  refill_need: number
  /** The refill can be packed (it has stock or is already ticked). */
  has_refill: boolean
  /** Units for slot rebuilds. */
  rebuild: number
  /** What the rebuilt slots need from the warehouse. */
  rebuild_need: number
  /** The slots that get the product in a rebuild. */
  slots: number[]
  ticked: boolean
  /** Most units the line can pack (slot need and warehouse stock). */
  max_quantity: number
  total: number
  need: number
  shortfall: number
  /** Nothing to pack: the warehouse has nothing left for this line. */
  unavailable: boolean
}

/** A product of the combined packing list with one line per machine. */
export interface PackCard {
  product_id: string
  product_name: string
  image_path: string | null
  sellprice: number | null
  lines: PackLine[]
}

/** Leftovers of the tour as shown at the end, with the quantities the refiller counted. */
export interface TourLeftoverRow extends TourLeftover {
  destination: 'warehouse' | 'waste'
  expiration_date: string | null
}

export interface RebuildLeftover {
  product_id: string
  name: string | null
  image_path: string | null
  van: number
  machine: number
}

// ── Persistence ──────────────────────────────────────────────────────────────

const STORAGE_KEY = 'refill-tour-state'

interface PersistedTourState {
  currentStep: WizardStep
  machines: RefillMachine[]
  currentMachineIndex: number
  selectedWarehouseId: string | null
  /** packedQuantities as [machineId, [productId, qty][]][] */
  packedQuantities: [string, [string, number][]][]
  /** completedMachineIds as string[] */
  completedMachineIds: string[]
  tourLog: TourLogEntry[]
  pickingMode?: PickingMode
  tourId?: string
  /** Slot change items the refiller declined at packing: [itemId, accepted][] */
  rebuildDecisions?: [string, boolean][]
  /** Units packed for slot rebuilds: [machineId, [productId, qty][]][] */
  rebuildPacked?: [string, [string, number][]][]
  /** Slot change leftovers per machine, booked back at the end of the tour. */
  tourLeftovers?: TourLeftoverEntry[]
  leftoversReturned?: boolean
  savedAt: number
}

/** Max age of persisted state (24 hours) */
const MAX_AGE_MS = 24 * 60 * 60 * 1000

/** Check if there is a saved tour to resume (standalone, no composable needed) */
export function hasSavedTour(): boolean {
  if (import.meta.server) return false
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return false
    const state = JSON.parse(raw) as PersistedTourState
    if (Date.now() - state.savedAt > MAX_AGE_MS) {
      localStorage.removeItem(STORAGE_KEY)
      return false
    }
    return state.currentStep === 'refill' || state.currentStep === 'summary'
  } catch {
    return false
  }
}

/** Clear saved tour state (standalone, no composable needed) */
export function clearSavedTourState(): void {
  if (import.meta.server) return
  try { localStorage.removeItem(STORAGE_KEY) } catch { /* ignore */ }
}

// ── tour_started activity payload ──────────────────────────────────────────

export interface TourStartedEntryInput {
  companyId: string | null | undefined
  user: { id?: string; email?: string | null; user_metadata?: Record<string, unknown> } | null
  tourId: string
  machines: { id: string; name: string }[]
  warehouseId: string | null
  warehouseName: string | null
}

/**
 * Build the `activity_log` insert payload for a tour start (spec:
 * docs/superpowers/specs/2026-06-11-ios-dashboard-activity-feed-design.md §3.1).
 * Pure function — unit-tested in __tests__/useRefillWizard.tourStarted.test.ts.
 * The iOS app writes a field-compatible payload; keep the two in sync.
 */
export function buildTourStartedEntry(input: TourStartedEntryInput) {
  const meta = (input.user?.user_metadata ?? {}) as Record<string, unknown>
  const fullName = [meta.first_name, meta.last_name]
    .filter(Boolean).join(' ').trim()
  const userDisplay = fullName || input.user?.email || null
  return {
    company_id: input.companyId ?? null,
    user_id: input.user?.id ?? null,
    entity_type: 'stock',
    entity_id: input.tourId,
    action: 'tour_started',
    metadata: {
      tour_id: input.tourId,
      machine_count: input.machines.length,
      machine_ids: input.machines.map(m => m.id),
      machine_names: input.machines.map(m => m.name),
      warehouse_id: input.warehouseId,
      warehouse_name: input.warehouseName,
      _user_email: input.user?.email ?? null,
      _user_display: userDisplay,
    },
  }
}

// ── refill snapshot ─────────────────────────────────────────────────────────

/**
 * Join the refill RPC's authoritative per-tray stock deltas with the
 * tray metadata (product) known client-side, producing the same shape
 * `useMachineTrays.ts`'s "refill all" snapshot uses — so both actions
 * render identically in the /history product-refill list.
 */
export function buildRefillSnapshot(
  results: { tray_id: string; old_stock: number; new_stock: number }[],
  traysToRefill: { id: string; item_number: number; product_id: string | null; product_name: string | null }[],
) {
  return results.map(r => {
    const tray = traysToRefill.find(t => t.id === r.tray_id)
    return {
      id: r.tray_id,
      item_number: tray?.item_number,
      product_name: tray?.product_name ?? undefined,
      product_id: tray?.product_id ?? undefined,
      old_stock: r.old_stock,
      new_stock: r.new_stock,
    }
  })
}

// ── Composable ───────────────────────────────────────────────────────────────

export function useRefillWizard() {
  const supabase = useSupabaseClient()
  const { organization } = useOrganization()
  const { fetchOrderedProductIds } = useWarehouse()
  const { fetchOpenRequests, applySlotChange, suggestExpiry } = useSlotChangeRequests()
  const tourNoteApi = useTourNotes()

  // Wizard state
  const currentStep = ref<WizardStep>('packing')
  const machines = ref<RefillMachine[]>([])
  const currentMachineIndex = ref(0)
  const selectedWarehouseId = ref<string | null>(null)
  const warehouseStock = ref(new Map<string, number>())
  const loading = ref(false)
  const tourStarting = ref(false)
  const confirmingRefill = ref(false)
  /** Surface for the last confirmMachineRefill failure after all retries.
   * Page reads this to show a banner; cleared on next confirm attempt. */
  const confirmError = ref<string | null>(null)
  const tourId = ref('')
  /** Open notes for this tour ("bring next time"), shown at the top of the packing step. */
  const tourNotes = ref<TourNote[]>([])

  // Packing state: machineId → Set<productKey>
  const packedItems = ref(new Map<string, Set<string>>())
  // Packed quantities: machineId → Map<productId, qty>
  const packedQuantities = ref(new Map<string, Map<string, number>>())
  // Committed quantities during packing: machineId → Map<productKey, qty>
  // Tracks how much warehouse stock is committed per machine per product
  const committedQuantities = ref(new Map<string, Map<string, number>>())
  // Custom quantities set by user during packing: machineId → Map<productId, qty>
  // When set, limits the committed quantity for that product+machine.
  // Unset = use full deficit (default behavior).
  const customQuantities = ref(new Map<string, Map<string, number>>())

  // Refill state: trays for the current machine
  const currentTrays = ref<TrayForRefill[]>([])
  const currentTraysLoading = ref(false)

  // Tour log
  const tourLog = ref<TourLogEntry[]>([])

  // Track which machines have been completed or skipped during refill step
  const completedMachineIds = ref(new Set<string>())

  // Picking mode and warehouse product order
  const pickingMode = ref<PickingMode>('per-machine')
  /** product_id → sort index (0-based). Empty = no positions defined. */
  const warehouseProductOrder = ref(new Map<string, number>())

  // ── Slot change requests ("Änderungsvermerk") ──
  // A machine's open change request rides along in RefillMachine.change_request.
  // The refiller accepts (default) or declines each slot while packing; accepted
  // slots leave the normal refill and get their own packing line. At the
  // machine they are rebuilt and quit via apply_slot_change, before the normal
  // refill of the other slots. Declined/skipped slots stay open server-side.
  /** item id → accepted; missing = accepted. */
  const rebuildDecisions = ref(new Map<string, boolean>())
  /** machineId → productId → units committed for rebuilds (packing step). */
  const committedRebuild = ref(new Map<string, Map<string, number>>())
  /** machineId → productId → units packed (deducted) for rebuilds. */
  const rebuildPacked = ref(new Map<string, Map<string, number>>())
  /**
   * machineId → productId → rebuild units the refiller dialled in (packing
   * step), e.g. only half a spiral of a new product. Missing = the full need.
   */
  const rebuildCustomQuantities = ref(new Map<string, Map<string, number>>())
  /** Raw tray rows per machine, kept during packing to recompute summaries. */
  const machineTrayRows = new Map<string, any[]>()
  let warehouseInfo: { warehouseStockMap: Map<string, number>; hasWarehouses: boolean } = { warehouseStockMap: new Map(), hasWarehouses: false }
  /** Rebuild cards of the current machine. */
  const currentRebuild = ref<RebuildSlot[]>([])
  const leftoverDestinations = ref(new Map<string, 'warehouse' | 'waste'>())
  /** productId → best-before date for goods taken out of the machine. */
  const leftoverExpiry = ref(new Map<string, string>())
  /** Batch number for goods returned from a machine (set localized by the page). */
  const returnBatchLabel = ref('Machine return')
  /** Packing ticks of rebuild-only rows (`machineId|productId`); only ticked units are booked, like a normal product. */
  const rebuildTicks = ref(new Set<string>())
  /** Tick order of the packing lines (`machineId|productKey`), see recalculateCommittedQuantities. */
  const lineTickSeq = ref(new Map<string, number>())
  let lineTickCounter = 0
  /**
   * Leftovers of the rebuilds, recorded per machine when it is quit and booked
   * back in one go at the end of the tour (return_slot_change_leftovers).
   */
  const tourLeftovers = ref<TourLeftoverEntry[]>([])
  const leftoversReturned = ref(false)
  /** Machines whose change note was withdrawn in the office after the tour loaded it. */
  const withdrawnRebuildMachines = ref(new Set<string>())
  /** Shown once when a withdrawn change note met slots already marked rebuilt. */
  const rebuildWithdrawnNotice = ref<string | null>(null)
  const returningLeftovers = ref(false)
  const returnLeftoversError = ref<string | null>(null)
  /** productId → quantities the refiller counted back at the warehouse. */
  const leftoverCounts = ref(new Map<string, { van: number; machine: number }>())

  // ── Computed ─────────────────────────────────────────────────────────────

  const currentMachine = computed(() => machines.value[currentMachineIndex.value] ?? null)

  const machinesNeedingRefill = computed(() =>
    machines.value.filter(m => m.stock_health !== 'ok')
  )

  const totalMachinesInTour = computed(() => {
    // Count machines that have at least one packed item
    return machines.value.filter(m => {
      const set = packedItems.value.get(m.id)
      return set && set.size > 0
    }).length
  })

  const currentMachineNumber = computed(() => currentMachineIndex.value + 1)

  // ── Packing helpers ──────────────────────────────────────────────────────

  function itemKey(item: { product_id: string | null; product_name: string }): string {
    return item.product_id ?? item.product_name
  }

  function isPacked(machineId: string, item: { product_id: string | null; product_name: string }): boolean {
    return packedItems.value.get(machineId)?.has(itemKey(item)) ?? false
  }

  /** Tick / untick a product of a machine: its whole line (refill and rebuild units). */
  function togglePacked(machineId: string, item: { product_id: string | null; product_name: string }) {
    toggleLine(machineId, itemKey(item))
  }

  function allPacked(machineId: string, items: RefillItem[]): boolean {
    if (!items || items.length === 0) return false
    const packable = items.filter(item => !isOutOfWarehouseStock(item, machineId))
    if (packable.length === 0) return false
    const set = packedItems.value.get(machineId)
    if (!set) return false
    return packable.every(item => set.has(itemKey(item)))
  }

  function getWarehouseAvailable(item: { product_id: string | null }): number | null {
    if (!selectedWarehouseId.value || !item.product_id) return null
    return warehouseStock.value.get(item.product_id) ?? 0
  }

  /**
   * Returns remaining warehouse stock for a product after subtracting
   * quantities committed (checked) by all machines.
   */
  function getWarehouseRemaining(productId: string): number {
    const total = warehouseStock.value.get(productId) ?? 0
    let committed = 0
    for (const [, machineMap] of committedQuantities.value) {
      committed += machineMap.get(productId) ?? 0
    }
    for (const [, machineMap] of committedRebuild.value) {
      committed += machineMap.get(productId) ?? 0
    }
    return Math.max(0, total - committed)
  }

  /** machineId → productKey → units, written without touching the input maps. */
  function setIn(map: Map<string, Map<string, number>>, machineId: string, key: string, qty: number) {
    const inner = map.get(machineId) ?? new Map<string, number>()
    inner.set(key, qty)
    map.set(machineId, inner)
  }

  /**
   * Recalculate committed quantities across all machines. A ticked line
   * (everything one machine gets of one product: refill and rebuild units)
   * lies in the box, so lines get their units in the order they were
   * ticked: a later tick only gets what is left and never takes units away
   * from a line already ticked. Within a line the rebuild comes first (a
   * planned slot cannot be done without its goods), the refill gets the rest.
   */
  function recalculateCommittedQuantities() {
    const restrict = !!selectedWarehouseId.value
    const remaining = new Map(warehouseStock.value)
    const entries: { machine: RefillMachine; index: number; key: string; seq: number }[] = []
    machines.value.forEach((machine, index) => {
      const keys = new Set<string>(packedItems.value.get(machine.id) ?? [])
      for (const pid of rebuildNeeds(machine.id).keys()) {
        if (isRebuildTaken(machine.id, pid)) keys.add(pid)
      }
      for (const key of keys) {
        entries.push({ machine, index, key, seq: lineTickSeq.value.get(`${machine.id}|${key}`) ?? Number.MAX_SAFE_INTEGER })
      }
    })
    entries.sort((a, b) => a.seq - b.seq || a.index - b.index)

    const newCommitted = new Map<string, Map<string, number>>()
    const newRebuild = new Map<string, Map<string, number>>()
    for (const { machine, key } of entries) {
      let avail = restrict ? (remaining.get(key) ?? 0) : Number.POSITIVE_INFINITY
      const need = rebuildNeeds(machine.id).get(key) ?? 0
      if (need > 0 && isRebuildTaken(machine.id, key)) {
        const wanted = Math.min(rebuildCustomQuantities.value.get(machine.id)?.get(key) ?? need, need)
        const qty = Math.max(0, Math.min(wanted, avail))
        if (qty > 0) {
          setIn(newRebuild, machine.id, key, qty)
          avail -= qty
        }
      }
      if (packedItems.value.get(machine.id)?.has(key)) {
        const item = machine.tray_summary.find(i => itemKey(i) === key)
        if (item?.product_id) {
          const custom = customQuantities.value.get(machine.id)?.get(item.product_id)
          const wanted = custom !== undefined ? Math.min(custom, item.deficit) : item.deficit
          const qty = Math.max(0, Math.min(wanted, avail))
          if (qty > 0) {
            setIn(newCommitted, machine.id, item.product_id, qty)
            avail -= qty
          }
        }
      }
      if (restrict) remaining.set(key, avail)
    }
    committedRebuild.value = newRebuild
    committedQuantities.value = newCommitted
  }

  function effectiveDeficit(item: { product_id: string | null; deficit: number }, machineId?: string): number {
    if (!selectedWarehouseId.value || !item.product_id) return item.deficit

    // If this item is checked for a specific machine, return committed qty
    if (machineId) {
      const checked = packedItems.value.get(machineId)
      if (checked?.has(itemKey(item))) {
        return committedQuantities.value.get(machineId)?.get(item.product_id) ?? 0
      }
    }

    // For unchecked items: show min(deficit, remaining warehouse stock)
    const remaining = getWarehouseRemaining(item.product_id)
    return Math.min(item.deficit, remaining)
  }

  function isOutOfWarehouseStock(item: { product_id: string | null }, machineId?: string): boolean {
    if (!selectedWarehouseId.value || !item.product_id) return false
    // If already checked for this machine, it has committed stock — not out of stock
    if (machineId) {
      const checked = packedItems.value.get(machineId)
      if (checked?.has(itemKey(item))) return false
    }
    const remaining = getWarehouseRemaining(item.product_id)
    return remaining <= 0
  }

  function hasPartialStock(item: { product_id: string | null; deficit: number }, machineId?: string): boolean {
    if (!selectedWarehouseId.value || !item.product_id) return false
    if (machineId) {
      const checked = packedItems.value.get(machineId)
      if (checked?.has(itemKey(item))) {
        const committed = committedQuantities.value.get(machineId)?.get(item.product_id) ?? 0
        return committed > 0 && committed < item.deficit
      }
    }
    const remaining = getWarehouseRemaining(item.product_id)
    return remaining > 0 && remaining < item.deficit
  }

  function hasAnyPackedItems(): boolean {
    for (const set of packedItems.value.values()) {
      if (set.size > 0) return true
    }
    return machines.value.some(m => newRebuildTicked(m) || isPureSwap(m))
  }

  /** A rebuild line of the machine is ticked. */
  function newRebuildTicked(machine: RefillMachine): boolean {
    return (committedRebuild.value.get(machine.id)?.size ?? 0) > 0
  }

  /** A change note that needs nothing from the warehouse: no line to tick, still a visit. */
  function isPureSwap(machine: RefillMachine): boolean {
    return acceptedItems(machine).length > 0 && ![...rebuildNeeds(machine.id).values()].some(n => n > 0)
  }

  // ── Change note (slot rebuilds) ─────────────────────────────────────────

  /**
   * Every planned slot is packed; whether it can be done is decided at the
   * machine ("not possible today"). Declines are only still read from a tour
   * saved by an older version of the app.
   */
  function isItemAccepted(itemId: string): boolean {
    return rebuildDecisions.value.get(itemId) !== false
  }

  function acceptedItems(machine: RefillMachine | null | undefined): SlotChangeItem[] {
    return (machine?.change_request?.items ?? []).filter(i => isItemAccepted(i.id))
  }

  /**
   * Units the accepted slots of a machine need for the rebuild. While packing
   * it is computed from the stock known now; once the tour started it is what
   * was actually packed.
   */
  function rebuildNeeds(machineId: string): Map<string, number> {
    if (currentStep.value !== 'packing') return rebuildPacked.value.get(machineId) ?? new Map()
    const machine = machines.value.find(m => m.id === machineId)
    const items = acceptedItems(machine)
    if (items.length === 0) return new Map()
    const stock = new Map<string, number>((machineTrayRows.get(machineId) ?? []).map(r => [r.id, r.current_stock]))
    return rebuildPackNeeds(items, stock)
  }

  /** The machine's rebuild units of a product lie in the box (its line is ticked). */
  function isRebuildTaken(machineId: string, productId: string): boolean {
    return rebuildTicks.value.has(`${machineId}|${productId}`)
  }

  /** What is committed for a rebuild product (≤ need when the warehouse runs short). */
  function rebuildCommitted(machineId: string, productId: string): number {
    return committedRebuild.value.get(machineId)?.get(productId) ?? 0
  }

  // ── Pack lines (one tick per machine and product) ───────────────────────

  /**
   * Warehouse units a machine's line of a product can use: what the lines of
   * the other machines left. Unlimited without a warehouse or for a product
   * without an id.
   */
  function lineAvailable(machineId: string, key: string, hasProductId: boolean): number {
    if (!selectedWarehouseId.value || !hasProductId) return Number.POSITIVE_INFINITY
    let others = 0
    for (const [mid, m] of committedQuantities.value) if (mid !== machineId) others += m.get(key) ?? 0
    for (const [mid, m] of committedRebuild.value) if (mid !== machineId) others += m.get(key) ?? 0
    return Math.max(0, (warehouseStock.value.get(key) ?? 0) - others)
  }

  /** One machine's line of a product: its refill and the units for its slot rebuilds. */
  function packLine(machine: RefillMachine, key: string): PackLine {
    const item = machine.tray_summary.find(i => itemKey(i) === key)
    const refillNeed = item?.deficit ?? 0
    const rebuildNeed = rebuildNeeds(machine.id).get(key) ?? 0
    const change = acceptedItems(machine).filter(i => i.to_product_id === key)
    const hasProductId = !!item?.product_id || rebuildNeed > 0
    const avail = lineAvailable(machine.id, key, hasProductId)
    const packed = packedItems.value.get(machine.id)?.has(key) ?? false
    const hasRefill = refillNeed > 0 && (packed || avail > 0)
    const rebuildTaken = rebuildNeed > 0 && isRebuildTaken(machine.id, key)

    let rebuild = 0
    if (rebuildTaken) rebuild = rebuildCommitted(machine.id, key)
    else if (rebuildNeed > 0) {
      const wanted = Math.min(rebuildCustomQuantities.value.get(machine.id)?.get(key) ?? rebuildNeed, rebuildNeed)
      rebuild = Math.min(wanted, avail)
    }
    let refill = 0
    if (packed) {
      refill = item?.product_id ? (committedQuantities.value.get(machine.id)?.get(key) ?? 0) : refillNeed
    } else if (hasRefill) {
      const custom = item?.product_id ? customQuantities.value.get(machine.id)?.get(key) : undefined
      const wanted = custom !== undefined ? Math.min(custom, refillNeed) : refillNeed
      refill = Math.max(0, Math.min(wanted, avail - rebuild))
    }
    const ticked = (hasRefill || rebuildNeed > 0)
      && (!hasRefill || packed)
      && (rebuildNeed === 0 || rebuildTaken)
    const total = refill + rebuild
    const need = refillNeed + rebuildNeed
    return {
      machine_id: machine.id,
      machine_name: machine.name,
      product_id: key,
      product_name: item?.product_name ?? change[0]?.to_name ?? '?',
      image_path: item?.image_path ?? change[0]?.to_image_path ?? null,
      sellprice: item?.sellprice ?? change[0]?.to_price ?? null,
      refill,
      refill_need: refillNeed,
      has_refill: hasRefill,
      rebuild,
      rebuild_need: rebuildNeed,
      slots: change.map(i => i.item_number).sort((a, b) => a - b),
      ticked,
      max_quantity: Math.min(rebuildNeed + (hasRefill ? refillNeed : 0), avail),
      total,
      need,
      shortfall: Math.max(0, need - total),
      unavailable: !hasRefill && rebuildNeed === 0,
    }
  }

  /** Every line of one machine, in warehouse order (unavailable ones included, shown dimmed). */
  function packLines(machine: RefillMachine): PackLine[] {
    const keys: string[] = []
    for (const item of machine.tray_summary) {
      if (item.deficit > 0 && !keys.includes(itemKey(item))) keys.push(itemKey(item))
    }
    for (const [pid, need] of rebuildNeeds(machine.id)) {
      if (need > 0 && !keys.includes(pid)) keys.push(pid)
    }
    return sortPackRows(keys.map(k => packLine(machine, k)), warehouseProductOrder.value)
  }

  /** Tick / untick a machine's line of a product; ticking pins what goes into the box. */
  function toggleLine(machineId: string, key: string) {
    const machine = machines.value.find(m => m.id === machineId)
    if (!machine) return
    const line = packLine(machine, key)
    if (line.unavailable) return
    const k = `${machineId}|${key}`
    const ticks = new Set(rebuildTicks.value)
    const packed = new Map(packedItems.value)
    const set = new Set(packed.get(machineId) ?? [])
    const seq = new Map(lineTickSeq.value)
    if (line.ticked) {
      ticks.delete(k)
      set.delete(key)
      seq.delete(k)
      deleteIn(rebuildCustomQuantities, machineId, key)
      deleteIn(customQuantities, machineId, key)
    } else {
      seq.set(k, ++lineTickCounter)
      if (line.rebuild_need > 0) ticks.add(k)
      if (line.has_refill) set.add(key)
    }
    packed.set(machineId, set)
    packedItems.value = packed
    rebuildTicks.value = ticks
    lineTickSeq.value = seq
    recalculateCommittedQuantities()
    if (!line.ticked) {
      // Pin the amounts: a line in the box keeps them whatever is ticked later.
      if (line.rebuild_need > 0) writeIn(rebuildCustomQuantities, machineId, key, rebuildCommitted(machineId, key))
      if (line.has_refill && machine.tray_summary.some(i => i.product_id === key)) {
        writeIn(customQuantities, machineId, key, committedQuantities.value.get(machineId)?.get(key) ?? 0)
      }
      recalculateCommittedQuantities()
    }
  }

  /**
   * Set a line's amount. The rebuild units are filled first (a planned slot
   * needs its goods), the rest goes to the refill, so packing less takes it
   * off the refill first.
   */
  function setLineQuantity(machineId: string, key: string, qty: number) {
    const machine = machines.value.find(m => m.id === machineId)
    if (!machine) return
    const line = packLine(machine, key)
    const total = Math.max(0, Math.min(line.max_quantity, Math.round(qty)))
    const rebuild = Math.min(total, line.rebuild_need)
    if (line.rebuild_need > 0) writeIn(rebuildCustomQuantities, machineId, key, rebuild)
    if (line.has_refill && machine.tray_summary.some(i => i.product_id === key)) {
      writeIn(customQuantities, machineId, key, total - rebuild)
    }
    recalculateCommittedQuantities()
  }

  function writeIn(target: Ref<Map<string, Map<string, number>>>, machineId: string, key: string, qty: number) {
    const next = new Map(target.value)
    const inner = new Map(next.get(machineId) ?? [])
    inner.set(key, qty)
    next.set(machineId, inner)
    target.value = next
  }

  function deleteIn(target: Ref<Map<string, Map<string, number>>>, machineId: string, key: string) {
    const inner = target.value.get(machineId)
    if (!inner?.has(key)) return
    const next = new Map(target.value)
    const copy = new Map(inner)
    copy.delete(key)
    if (copy.size === 0) next.delete(machineId)
    else next.set(machineId, copy)
    target.value = next
  }

  /** Every line of a machine that can be packed is in the box. */
  function allLinesTicked(machine: RefillMachine): boolean {
    const lines = packLines(machine).filter(l => !l.unavailable)
    return lines.length > 0 && lines.every(l => l.ticked)
  }

  /** Units ticked into the box vs. all units on the packing list. */
  const packBox = computed(() => {
    let packed = 0
    let total = 0
    for (const machine of machines.value) {
      for (const line of packLines(machine)) {
        total += line.total
        if (line.ticked) packed += line.total
      }
    }
    return { packed, total }
  })

  /** Machines with at least one line in the box. */
  const machinesReady = computed(() => machines.value.filter(m => packLines(m).some(l => l.ticked)).length)

  /** Lines with units that are not ticked: they stay in the warehouse when the tour starts. */
  const openPackLines = computed<PackLine[]>(() =>
    machines.value.flatMap(m => packLines(m).filter(l => !l.ticked && !l.unavailable && l.total > 0)))

  /** Set a custom packing quantity for a product on a specific machine */
  function setCustomQuantity(machineId: string, productId: string, qty: number) {
    // Find the deficit for this product on this machine
    const machine = machines.value.find(m => m.id === machineId)
    const item = machine?.tray_summary.find(i => i.product_id === productId)
    if (!item) return

    const totalStock = warehouseStock.value.get(productId) ?? item.deficit
    const maxQty = Math.min(item.deficit, totalStock)
    const clamped = Math.max(1, Math.min(maxQty, qty))

    const machineCustom = customQuantities.value.get(machineId) ?? new Map<string, number>()
    machineCustom.set(productId, clamped)
    customQuantities.value.set(machineId, machineCustom)
    customQuantities.value = new Map(customQuantities.value)
    recalculateCommittedQuantities()
  }

  /** Get the custom quantity for a product on a machine, or null if not set */
  function getCustomQuantity(machineId: string, productId: string): number | null {
    return customQuantities.value.get(machineId)?.get(productId) ?? null
  }

  /** Get the max allowed custom quantity for a product on a machine */
  function getMaxCustomQuantity(machineId: string, item: { product_id: string | null; deficit: number }): number {
    if (!item.product_id) return item.deficit
    const totalStock = warehouseStock.value.get(item.product_id) ?? item.deficit
    return Math.min(item.deficit, totalStock)
  }

  /**
   * Get the displayed packing quantity for a checked item.
   * Returns the custom quantity (user's intent) if set, otherwise the committed quantity (default).
   * This is what the quantity adjuster shows and operates on.
   */
  function getDisplayedPackingQty(machineId: string, item: { product_id: string | null; deficit: number }): number {
    if (!item.product_id) return effectiveDeficit(item, machineId)
    const customQty = customQuantities.value.get(machineId)?.get(item.product_id)
    if (customQty !== undefined) return customQty
    // No custom qty: return the committed (default) amount
    return effectiveDeficit(item, machineId)
  }

  // ── Init ─────────────────────────────────────────────────────────────────

  /**
   * Stock summary of one machine for the packing list. Counts are products:
   * all slots of a product in a machine are one group (lib/stock-health.ts),
   * so a product that is empty in one spiral but stocked in another doesn't
   * put the machine on the tour, and a product that does is packed for all of
   * its slots. Slots with an accepted change are left out — they get the
   * rebuild instead of a normal refill. Returns null when the machine needs
   * neither a refill nor a rebuild.
   */
  function buildRefillMachine(
    m: { id: string; name: string | null },
    rows: any[],
    request: SlotChangeRequest | null,
  ): RefillMachine | null {
    const excluded = new Set(
      (request?.items ?? []).filter(i => isItemAccepted(i.id)).map(i => i.tray_id),
    )
    let empty = 0, low = 0, fill = 0, totalStock = 0, totalCapacity = 0
    const deficits: RefillItem[] = []
    for (const tray of rows) {
      totalStock += tray.current_stock
      totalCapacity += tray.capacity
    }
    for (const group of groupTraysByProduct(rows.filter(r => !excluded.has(r.id)))) {
      if (!groupNeedsRefill(group)) continue
      if (isProductRefillable(group.product_id, warehouseInfo.warehouseStockMap, warehouseInfo.hasWarehouses)) {
        if (group.state === 'critical') empty++
        else if (group.state === 'low') low++
        else fill++
      }
      const first = group.trays[0]
      deficits.push({
        product_name: first.products?.name ?? `Slot ${first.item_number}`,
        product_id: group.product_id,
        deficit: group.deficit,
        image_path: first.products?.image_path ?? null,
        sellprice: first.products?.sellprice ?? null,
      })
    }
    const hasRequest = (request?.items.length ?? 0) > 0
    if (!hasRequest && empty === 0 && low === 0 && fill === 0) return null
    return {
      id: m.id,
      name: m.name ?? 'Unnamed',
      stock_health: empty > 0 ? 'critical' : low > 0 ? 'low' : fill > 0 ? 'fill' : 'ok',
      stock_percent: totalCapacity > 0 ? Math.round((totalStock / totalCapacity) * 100) : 0,
      empty_trays: empty,
      low_trays: low + empty,
      total_trays: rows.length,
      tray_summary: deficits.sort((a, b) => b.deficit - a.deficit),
      change_request: hasRequest ? request : null,
    }
  }


  async function initTour() {
    loading.value = true
    try {
      // Fetch machines with stock data (reuse fetchMachines logic via direct query)
      const { data: machineData, error: machErr } = await supabase
        .from('vendingMachine')
        .select('id, name')

      if (machErr) throw machErr

      const machineIds = (machineData ?? []).map((m: any) => m.id)
      if (machineIds.length === 0) {
        machines.value = []
        tourNotes.value = []
        return
      }

      // Fetch all trays + company-wide warehouse stock (to tell whether a
      // low/empty/fill-below tray is actually refillable, same check /machines uses)
      const [trayRes, warehouseStockRes, requests, openNotes] = await Promise.all([
        (supabase as any)
          .from('machine_trays')
          .select('id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, sellprice)')
          .in('machine_id', machineIds),
        (supabase as any)
          .from('warehouse_stock_batches')
          .select('product_id, quantity')
          .gt('quantity', 0),
        // A failing change-request lookup must never block a normal tour.
        fetchOpenRequests(machineIds).catch((err: unknown) => {
          console.warn('[refillWizard] change requests unavailable:', err)
          return new Map<string, SlotChangeRequest>()
        }),
        // Same for the notes from the last tours.
        tourNoteApi.fetchOpenNotes().catch((err: unknown) => {
          console.warn('[refillWizard] tour notes unavailable:', err)
          return [] as TourNote[]
        }),
      ])
      tourNotes.value = notesForPacking(openNotes, tourId.value)

      if (trayRes.error) throw trayRes.error

      warehouseInfo = buildWarehouseStockInfo(
        (warehouseStockRes.data ?? []) as { product_id: string; quantity: number }[],
      )

      machineTrayRows.clear()
      for (const tray of ((trayRes.data ?? []) as any[]).filter(t => t.machine_id)) {
        const rows = machineTrayRows.get(tray.machine_id) ?? []
        rows.push({ ...tray, min_stock: tray.min_stock ?? 0, fill_when_below: tray.fill_when_below ?? 0 })
        machineTrayRows.set(tray.machine_id, rows)
      }

      // Build RefillMachine list (machines needing refill or with a change note)
      const result: RefillMachine[] = []
      for (const m of (machineData ?? []) as any[]) {
        const built = buildRefillMachine(m, machineTrayRows.get(m.id) ?? [], requests.get(m.id) ?? null)
        if (built) result.push(built)
      }

      // Sort by urgency
      const healthOrder: Record<string, number> = { critical: 0, low: 1, fill: 2, ok: 3 }
      result.sort((a, b) => {
        const ha = healthOrder[a.stock_health] ?? 2
        const hb = healthOrder[b.stock_health] ?? 2
        if (ha !== hb) return ha - hb
        return b.low_trays - a.low_trays
      })

      machines.value = result
    } finally {
      loading.value = false
    }
  }

  async function loadWarehouseStock() {
    if (!selectedWarehouseId.value) {
      warehouseStock.value = new Map()
      warehouseProductOrder.value = new Map()
      return
    }
    try {
      // Fetch stock and product positions (depth-first via groups) in parallel
      const [stockRes, orderedIds] = await Promise.all([
        (supabase as any)
          .from('warehouse_stock_batches')
          .select('product_id, quantity')
          .eq('warehouse_id', selectedWarehouseId.value)
          .gt('quantity', 0),
        fetchOrderedProductIds(selectedWarehouseId.value).catch(() => [] as string[]),
      ])
      if (stockRes.error) throw stockRes.error

      const map = new Map<string, number>()
      for (const b of (stockRes.data ?? []) as any[]) {
        map.set(b.product_id, (map.get(b.product_id) ?? 0) + b.quantity)
      }
      warehouseStock.value = map

      // Build position order map: product_id → index (depth-first group traversal)
      const orderMap = new Map<string, number>()
      for (let i = 0; i < orderedIds.length; i++) {
        orderMap.set(orderedIds[i], i)
      }
      warehouseProductOrder.value = orderMap

      recalculateCommittedQuantities()
    } catch {
      warehouseStock.value = new Map()
      warehouseProductOrder.value = new Map()
      recalculateCommittedQuantities()
    }
  }

  // Compute effective stock health considering warehouse availability
  // Uses raw warehouse stock (not remaining after commits) so checked items
  // don't cause the machine card to collapse.
  function effectiveStockHealth(machine: RefillMachine): string {
    if (machine.stock_health === 'ok') return 'ok'
    if (!selectedWarehouseId.value) return machine.stock_health
    // If every product in tray_summary is out of warehouse stock, downgrade to ok
    const hasRefillable = machine.tray_summary.some(item => {
      if (!item.product_id) return true
      const total = warehouseStock.value.get(item.product_id) ?? 0
      return total > 0
    })
    return hasRefillable ? machine.stock_health : 'ok'
  }

  // ── Start Tour (warehouse deduction) ────────────────────────────────────

  async function startTour() {
    if (!selectedWarehouseId.value) return
    tourStarting.value = true
    tourId.value = self.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`

    try {
      const { data: { session } } = await supabase.auth.getSession()

      // Collect all deductions from committed quantities
      const deductions: { machine_id: string; product_id: string; quantity: number }[] = []

      const newRebuildPacked = new Map<string, Map<string, number>>()
      for (const machine of machines.value) {
        const committed = committedQuantities.value.get(machine.id) ?? new Map<string, number>()
        const rebuild = committedRebuild.value.get(machine.id) ?? new Map<string, number>()
        if (committed.size === 0 && rebuild.size === 0) continue

        const machinePackedQty = new Map<string, number>()
        const total = new Map<string, number>()

        for (const [productId, qty] of committed) {
          if (qty <= 0) continue
          machinePackedQty.set(productId, (machinePackedQty.get(productId) ?? 0) + qty)
          total.set(productId, (total.get(productId) ?? 0) + qty)
        }
        for (const [productId, qty] of rebuild) {
          if (qty <= 0) continue
          total.set(productId, (total.get(productId) ?? 0) + qty)
        }
        // One deduction per (machine, product); rebuild units are tracked
        // separately so unused ones can go back to their batch later.
        for (const [productId, qty] of total) {
          deductions.push({ machine_id: machine.id, product_id: productId, quantity: qty })
        }

        if (machinePackedQty.size > 0) packedQuantities.value.set(machine.id, machinePackedQty)
        if (rebuild.size > 0) newRebuildPacked.set(machine.id, new Map(rebuild))
      }

      // Execute all deductions in parallel
      const deductionResults = await Promise.all(
        deductions.map(d =>
          (supabase as any).rpc('deduct_warehouse_stock_fifo', {
            p_warehouse_id: selectedWarehouseId.value,
            p_product_id: d.product_id,
            p_quantity: d.quantity,
            p_user_id: session?.user?.id ?? null,
            p_reference_id: d.machine_id,
            p_notes: 'Refill tour',
            p_metadata: { _user_email: session?.user?.email ?? null, tour_id: tourId.value },
          })
        )
      )
      const firstError = deductionResults.find(r => r.error)
      if (firstError) throw firstError.error
      rebuildPacked.value = newRebuildPacked

      // Filter machines list to those with a line in the box (refill or
      // rebuild units), preserve order. A change note alone does not put a
      // machine on the tour; only a pure swap, which needs nothing from the
      // warehouse and so has no line to tick, still means a visit.
      const tourMachines = machines.value
        .filter((m) => {
          const qty = packedQuantities.value.get(m.id)
          return (qty && qty.size > 0) || newRebuildPacked.has(m.id) || isPureSwap(m)
        })
        .map((m) => {
          const items = acceptedItems(m)
          return { ...m, change_request: m.change_request && items.length > 0 ? { ...m.change_request, items } : null }
        })
      machines.value = tourMachines

      // Tour-started activity entry (non-critical — failures only logged).
      // Written only after all deductions succeeded so an aborted tour start
      // never leaves an orphaned feed entry (spec §3.1).
      try {
        // Name lookup failure must not suppress the entry itself — a
        // name-less tour_started beats no entry.
        let warehouseName: string | null = null
        try {
          if (selectedWarehouseId.value) {
            const { data: wh } = await (supabase as any)
              .from('warehouses')
              .select('name')
              .eq('id', selectedWarehouseId.value)
              .maybeSingle()
            warehouseName = wh?.name ?? null
          }
        } catch { /* non-critical */ }
        await (supabase as any).from('activity_log').insert(
          buildTourStartedEntry({
            companyId: organization.value?.id,
            user: session?.user ?? null,
            tourId: tourId.value,
            machines: tourMachines.map(m => ({ id: m.id, name: m.name })),
            warehouseId: selectedWarehouseId.value,
            warehouseName,
          }),
        )
      } catch (logErr) {
        console.warn('[refillWizard] tour_started activity_log write failed:', logErr)
      }

      currentMachineIndex.value = 0
      tourLog.value = []
      currentStep.value = 'refill'

      // Load trays for first machine
      if (machines.value.length > 0) {
        await loadTraysForCurrentMachine()
      } else {
        currentStep.value = 'summary'
      }

      saveTourState()
    } finally {
      tourStarting.value = false
    }
  }

  // ── Refill step ────────────────────────────────────────────────────────

  async function loadTraysForCurrentMachine() {
    const machine = currentMachine.value
    if (!machine) return

    currentTraysLoading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('machine_trays')
        .select('id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, sellprice)')
        .eq('machine_id', machine.id)
        .order('item_number')

      if (error) throw error

      // Withdrawn in the office after the tour loaded it?
      let withdrawn = withdrawnRebuildMachines.value.has(machine.id)
      if (!withdrawn && machine.change_request) {
        try {
          const { data: req, error: reqErr } = await (supabase as any)
            .from('slot_change_requests')
            .select('status')
            .eq('id', machine.change_request.id)
          if (!reqErr) withdrawn = (req as { status: string }[] | null)?.[0]?.status !== 'open'
        } catch { /* keep the note; apply_slot_change will tell */ }
      }

      const packed = packedQuantities.value.get(machine.id) ?? new Map<string, number>()

      // Build tray list: every slot of a product that needs refill, with the
      // packed amount spread emptiest-slot-first. Slots that get nothing
      // (out-of-stock products, or fewer units packed than slots need) are hidden.
      const rows = ((data ?? []) as any[]).map(t => ({
        ...t,
        min_stock: t.min_stock ?? 0,
        fill_when_below: t.fill_when_below ?? 0,
      }))

      // Slots being rebuilt are handled by the change note, not the refill.
      const rebuildItems = acceptedItems(machine)
      const rebuildTrayIds = new Set(rebuildItems.map(i => i.tray_id))
      const rowById = new Map(rows.map(r => [r.id, r]))
      currentRebuild.value = rebuildItems
        .filter(item => rowById.has(item.tray_id))
        .map((item) => {
          const live = rowById.get(item.tray_id)!.current_stock as number
          return { item, live_stock: live, removed: live, filled: 0, filled_touched: false, moved: 0, from_van: 0, action: null, price_set: false, age_set: false }
        })
      if (withdrawn) markRebuildWithdrawn(machine.id)
      recomputeRebuildFill()

      const fillByTrayId = new Map<string, number>()
      for (const group of groupTraysByProduct(rows.filter(r => !rebuildTrayIds.has(r.id)))) {
        if (!groupNeedsRefill(group)) continue
        const amounts = distributeAcrossSlots(group.trays, packed.get(group.product_id) ?? 0)
        group.trays.forEach((t, i) => fillByTrayId.set(t.id, amounts[i]!))
      }

      const trays: TrayForRefill[] = []
      for (const t of rows) {
        const fillAmount = fillByTrayId.get(t.id) ?? 0
        if (fillAmount <= 0) continue

        trays.push({
          id: t.id,
          item_number: t.item_number,
          product_id: t.product_id,
          product_name: t.products?.name ?? null,
          image_path: t.products?.image_path ?? null,
          sellprice: t.products?.sellprice ?? null,
          capacity: t.capacity,
          current_stock: t.current_stock,
          min_stock: t.min_stock,
          fill_when_below: t.fill_when_below,
          fill_amount: fillAmount,
        })
      }

      currentTrays.value = trays
    } finally {
      currentTraysLoading.value = false
    }
  }

  // ── Rebuild at the machine ─────────────────────────────────────────────

  /** Refresh the suggested fill of every slot whose fill the refiller hasn't typed. */
  function recomputeRebuildFill() {
    const machine = currentMachine.value
    if (!machine) return
    const slots = currentRebuild.value
    const removed = new Map(slots.filter(s => s.action !== 'skip').map(s => [s.item.id, s.removed]))
    const plan = fillPlan(
      slots.filter(s => s.action !== 'skip').map(s => s.item),
      removed,
      rebuildPacked.value.get(machine.id) ?? new Map(),
    )
    for (const s of slots) {
      const p = plan.get(s.item.id) ?? { moved: 0, van: 0, total: 0 }
      s.moved = p.moved
      s.from_van = p.van
      if (!s.filled_touched) s.filled = p.total
    }
  }

  function setRebuildRemoved(itemId: string, value: number) {
    const slot = currentRebuild.value.find(s => s.item.id === itemId)
    if (!slot) return
    slot.removed = Math.max(0, Math.round(value || 0))
    recomputeRebuildFill()
  }

  function setRebuildFilled(itemId: string, value: number) {
    const slot = currentRebuild.value.find(s => s.item.id === itemId)
    if (!slot) return
    slot.filled = Math.max(0, Math.min(maxRebuildFilled(itemId), Math.round(value || 0)))
    slot.filled_touched = true
  }

  /**
   * Most units a slot can get: its new spiral, and only goods meant for the
   * rebuild (taken out of the machine's other changed slots or packed for it)
   * minus what the other slots of the product get. Goods of the normal
   * refill are booked with the refill; counting them here too would book
   * them twice.
   */
  function maxRebuildFilled(itemId: string): number {
    const slot = currentRebuild.value.find(s => s.item.id === itemId)
    const machine = currentMachine.value
    const productId = slot?.item.to_product_id
    if (!slot || !productId || !machine) return 0
    const active = currentRebuild.value.filter(s => s.action !== 'skip')
    const moved = active.filter(s => s.item.from_product_id === productId).reduce((sum, s) => sum + s.removed, 0)
    const packed = rebuildPacked.value.get(machine.id)?.get(productId) ?? 0
    const others = active
      .filter(s => s.item.id !== itemId && s.item.to_product_id === productId)
      .reduce((sum, s) => sum + s.filled, 0)
    return Math.max(0, Math.min(slot.item.to_capacity, moved + packed - others))
  }

  /** Slots skipped today whose old product was to move into this slot: it gets fewer units than planned. */
  function skippedSourceSlots(itemId: string): number[] {
    const slot = currentRebuild.value.find(s => s.item.id === itemId)
    const productId = slot?.item.to_product_id
    if (!slot || !productId) return []
    return currentRebuild.value
      .filter(s => s.action === 'skip' && s.item.id !== itemId && s.item.from_product_id === productId)
      .map(s => s.item.item_number)
      .sort((a, b) => a - b)
  }

  function setRebuildAction(itemId: string, action: 'done' | 'skip' | null) {
    const slot = currentRebuild.value.find(s => s.item.id === itemId)
    if (!slot) return
    // A slot whose price or age restriction changes can only be quit once
    // the setting at the machine is confirmed.
    if (action === 'done' && needsConfirmation(slot)) return
    slot.action = action
    recomputeRebuildFill()
  }

  function setRebuildPriceSet(itemId: string, value: boolean) {
    const slot = currentRebuild.value.find(s => s.item.id === itemId)
    if (!slot) return
    slot.price_set = value
    if (!value && slot.action === 'done' && changesPrice(slot.item)) {
      slot.action = null
      recomputeRebuildFill()
    }
  }

  /**
   * The change note is no longer open: nothing is rebuilt at this machine
   * (every slot "not rebuilt", nothing taken out or filled in), so its packed
   * units come back as leftovers.
   */
  function markRebuildWithdrawn(machineId: string) {
    withdrawnRebuildMachines.value = new Set([...withdrawnRebuildMachines.value, machineId])
    if (currentMachine.value?.id !== machineId) return
    for (const s of currentRebuild.value) {
      s.action = 'skip'
      s.removed = 0
      s.filled = 0
      s.filled_touched = true
    }
  }

  function setRebuildAgeSet(itemId: string, value: boolean) {
    const slot = currentRebuild.value.find(s => s.item.id === itemId)
    if (!slot) return
    slot.age_set = value
    if (!value && slot.action === 'done' && ageChanged(slot.item)) {
      slot.action = null
      recomputeRebuildFill()
    }
  }

  /** Every slot of the change note has been marked rebuilt or not rebuilt. */
  const rebuildReady = computed(() => currentRebuild.value.every(s => s.action !== null))

  /**
   * What is left over for the current machine, per product. Slots not decided
   * yet count as rebuilt (the expected case) so the panel can be read early.
   */
  const rebuildLeftovers = computed<RebuildLeftover[]>(() => {
    const machine = currentMachine.value
    if (!machine || currentRebuild.value.length === 0) return []
    const outcome = new Map<string, ItemOutcome>(currentRebuild.value.map(s => [
      s.item.id,
      { action: s.action === 'skip' ? 'skip' : 'done', removed: s.removed, filled: s.filled },
    ]))
    const left = computeLeftovers(currentRebuild.value.map(s => s.item), outcome, rebuildPacked.value.get(machine.id) ?? new Map())
    const info = new Map<string, { name: string | null; image_path: string | null }>()
    for (const s of currentRebuild.value) {
      if (s.item.from_product_id) info.set(s.item.from_product_id, { name: s.item.from_name, image_path: s.item.from_image_path })
      if (s.item.to_product_id) info.set(s.item.to_product_id, { name: s.item.to_name, image_path: s.item.to_image_path })
    }
    return [...left.entries()].map(([pid, v]) => ({
      product_id: pid,
      name: info.get(pid)?.name ?? null,
      image_path: info.get(pid)?.image_path ?? null,
      van: v.van,
      machine: v.machine,
    }))
  })

  function setLeftoverDestination(productId: string, dest: 'warehouse' | 'waste') {
    const next = new Map(leftoverDestinations.value)
    next.set(productId, dest)
    leftoverDestinations.value = next
  }

  function setLeftoverExpiry(productId: string, date: string) {
    const next = new Map(leftoverExpiry.value)
    if (date) next.set(productId, date)
    else next.delete(productId)
    leftoverExpiry.value = next
  }

  /** Leftovers of the tour per product, with what the refiller counted and chose. */
  const tourLeftoverRows = computed<TourLeftoverRow[]>(() =>
    aggregateTourLeftovers(tourLeftovers.value).map(l => {
      const counted = leftoverCounts.value.get(l.product_id)
      return {
        ...l,
        van: counted?.van ?? l.van,
        machine: counted?.machine ?? l.machine,
        destination: leftoverDestinations.value.get(l.product_id) ?? (selectedWarehouseId.value ? 'warehouse' : 'waste'),
        expiration_date: leftoverExpiry.value.get(l.product_id) ?? null,
      }
    }))

  const hasPendingLeftovers = computed(() => !leftoversReturned.value && tourLeftoverRows.value.length > 0)

  function setLeftoverCount(productId: string, kind: 'van' | 'machine', value: number) {
    const row = tourLeftoverRows.value.find(r => r.product_id === productId)
    if (!row) return
    const next = new Map(leftoverCounts.value)
    next.set(productId, { van: row.van, machine: row.machine, [kind]: Math.max(0, Math.round(value || 0)) })
    leftoverCounts.value = next
  }

  /**
   * Pre-fill the best-before date of goods taken out of machines: the date of
   * the last batch that went into one of those machines (earliest wins when
   * several machines gave back the same product).
   */
  async function loadTourExpirySuggestions() {
    const rows = tourLeftoverRows.value.filter(r => r.machine > 0 && !leftoverExpiry.value.has(r.product_id))
    const found = await Promise.all(rows.map(async (r) => {
      const dates = await Promise.all(r.machine_ids.map(mid => suggestExpiry(mid, r.product_id).catch(() => null)))
      return dates.filter((d): d is string => !!d).sort()[0] ?? null
    }))
    const next = new Map(leftoverExpiry.value)
    rows.forEach((r, i) => {
      if (found[i] && !next.has(r.product_id)) next.set(r.product_id, found[i]!)
    })
    leftoverExpiry.value = next
  }

  function leftoverPayload(): SlotChangeLeftover[] {
    return tourLeftoverRows.value
      .filter(l => l.van > 0 || l.machine > 0)
      .map(l => ({
        product_id: l.product_id,
        van_qty: l.van,
        machine_qty: l.machine,
        destination: l.destination,
        expiration_date: l.machine > 0 && l.destination === 'warehouse' ? l.expiration_date : null,
        batch_number: returnBatchLabel.value,
      }))
  }

  /** Book the tour's leftovers back (or write them off). Idempotent per tour, retried like the refill. */
  async function returnTourLeftovers(): Promise<boolean> {
    if (leftoversReturned.value) return true
    returnLeftoversError.value = null
    returningLeftovers.value = true
    try {
      const backoffMs = [1000, 3000]
      let lastError: unknown = null
      for (let attempt = 1; attempt <= 3; attempt++) {
        const { error: rpcErr } = await (supabase as any).rpc('return_slot_change_leftovers', {
          p_tour_id: tourId.value,
          p_warehouse_id: selectedWarehouseId.value,
          p_leftovers: leftoverPayload(),
        })
        if (!rpcErr) {
          leftoversReturned.value = true
          saveTourState()
          return true
        }
        lastError = rpcErr
        console.warn(`[refillWizard] return_slot_change_leftovers attempt ${attempt}/3 failed:`, rpcErr)
        if (attempt < 3) await delay(backoffMs[attempt - 1]!)
      }
      returnLeftoversError.value = (lastError as { message?: string })?.message ?? String(lastError ?? 'unknown error')
      return false
    } finally {
      returningLeftovers.value = false
    }
  }

  /** Remember what this machine left over (overwrites, so a retried quit never counts twice). */
  function recordMachineLeftovers(machineId: string) {
    const entries = rebuildLeftovers.value.map(l => ({
      machine_id: machineId,
      product_id: l.product_id,
      name: l.name,
      image_path: l.image_path,
      van: l.van,
      machine: l.machine,
    }))
    tourLeftovers.value = [...tourLeftovers.value.filter(e => e.machine_id !== machineId), ...entries]
  }

  /** Quit the rebuild of the current machine (idempotent, retried like the refill). */
  async function applyCurrentRebuild(mode: 'confirm' | 'skip'): Promise<number | null> {
    const machine = currentMachine.value
    const request = machine?.change_request
    if (!machine || !request || currentRebuild.value.length === 0) return 0
    if (mode === 'skip') {
      for (const s of currentRebuild.value) s.action = 'skip'
    }
    const items = currentRebuild.value.map(s => ({
      item_id: s.item.id,
      action: s.action === 'done' ? 'done' as const : 'skip' as const,
      removed: s.removed,
      filled: s.filled,
      price_set: s.price_set,
      age_set: s.age_set,
    }))
    const backoffMs = [1000, 3000]
    let lastError: unknown = null
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        await applySlotChange({
          requestId: request.id,
          tourId: tourId.value,
          warehouseId: selectedWarehouseId.value,
          items,
          // Leftovers ride along in the van and are booked at the end of the tour.
          leftovers: [],
        })
        recordMachineLeftovers(machine.id)
        return items.filter(i => i.action === 'done').length
      } catch (err) {
        lastError = err
        console.warn(`[refillWizard] apply_slot_change attempt ${attempt}/3 failed:`, err)
        // Withdrawn in the office while the tour was running: a retry can
        // never succeed. Nothing is switched; the packed units go back as
        // leftovers and the tour carries on.
        if (String((err as { message?: string })?.message ?? err).includes('no longer open')) {
          if (currentRebuild.value.some(s => s.action === 'done')) rebuildWithdrawnNotice.value = machine.name
          markRebuildWithdrawn(machine.id)
          recordMachineLeftovers(machine.id)
          return 0
        }
        if (attempt < 3) await delay(backoffMs[attempt - 1]!)
      }
    }
    confirmError.value = (lastError as { message?: string })?.message ?? String(lastError ?? 'unknown error')
    return null
  }

  function adjustFillAmount(trayId: string, delta: number) {
    const tray = currentTrays.value.find(t => t.id === trayId)
    if (!tray) return
    const maxFill = tray.capacity - tray.current_stock
    tray.fill_amount = Math.max(0, Math.min(maxFill, tray.fill_amount + delta))
  }

  function setFillAmount(trayId: string, amount: number) {
    const tray = currentTrays.value.find(t => t.id === trayId)
    if (!tray) return
    const maxFill = tray.capacity - tray.current_stock
    tray.fill_amount = Math.max(0, Math.min(maxFill, amount))
  }

  /** Server response row from the `refill_machine_trays` RPC. */
  interface RefillRpcRow {
    tray_id: string
    old_stock: number
    new_stock: number
    fill_amount: number
    was_already_applied: boolean
  }

  /** Sleep helper for backoff between retry attempts. */
  function delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms))
  }

  /**
   * Confirm refill for the current machine. All tray updates run in one
   * atomic RPC (`refill_machine_trays`). On network failures we retry up
   * to 3× with exponential backoff — the RPC is idempotent via
   * `(tour_id, tray_id)`, so retries cannot double-apply.
   *
   * If all 3 attempts fail the machine is **not** marked completed and
   * the wizard stays put. `confirmError` is set so the page can render
   * a banner; the user can hit Confirm again.
   */
  async function confirmMachineRefill() {
    const machine = currentMachine.value
    if (!machine) return

    confirmError.value = null
    confirmingRefill.value = true
    try {
      const traysToRefill = currentTrays.value.filter(t => t.fill_amount > 0)

      // Change note first: switches the rebuilt slots and books leftovers.
      // The normal refill below never touches those slots.
      if (currentRebuild.value.length > 0 && !rebuildReady.value) return
      const slotsRebuilt = await applyCurrentRebuild('confirm')
      if (slotsRebuilt === null) return  // error surfaced, user can retry
      const rebuilt = rebuiltSlotRows()
      const rebuildAdded = rebuilt.reduce((sum, r) => sum + r.quantity, 0)

      // Visit-only stop (no tray writes). Still record the tour stop.
      if (traysToRefill.length === 0) {
        if (rebuilt.length > 0) await writeTourActivity(machine, [], [], rebuilt)
        completedMachineIds.value = new Set([...completedMachineIds.value, machine.id])
        tourLog.value.push({
          machine_id: machine.id,
          machine_name: machine.name,
          trays_refilled: rebuilt.length,
          total_added: rebuildAdded,
          skipped: false,
          slots_rebuilt: slotsRebuilt,
        })
        await advanceToNextMachine()
        saveTourState()
        return
      }

      const trayPayload = traysToRefill.map(t => ({
        tray_id: t.id,
        fill_amount: t.fill_amount,
      }))

      const backoffMs = [1000, 3000]   // delay BEFORE attempts 2 and 3
      let results: RefillRpcRow[] | null = null
      let lastError: unknown = null

      for (let attempt = 1; attempt <= 3; attempt++) {
        const { data, error: rpcErr } = await (supabase as any).rpc('refill_machine_trays', {
          p_machine_id: machine.id,
          p_tour_id: tourId.value,
          p_trays: trayPayload,
        })

        if (!rpcErr) {
          results = (data ?? []) as RefillRpcRow[]
          break
        }

        lastError = rpcErr
        console.warn(`[refillWizard] confirmMachineRefill attempt ${attempt}/3 failed:`, rpcErr)
        if (attempt < 3) {
          await delay(backoffMs[attempt - 1]!)
        }
      }

      if (!results) {
        const msg = (lastError as { message?: string })?.message ?? String(lastError ?? 'unknown error')
        confirmError.value = msg
        return  // do NOT mark complete, do NOT advance — user can retry
      }

      // Authoritative server-side delta (handles capacity clamp + dedupe)
      const totalAdded = results.reduce(
        (sum, r) => sum + Math.max(0, r.new_stock - r.old_stock),
        0,
      )

      await writeTourActivity(machine, results, traysToRefill, rebuilt)

      completedMachineIds.value = new Set([...completedMachineIds.value, machine.id])

      tourLog.value.push({
        machine_id: machine.id,
        machine_name: machine.name,
        trays_refilled: results.length + rebuilt.length,
        total_added: totalAdded + rebuildAdded,
        skipped: false,
        slots_rebuilt: slotsRebuilt,
      })

      await advanceToNextMachine()
      saveTourState()
    } finally {
      confirmingRefill.value = false
    }
  }

  /** Slots switched at this stop that got the new product, as history rows. */
  function rebuiltSlotRows() {
    return currentRebuild.value
      .filter(s => s.action === 'done' && s.item.to_product_id && s.filled > 0)
      .map(s => ({
        tray_id: s.item.tray_id,
        item_number: s.item.item_number,
        product_id: s.item.to_product_id!,
        product_name: s.item.to_name ?? '',
        quantity: s.filled,
      }))
  }

  /**
   * The `stock_refill_tour` history entry of a stop. Rebuilt slots are listed
   * next to the refilled ones (flagged `rebuild`), so the history shows
   * everything that went into the machine. Non-critical: failures only logged.
   */
  async function writeTourActivity(
    machine: RefillMachine,
    results: RefillRpcRow[],
    traysToRefill: TrayForRefill[],
    rebuilt: ReturnType<typeof rebuiltSlotRows>,
  ) {
    const totalAdded = results.reduce((sum, r) => sum + Math.max(0, r.new_stock - r.old_stock), 0)
      + rebuilt.reduce((sum, r) => sum + r.quantity, 0)
    try {
      const { data: { session } } = await supabase.auth.getSession()
      const u = session?.user ?? null
      const fullName = [u?.user_metadata?.first_name, u?.user_metadata?.last_name]
        .filter(Boolean).join(' ').trim()
      const userDisplay = fullName || u?.email || null

      await (supabase as any).from('activity_log').insert({
        company_id: organization.value?.id,
        user_id: u?.id ?? null,
        entity_type: 'stock',
        entity_id: machine.id,
        action: 'stock_refill_tour',
        metadata: {
          tour_id: tourId.value,
          machine_id: machine.id,
          machine_name: machine.name,
          warehouse_id: selectedWarehouseId.value,
          // Scalar count + flat products stay for the native iOS decoder
          // (ActivityLogMetadata.traysRefilled: Int?, .products) — never
          // change an existing key's type; add a new one instead.
          trays_refilled: results.length + rebuilt.length,
          products: [
            ...traysToRefill.map(t => ({
              product_id: t.product_id,
              product_name: t.product_name,
              quantity: t.fill_amount,
            })),
            ...rebuilt.map(r => ({
              product_id: r.product_id,
              product_name: r.product_name,
              quantity: r.quantity,
              item_number: r.item_number,
              rebuild: true,
            })),
          ],
          // Rich per-tray old/new snapshot for the PWA /history view only.
          // A rebuilt slot starts empty after the old product came out.
          trays_detail: [
            ...buildRefillSnapshot(results, traysToRefill),
            ...rebuilt.map(r => ({
              id: r.tray_id,
              item_number: r.item_number,
              product_name: r.product_name,
              product_id: r.product_id,
              old_stock: 0,
              new_stock: r.quantity,
              rebuild: true,
            })),
          ],
          total_added: totalAdded,
          _user_email: u?.email ?? null,
          _user_display: userDisplay,
        },
      })
    } catch (logErr) {
      console.warn('[refillWizard] activity_log write failed:', logErr)
    }
  }

  // ── Note for the next tour ─────────────────────────────────────────────

  /**
   * Tick a note off while packing. It stays on every tour until ticked;
   * removed right away and put back if the server refuses.
   */
  async function completeTourNote(noteId: string): Promise<void> {
    const note = tourNotes.value.find(n => n.id === noteId)
    if (!note) return
    tourNotes.value = tourNotes.value.filter(n => n.id !== noteId)
    try {
      await tourNoteApi.completeNotes([noteId], tourId.value)
    } catch (err) {
      tourNotes.value = notesForPacking([...tourNotes.value, note], tourId.value)
      throw err
    }
  }

  /** This tour's note for the machine, '' when there is none yet. */
  async function loadTourNote(machineId: string): Promise<string> {
    if (!tourId.value) return ''
    return tourNoteApi.fetchTourNote(machineId, tourId.value)
  }

  /** Write the machine's note for the next tour; empty text deletes it. */
  async function saveTourNote(machineId: string, note: string): Promise<void> {
    if (!tourId.value) throw new Error('No tour running')
    await tourNoteApi.saveTourNote(machineId, tourId.value, note)
  }

  async function skipMachine() {
    const machine = currentMachine.value
    if (machine && currentRebuild.value.length > 0) {
      // Not rebuilt: the slots stay open for the next tour, and what was
      // packed for them goes back to its batch.
      confirmError.value = null
      confirmingRefill.value = true
      try {
        if ((await applyCurrentRebuild('skip')) === null) return
      } finally {
        confirmingRefill.value = false
      }
    }
    if (machine) {
      completedMachineIds.value = new Set([...completedMachineIds.value, machine.id])
      tourLog.value.push({
        machine_id: machine.id,
        machine_name: machine.name,
        trays_refilled: 0,
        total_added: 0,
        skipped: true,
      })

      // Log skip activity (non-blocking, non-critical)
      try {
        const { data: { session } } = await supabase.auth.getSession()
        const u = session?.user ?? null
        const fullName = [u?.user_metadata?.first_name, u?.user_metadata?.last_name]
          .filter(Boolean).join(' ').trim()
        const userDisplay = fullName || u?.email || null

        await (supabase as any).from('activity_log').insert({
          company_id: organization.value?.id,
          user_id: u?.id ?? null,
          entity_type: 'stock',
          entity_id: machine.id,
          action: 'stock_refill_tour_skip',
          metadata: {
            tour_id: tourId.value,
            machine_id: machine.id,
            machine_name: machine.name,
            _user_email: u?.email ?? null,
            _user_display: userDisplay,
          },
        })
      } catch {
        // activity log failure is non-critical
      }
    }
    await advanceToNextMachine()
    saveTourState()
  }

  /** Navigate to a specific machine by index (for tab bar switching) */
  async function goToMachine(index: number) {
    if (index < 0 || index >= machines.value.length) return
    if (index === currentMachineIndex.value) return
    currentMachineIndex.value = index
    await loadTraysForCurrentMachine()
  }

  /** Check if a machine has been completed or skipped */
  function isMachineCompleted(machineId: string): boolean {
    return completedMachineIds.value.has(machineId)
  }

  /** Check if all machines are completed */
  const allMachinesCompleted = computed(() => {
    return machines.value.every(m => completedMachineIds.value.has(m.id))
  })

  // ── Position-sorted computeds ──────────────────────────────────────────

  /** Sort helper: sort RefillItems by warehouse position, unpositioned last alphabetically */
  function sortByPosition(items: RefillItem[]): RefillItem[] {
    const order = warehouseProductOrder.value
    if (order.size === 0) return items // no positions defined — keep deficit-based order
    return [...items].sort((a, b) => {
      const posA = a.product_id ? order.get(a.product_id) : undefined
      const posB = b.product_id ? order.get(b.product_id) : undefined
      // Both positioned: sort by position
      if (posA !== undefined && posB !== undefined) return posA - posB
      // Only one positioned: positioned comes first
      if (posA !== undefined) return -1
      if (posB !== undefined) return 1
      // Neither positioned: alphabetical
      return a.product_name.localeCompare(b.product_name)
    })
  }

  /** Machines with tray_summary sorted by warehouse position */
  const sortedMachines = computed<RefillMachine[]>(() => {
    return machines.value.map(m => ({
      ...m,
      tray_summary: sortByPosition(m.tray_summary),
    }))
  })

  /** All products across all machines merged and sorted by warehouse position */
  const combinedPickList = computed<CombinedPickItem[]>(() => {
    const grouped = new Map<string, CombinedPickItem>()
    for (const machine of machines.value) {
      for (const item of machine.tray_summary) {
        if (!item.product_id) continue
        const existing = grouped.get(item.product_id)
        if (existing) {
          existing.total_deficit += item.deficit
          existing.machines.push({ id: machine.id, name: machine.name, deficit: item.deficit })
        } else {
          grouped.set(item.product_id, {
            product_id: item.product_id,
            product_name: item.product_name,
            image_path: item.image_path,
            sellprice: item.sellprice,
            total_deficit: item.deficit,
            machines: [{ id: machine.id, name: machine.name, deficit: item.deficit }],
          })
        }
      }
    }

    const items = Array.from(grouped.values())
    const order = warehouseProductOrder.value
    if (order.size === 0) {
      // No positions — sort by total deficit descending
      return items.sort((a, b) => b.total_deficit - a.total_deficit)
    }
    return items.sort((a, b) => {
      const posA = order.get(a.product_id)
      const posB = order.get(b.product_id)
      if (posA !== undefined && posB !== undefined) return posA - posB
      if (posA !== undefined) return -1
      if (posB !== undefined) return 1
      return a.product_name.localeCompare(b.product_name)
    })
  })

  /**
   * The combined packing list in warehouse order: one card per product with
   * one line per machine (machines refilling it first, then those needing it
   * only for a slot rebuild).
   */
  const combinedPackCards = computed<PackCard[]>(() => {
    const cards = new Map<string, PackCard>()
    for (const machine of machines.value) {
      for (const line of packLines(machine)) {
        const card = cards.get(line.product_id) ?? {
          product_id: line.product_id,
          product_name: line.product_name,
          image_path: line.image_path,
          sellprice: line.sellprice,
          lines: [],
        }
        card.lines.push(line)
        cards.set(line.product_id, card)
      }
    }
    for (const card of cards.values()) {
      card.lines.sort((a, b) => Number(a.refill_need === 0) - Number(b.refill_need === 0))
    }
    return sortPackRows([...cards.values()], warehouseProductOrder.value)
  })

  async function advanceToNextMachine() {
    // Find the next uncompleted machine
    let nextIndex = -1
    for (let i = 0; i < machines.value.length; i++) {
      if (!completedMachineIds.value.has(machines.value[i].id)) {
        nextIndex = i
        break
      }
    }

    if (nextIndex === -1) {
      // All machines completed
      currentStep.value = 'summary'
      return
    }
    currentMachineIndex.value = nextIndex
    await loadTraysForCurrentMachine()
  }

  // ── Summary ────────────────────────────────────────────────────────────

  const tourSummary = computed(() => {
    const totalMachines = tourLog.value.length
    const machinesRefilled = tourLog.value.filter(e => !e.skipped).length
    const machinesSkipped = tourLog.value.filter(e => e.skipped).length
    const totalTraysRefilled = tourLog.value.reduce((sum, e) => sum + e.trays_refilled, 0)
    const totalItemsAdded = tourLog.value.reduce((sum, e) => sum + e.total_added, 0)
    const totalSlotsRebuilt = tourLog.value.reduce((sum, e) => sum + (e.slots_rebuilt ?? 0), 0)
    return { totalMachines, machinesRefilled, machinesSkipped, totalTraysRefilled, totalItemsAdded, totalSlotsRebuilt }
  })

  // ── Persistence ──────────────────────────────────────────────────────────

  function saveTourState() {
    if (import.meta.server) return
    if (currentStep.value === 'packing') return // nothing to persist before tour starts

    const state: PersistedTourState = {
      currentStep: currentStep.value,
      machines: machines.value,
      currentMachineIndex: currentMachineIndex.value,
      selectedWarehouseId: selectedWarehouseId.value,
      packedQuantities: Array.from(packedQuantities.value.entries()).map(
        ([mid, pmap]) => [mid, Array.from(pmap.entries())] as [string, [string, number][]]
      ),
      completedMachineIds: Array.from(completedMachineIds.value),
      tourLog: tourLog.value,
      pickingMode: pickingMode.value,
      tourId: tourId.value,
      rebuildDecisions: Array.from(rebuildDecisions.value.entries()),
      rebuildPacked: Array.from(rebuildPacked.value.entries()).map(
        ([mid, pmap]) => [mid, Array.from(pmap.entries())] as [string, [string, number][]]
      ),
      tourLeftovers: tourLeftovers.value,
      leftoversReturned: leftoversReturned.value,
      savedAt: Date.now(),
    }
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state))
    } catch {
      // storage full or unavailable — non-critical
    }
  }

  /** Restore a previously saved tour. Returns true if successful. */
  async function resumeTour(): Promise<boolean> {
    if (import.meta.server) return false
    try {
      const raw = localStorage.getItem(STORAGE_KEY)
      if (!raw) return false
      const state = JSON.parse(raw) as PersistedTourState
      if (Date.now() - state.savedAt > MAX_AGE_MS) {
        localStorage.removeItem(STORAGE_KEY)
        return false
      }
      if (state.currentStep !== 'refill' && state.currentStep !== 'summary') return false

      // Restore state
      currentStep.value = state.currentStep
      machines.value = state.machines
      currentMachineIndex.value = state.currentMachineIndex
      selectedWarehouseId.value = state.selectedWarehouseId
      completedMachineIds.value = new Set(state.completedMachineIds)
      tourLog.value = state.tourLog
      pickingMode.value = state.pickingMode ?? 'per-machine'
      if (state.tourId) tourId.value = state.tourId
      rebuildDecisions.value = new Map(state.rebuildDecisions ?? [])
      rebuildPacked.value = new Map((state.rebuildPacked ?? []).map(([mid, entries]) => [mid, new Map(entries)]))
      tourLeftovers.value = state.tourLeftovers ?? []
      leftoversReturned.value = state.leftoversReturned ?? false

      const pq = new Map<string, Map<string, number>>()
      for (const [mid, entries] of state.packedQuantities) {
        pq.set(mid, new Map(entries))
      }
      packedQuantities.value = pq

      // Load trays for current machine if in refill step
      if (state.currentStep === 'refill' && machines.value.length > 0) {
        await loadTraysForCurrentMachine()
      }

      return true
    } catch {
      return false
    }
  }

  function resetWizard() {
    currentStep.value = 'packing'
    machines.value = []
    currentMachineIndex.value = 0
    packedItems.value = new Map()
    packedQuantities.value = new Map()
    committedQuantities.value = new Map()
    customQuantities.value = new Map()
    completedMachineIds.value = new Set()
    currentTrays.value = []
    tourLog.value = []
    tourId.value = ''
    tourNotes.value = []
    pickingMode.value = 'per-machine'
    warehouseProductOrder.value = new Map()
    rebuildDecisions.value = new Map()
    committedRebuild.value = new Map()
    rebuildPacked.value = new Map()
    rebuildCustomQuantities.value = new Map()
    currentRebuild.value = []
    leftoverDestinations.value = new Map()
    leftoverExpiry.value = new Map()
    leftoverCounts.value = new Map()
    tourLeftovers.value = []
    leftoversReturned.value = false
    returnLeftoversError.value = null
    rebuildTicks.value = new Set()
    lineTickSeq.value = new Map()
    withdrawnRebuildMachines.value = new Set()
    rebuildWithdrawnNotice.value = null
    machineTrayRows.clear()
    clearSavedTourState()
  }

  return {
    // State
    currentStep,
    machines,
    currentMachineIndex,
    selectedWarehouseId,
    warehouseStock,
    loading,
    tourStarting,
    confirmingRefill,
    packedItems,
    packedQuantities,
    currentTrays,
    currentTraysLoading,
    tourLog,
    pickingMode,

    // Computed
    currentMachine,
    machinesNeedingRefill,
    totalMachinesInTour,
    currentMachineNumber,
    tourSummary,
    allMachinesCompleted,
    completedMachineIds,
    sortedMachines,
    combinedPickList,

    // Packing
    isPacked,
    togglePacked,
    allPacked,
    getWarehouseAvailable,
    effectiveDeficit,
    isOutOfWarehouseStock,
    hasPartialStock,
    hasAnyPackedItems,
    effectiveStockHealth,
    customQuantities,
    setCustomQuantity,
    getCustomQuantity,
    getMaxCustomQuantity,
    getDisplayedPackingQty,

    // Change note (slot rebuilds)
    isItemAccepted,
    acceptedItems,
    rebuildNeeds,
    rebuildCommitted,
    packLine,
    packLines,
    toggleLine,
    setLineQuantity,
    allLinesTicked,
    packBox,
    machinesReady,
    openPackLines,
    combinedPackCards,
    maxRebuildFilled,
    skippedSourceSlots,
    withdrawnRebuildMachines,
    rebuildWithdrawnNotice,
    currentRebuild,
    rebuildReady,
    rebuildLeftovers,
    leftoverDestinations,
    leftoverExpiry,
    returnBatchLabel,
    setRebuildRemoved,
    setRebuildFilled,
    setRebuildAction,
    setRebuildPriceSet,
    setRebuildAgeSet,
    setLeftoverDestination,
    setLeftoverExpiry,
    setLeftoverCount,
    tourLeftoverRows,
    hasPendingLeftovers,
    leftoversReturned,
    returningLeftovers,
    returnLeftoversError,
    loadTourExpirySuggestions,
    returnTourLeftovers,

    // Actions
    initTour,
    loadWarehouseStock,
    startTour,
    loadTraysForCurrentMachine,
    adjustFillAmount,
    setFillAmount,
    confirmMachineRefill,
    confirmError,
    skipMachine,
    tourNotes,
    completeTourNote,
    loadTourNote,
    saveTourNote,
    goToMachine,
    isMachineCompleted,
    resetWizard,
    resumeTour,
  }
}
