<script lang="ts">
// Module-scoped: not serialized by Nuxt SSR
let _Sortable: typeof import('sortablejs').default | null = null
</script>

<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  IconPlus, IconBarcode, IconTrash,
  IconPackageImport, IconChevronDown, IconChevronRight,
  IconSearch, IconX,
  IconGripVertical,
  IconFolder, IconFolderPlus, IconChevronDown as IconChevronDownSmall, IconChevronRight as IconChevronRightSmall,
  IconEdit, IconSquareCheck, IconSquare,
  IconArrowUp, IconArrowDown, IconArrowsSort, IconArrowLeft, IconSettings,
} from '@tabler/icons-vue'
import WarehouseProductSheet from '@/components/warehouse/WarehouseProductSheet.vue'
import WarehouseOrderTab from '@/components/warehouse/WarehouseOrderTab.vue'
import WarehouseExpectedDeliveries from '@/components/warehouse/WarehouseExpectedDeliveries.vue'
import WarehouseSupplierSettings from '@/components/warehouse/WarehouseSupplierSettings.vue'
import { usePurchaseOrders, type PurchaseOrder, type ReceiveLineInput } from '@/composables/usePurchaseOrders'
import { buildOrderGroups, orderLineCount, type OrderGroup, type OrderProductInput, type OrderSettings } from '@/lib/orderSuggestion'
import {
  chipCounts, matchesChip, resolveWarehouseView,
  type StockChip, type WarehouseTab, type SetupSection,
} from '@/lib/warehouseView'
import { timeAgo, formatCurrency, formatDate } from '@/lib/utils'
import { getProductImageUrl } from '@/composables/useProducts'
import {
  expirationBadgeClass, expirationLabel,
  type Warehouse, type StockBatch, type WarehouseProductSummary,
  type WarehouseProductPosition, type WarehousePositionGroup,
} from '@/composables/useWarehouse'

const { t, locale } = useI18n()
const { organization, role } = useOrganization()
const { products, categories, fetchProducts, createProduct, uploadProductImage, toggleDiscontinued } = useProducts()
const {
  warehouses, batches, transactions, productSummaries: rawSummaries, barcodes,
  loading, transactionLoading, transactionHasMore,
  fetchWarehouses, createWarehouse, updateWarehouse, deleteWarehouse,
  fetchBarcodes, lookupBarcode, addBarcode, removeBarcode,
  fetchBatches, fetchProductSummaries, bookIncoming, adjustStock,
  fetchMinStocks, setMinStock, fetchVelocityDays, setVelocityDays, velocityDays,
  positions, groups, fetchPositions, savePositions, removePosition,
  fetchGroups, createGroup, updateGroup, deleteGroup, saveGroupOrder,
  fetchTransactions, fetchMoreTransactions,
  subscribeToStockUpdates,
  transactionTypeLabel, transactionTypeBadgeClass,
} = useWarehouse()
const ordering = usePurchaseOrders()
const {
  suppliers: orderSuppliers, settings: orderSettings, manualEntries, openOrders, productInfo,
} = ordering

const isAdmin = computed(() => role.value === 'admin')

const route = useRoute()
const router = useRouter()
const STOCK_CHIPS: StockChip[] = ['all', 'action', 'expiring', 'hidden']
const SETUP_SECTIONS: SetupSection[] = ['warehouses', 'positions', 'suppliers', 'barcodes', 'calculation']
const initialView = resolveWarehouseView(route.query.tab, route.query.section, isAdmin.value)
const activeTab = ref<WarehouseTab>(initialView.tab)
const setupSection = ref<SetupSection>(initialView.section)
const positionsVisible = computed(() => activeTab.value === 'setup' && setupSection.value === 'positions')

function syncQuery() {
  const query: Record<string, string> = { ...(route.query as Record<string, string>) }
  delete query.section
  if (activeTab.value === 'stock') delete query.tab
  else query.tab = activeTab.value
  if (activeTab.value === 'setup') query.section = setupSection.value
  router.replace({ query })
}

function setTab(tab: WarehouseTab) {
  activeTab.value = tab === 'setup' && !isAdmin.value ? 'stock' : tab
  syncQuery()
}

function setSection(section: SetupSection) {
  setupSection.value = section
  syncQuery()
}

// The role can arrive after the first render; re-resolve so an admin's
// setup link (or an old ?tab=positions) still lands in setup.
watch(isAdmin, (admin) => {
  const view = resolveWarehouseView(route.query.tab, route.query.section, admin)
  activeTab.value = view.tab
  setupSection.value = view.section
})
const selectedWarehouseId = ref<string | null>(null)

const selectedWarehouse = computed(() =>
  warehouses.value.find(w => w.id === selectedWarehouseId.value) ?? null
)

const pullRefreshHandler = async () => {
  await Promise.all([fetchWarehouses(), fetchProducts(), fetchMachineStockValue(), loadOrderingBase()])
  if (selectedWarehouseId.value) await loadWarehouseData()
}
usePullToRefresh(pullRefreshHandler)

// Disable pull-to-refresh on positions tab (conflicts with touch drag-and-drop)
if (import.meta.client) {
  const pullRefreshState = useState<(() => Promise<void> | void) | null>('pull-refresh-handler')
  watch(positionsVisible, (visible) => {
    pullRefreshState.value = visible ? null : pullRefreshHandler
  }, { immediate: true })
}

let unsubscribe: (() => void) | null = null
let unsubscribeOrdering: (() => void) | null = null

onMounted(async () => {
  // Load sortablejs client-side only
  const mod = await import('sortablejs')
  _Sortable = mod.default

  await Promise.all([fetchWarehouses(), fetchProducts(), fetchMachineStockValue(), fetchVelocityDays(), loadOrderingBase()])
  const first = warehouses.value[0]
  if (first) {
    selectedWarehouseId.value = first.id
    await loadWarehouseData()
  }
})

onUnmounted(() => {
  unsubscribe?.()
  unsubscribeOrdering?.()
})

watch(selectedWarehouseId, async (id) => {
  unsubscribe?.()
  unsubscribeOrdering?.()
  if (id) {
    await loadWarehouseData()
    unsubscribe = subscribeToStockUpdates(id)
    unsubscribeOrdering = ordering.subscribe(id, () => {})
    // A deep link (?tab=history, ?tab=setup&section=positions) opens before
    // the warehouse is known; load that view's data now.
    if (activeTab.value === 'history') loadHistory()
    if (positionsVisible.value) loadPositions()
  }
})

async function loadWarehouseData() {
  const id = selectedWarehouseId.value
  if (!id) return
  await Promise.all([
    fetchProductSummaries(id),
    fetchBatches(id),
    fetchMinStocks(id),
    ordering.fetchManualEntries(id).catch(() => {}),
    ordering.fetchOpenOrders(id).catch(() => {}),
  ])
}

// Suppliers first: the latest purchase price names its supplier.
async function loadOrderingBase() {
  try {
    await Promise.all([ordering.fetchSuppliers(), ordering.fetchSettings()])
    await ordering.fetchProductInfo()
  } catch {
    // Ordering is optional on the page; the stock tab works without it.
  }
}

/**
 * Reach counts machine stock when the company says so (Setup › Calculation),
 * the same rule the order suggestion uses.
 */
const productSummaries = computed<WarehouseProductSummary[]>(() => {
  if (!orderSettings.value.countMachineStock) return rawSummaries.value
  return rawSummaries.value.map(p => p.avg_daily_sales > 0
    ? { ...p, estimated_days_remaining: Math.round((p.total_quantity + machineStockFor(p.product_id)) / p.avg_daily_sales) }
    : p)
})

// ── KPIs ────────────────────────────────────────────────────────────────────

/**
 * One chip replaces the old discontinued / unassigned / all-out-of-stock
 * checkboxes. "all" hides discontinued products and products in no machine;
 * "hidden" lists those that still have stock (see lib/warehouseView.ts).
 */
const stockChip = ref<StockChip>('all')

const activeProductSummaries = computed(() =>
  productSummaries.value.filter(p => matchesChip(p, assignedProductIds.value.has(p.product_id), stockChip.value))
)

const chipCountsAll = computed(() => chipCounts(productSummaries.value, assignedProductIds.value))

const totalProducts = computed(() => productSummaries.value.filter(p => !p.discontinued).length)
const totalUnits = computed(() => productSummaries.value.filter(p => !p.discontinued).reduce((s, p) => s + p.total_quantity, 0))
const expiringSoonCount = computed(() => productSummaries.value.filter(p => !p.discontinued && p.expiration_status !== 'ok').length)
const belowMinCount = computed(() => productSummaries.value.filter(p => p.is_below_min).length)
const outOfStockCount = computed(() => productSummaries.value.filter(p => !p.discontinued && p.total_quantity === 0).length)
const totalValue = computed(() => {
  const productMap = new Map(products.value.map(p => [p.id, p.sellprice]))
  return productSummaries.value.reduce((sum, ps) => {
    const price = productMap.get(ps.product_id) ?? 0
    return sum + ps.total_quantity * (price ?? 0)
  }, 0)
})

// ── Machine stock value ─────────────────────────────────────────────────────
const machineTrays = ref<{ product_id: string; current_stock: number; sellprice: number }[]>([])

async function fetchMachineStockValue() {
  const supabase = useSupabaseClient()
  const { data } = await supabase
    .from('machine_trays')
    .select('product_id, current_stock, products(sellprice)')
    .not('product_id', 'is', null)
  if (data) {
    machineTrays.value = (data as any[]).map(t => ({
      product_id: t.product_id,
      current_stock: t.current_stock ?? 0,
      sellprice: t.products?.sellprice ?? 0,
    }))
  }
}

const machineStockValue = computed(() =>
  machineTrays.value.reduce((sum, t) => sum + t.current_stock * t.sellprice, 0)
)

const assignedProductIds = computed(() => new Set(machineTrays.value.map(t => t.product_id)))

const machineStockByProduct = computed(() => {
  const map = new Map<string, number>()
  for (const t of machineTrays.value) map.set(t.product_id, (map.get(t.product_id) ?? 0) + t.current_stock)
  return map
})

function machineStockFor(productId: string): number {
  return machineStockByProduct.value.get(productId) ?? 0
}

function isAssignedToMachine(productId: string): boolean {
  return assignedProductIds.value.has(productId)
}

// ── Stock tab state ─────────────────────────────────────────────────────────

const stockSearch = ref('')
const stockSortKey = ref<'name' | 'quantity' | 'min_stock' | 'range' | 'expiration' | 'status'>('name')
const stockSortDir = ref<'asc' | 'desc'>('asc')

function toggleSort(key: 'name' | 'quantity' | 'min_stock' | 'range' | 'expiration' | 'status') {
  if (stockSortKey.value === key) {
    stockSortDir.value = stockSortDir.value === 'asc' ? 'desc' : 'asc'
  } else {
    stockSortKey.value = key
    stockSortDir.value = 'asc'
  }
}

// Product detail sheet (batches, corrections, min stock, discontinued)
const detailProductId = ref<string | null>(null)
const detailSummary = computed(() =>
  productSummaries.value.find(p => p.product_id === detailProductId.value) ?? null
)

function openDetail(productId: string) {
  detailProductId.value = productId
}

async function onSaveMinStock(value: number) {
  if (!selectedWarehouseId.value || !detailProductId.value) return
  await setMinStock({ product_id: detailProductId.value, warehouse_id: selectedWarehouseId.value, min_quantity: value })
  await Promise.all([fetchProductSummaries(selectedWarehouseId.value), fetchMinStocks(selectedWarehouseId.value)])
}

async function onToggleDiscontinued(value: boolean) {
  if (!detailProductId.value) return
  await toggleDiscontinued(detailProductId.value, value)
  if (selectedWarehouseId.value) await fetchProductSummaries(selectedWarehouseId.value)
}

import { fuzzyFilter } from '@/lib/fuzzySearch'
import { moveProductPosition, productsInGroup, revertSortableMove } from '@/lib/warehousePositions'

const filteredSummaries = computed(() => {
  let items = activeProductSummaries.value
  if (stockSearch.value) {
    items = fuzzyFilter(items, stockSearch.value, [p => p.product_name])
  }
  return sortSummaries(items)
})

/**
 * Compute a numeric severity score for a product summary.
 * Lower = more urgent. Used for status column sorting.
 *
 *  0   — out of stock (active product, quantity 0)
 *  1   — below min stock
 *  2   — MHD critical (< 7 days)
 *  3   — MHD warning (7–30 days)
 *  4   — OK (everything fine)
 *  4.5 — not assigned to any machine (active but irrelevant)
 *  5   — discontinued (always last)
 */
function statusSeverity(p: WarehouseProductSummary): number {
  if (p.discontinued) return 5
  if (!p.discontinued && p.total_quantity === 0) return 0
  if (p.is_below_min) return 1
  if (p.expiration_status === 'critical') return 2
  if (p.expiration_status === 'warning') return 3
  if (!isAssignedToMachine(p.product_id)) return 4.5
  return 4
}

function sortSummaries(items: WarehouseProductSummary[]) {
  const dir = stockSortDir.value === 'asc' ? 1 : -1
  return [...items].sort((a, b) => {
    if (stockSortKey.value === 'name') {
      return dir * a.product_name.localeCompare(b.product_name)
    }
    if (stockSortKey.value === 'quantity') {
      return dir * (a.total_quantity - b.total_quantity)
    }
    if (stockSortKey.value === 'min_stock') {
      return dir * (a.min_stock - b.min_stock)
    }
    if (stockSortKey.value === 'range') {
      const aRange = a.estimated_days_remaining ?? Infinity
      const bRange = b.estimated_days_remaining ?? Infinity
      if (aRange === bRange) return 0
      return dir * (aRange - bRange)
    }
    if (stockSortKey.value === 'expiration') {
      const aDate = a.earliest_expiration ?? ''
      const bDate = b.earliest_expiration ?? ''
      if (!aDate && !bDate) return 0
      if (!aDate) return dir
      if (!bDate) return -dir
      return dir * aDate.localeCompare(bDate)
    }
    // status: composite severity (out-of-stock > low-stock > MHD critical > MHD warning > ok > discontinued)
    const aSev = statusSeverity(a)
    const bSev = statusSeverity(b)
    if (aSev !== bSev) return dir * (aSev - bSev)
    // secondary: sort by name within same severity
    return a.product_name.localeCompare(b.product_name)
  })
}


function batchesForProduct(productId: string): StockBatch[] {
  return batches.value.filter(b => b.product_id === productId)
}

// ── Order tab ───────────────────────────────────────────────────────────────

/** Quantities changed in the order tab, in cartons. Kept until ordered. */
const orderOverrides = ref<Record<string, number>>({})
const placingSupplierId = ref<string | null>(null)
const receivingOrderId = ref<string | null>(null)
const focusOrderId = ref<string | null>(null)
const notice = ref<{ kind: 'ok' | 'error'; text: string } | null>(null)
let noticeTimer: ReturnType<typeof setTimeout> | null = null

function showNotice(kind: 'ok' | 'error', text: string) {
  notice.value = { kind, text }
  if (noticeTimer) clearTimeout(noticeTimer)
  noticeTimer = setTimeout(() => { notice.value = null }, 5000)
}

const productById = computed(() => new Map(products.value.map(p => [p.id, p])))

const orderInputs = computed<OrderProductInput[]>(() => productSummaries.value.map(p => {
  const info = productInfo.value.get(p.product_id)
  return {
    product_id: p.product_id,
    product_name: p.product_name,
    image_path: p.product_image_path,
    discontinued: p.discontinued,
    warehouse_qty: p.total_quantity,
    machine_qty: machineStockFor(p.product_id),
    avg_daily_sales: p.avg_daily_sales,
    on_order: ordering.onOrderFor(p.product_id),
    unit_size: info?.order_unit_size ?? 1,
    supplier_id: ordering.supplierFor(p.product_id),
    unit_price_net: info?.latest_price_net ?? null,
  }
}))

const orderGroups = computed<OrderGroup[]>(() => buildOrderGroups({
  products: orderInputs.value,
  suppliers: orderSuppliers.value,
  manual: manualEntries.value,
  overrides: orderOverrides.value,
  settings: orderSettings.value,
}))

const orderCount = computed(() => orderLineCount(orderGroups.value))

const supplierProductCounts = computed(() => {
  const counts: Record<string, number> = {}
  for (const p of orderInputs.value) {
    if (p.supplier_id && !p.discontinued) counts[p.supplier_id] = (counts[p.supplier_id] ?? 0) + 1
  }
  return counts
})

function errorText(e: unknown): string {
  return (e as { message?: string })?.message ?? String(e)
}

function onSetCartons(productId: string, cartons: number) {
  orderOverrides.value = { ...orderOverrides.value, [productId]: Math.max(0, cartons) }
}

function onResetCartons(productId: string) {
  const next = { ...orderOverrides.value }
  delete next[productId]
  orderOverrides.value = next
}

async function onAddToOrderList(productId: string) {
  if (!selectedWarehouseId.value) return
  try {
    await ordering.addToOrderList(selectedWarehouseId.value, productId)
  } catch (e) {
    showNotice('error', errorText(e))
  }
}

async function onRemoveFromOrderList(productId: string) {
  if (!selectedWarehouseId.value) return
  try {
    await ordering.removeFromOrderList(selectedWarehouseId.value, productId)
    onResetCartons(productId)
  } catch (e) {
    showNotice('error', errorText(e))
  }
}

async function onSaveOrdering(productId: string, updates: { preferred_supplier_id?: string | null; order_unit_size?: number }) {
  try {
    await ordering.updateProductOrdering(productId, updates)
    onResetCartons(productId)
    // Reload so the order list is computed from what the server now holds.
    await ordering.fetchProductInfo()
  } catch (e) {
    showNotice('error', errorText(e))
  }
}

async function onAssignSupplier(productId: string, supplierId: string) {
  await onSaveOrdering(productId, { preferred_supplier_id: supplierId })
  const name = orderSuppliers.value.find(s => s.id === supplierId)?.name ?? ''
  const product = productById.value.get(productId)?.name ?? ''
  showNotice('ok', t('warehouse.order.assigned', { product, supplier: name }))
}

async function onPlaceOrder(group: OrderGroup) {
  if (!selectedWarehouseId.value || !group.supplier) return
  const lines = group.lines.filter(l => l.cartons > 0).map(l => ({
    product_id: l.product.product_id,
    quantity: l.units,
    unit_size: Math.max(1, l.product.unit_size),
    unit_price_net: l.product.unit_price_net,
  }))
  if (!lines.length) return
  placingSupplierId.value = group.supplier.id
  try {
    await ordering.placeOrder(selectedWarehouseId.value, group.supplier.id, lines)
    const next = { ...orderOverrides.value }
    for (const l of group.lines) delete next[l.product.product_id]
    orderOverrides.value = next
    showNotice('ok', t('warehouse.order.placed', { supplier: group.supplier.name }))
  } catch (e) {
    showNotice('error', errorText(e))
  } finally {
    placingSupplierId.value = null
  }
}

async function onCancelOrder(order: PurchaseOrder) {
  if (!window.confirm(t('warehouse.order.cancelConfirm', { supplier: order.supplier_name ?? '' }))) return
  try {
    await ordering.cancelOrder(order)
  } catch (e) {
    showNotice('error', errorText(e))
  }
}

function onCheckDelivery(order: PurchaseOrder) {
  focusOrderId.value = order.id
  setTab('incoming')
}

async function onReceiveOrder(order: PurchaseOrder, lines: ReceiveLineInput[]) {
  if (!selectedWarehouseId.value) return
  receivingOrderId.value = order.id
  try {
    const res = await ordering.receiveOrder(order, lines)
    focusOrderId.value = null
    showNotice('ok', t('warehouse.order.received', { count: res.units }))
    await Promise.all([fetchProductSummaries(selectedWarehouseId.value), fetchBatches(selectedWarehouseId.value)])
  } catch (e) {
    showNotice('error', errorText(e))
  } finally {
    receivingOrderId.value = null
  }
}

async function onCloseOrder(order: PurchaseOrder) {
  if (!window.confirm(t('warehouse.order.closeConfirm'))) return
  receivingOrderId.value = order.id
  try {
    await ordering.closeOrder(order)
    focusOrderId.value = null
  } catch (e) {
    showNotice('error', errorText(e))
  } finally {
    receivingOrderId.value = null
  }
}

async function onUpdateSupplier(id: string, updates: Record<string, string | number | null>) {
  try {
    await ordering.updateSupplier(id, updates)
  } catch (e) {
    showNotice('error', errorText(e))
  }
}

async function onCreateSupplier(name: string) {
  try {
    await ordering.createSupplier(name)
  } catch (e) {
    showNotice('error', errorText(e))
  }
}

async function onSaveOrderSettings(patch: Partial<OrderSettings>) {
  try {
    await ordering.saveSettings({ ...orderSettings.value, ...patch })
  } catch (e) {
    showNotice('error', errorText(e))
  }
}

function onOrderSettingNumber(key: 'bufferDays' | 'defaultLeadDays' | 'defaultIntervalDays', e: Event) {
  const n = parseInt((e.target as HTMLInputElement).value, 10)
  const min = key === 'defaultIntervalDays' ? 1 : 0
  if (!Number.isFinite(n) || n < min) return
  onSaveOrderSettings({ [key]: Math.min(365, n) })
}

const detailOrderLine = computed(() => {
  const id = detailProductId.value
  if (!id) return null
  for (const g of orderGroups.value) {
    const l = g.lines.find(x => x.product.product_id === id)
    if (l) return l
  }
  return null
})

// ── Positions tab state ─────────────────────────────────────────────────────

const positionsLoading = ref(false)
const positionsSaving = ref(false)
let positionSaveTimer: ReturnType<typeof setTimeout> | null = null

// Group management
const expandedGroups = ref(new Set<string>())
const editingGroupId = ref<string | null>(null)
const editingGroupName = ref('')
const showAddGroupModal = ref(false)
const addGroupForm = ref({ name: '', parent_id: null as string | null })
const deletingGroup = ref<WarehousePositionGroup | null>(null)
const showDeleteGroupConfirm = ref(false)

// Multi-select
const selectedProducts = ref(new Set<string>())
const showMoveToGroupMenu = ref(false)

// Cleanup sortables on unmount
onUnmounted(() => destroySortables())

const positionedItems = computed(() => positions.value.filter(p => p.sort_order >= 0))
const unpositionedItems = computed(() => positions.value.filter(p => p.sort_order < 0))
const rootProducts = computed(() => productsInGroup(positions.value, null))
const ungroupedPositioned = computed(() => productsInGroup(positions.value, null))

// Flat list of all groups for move-to-group dropdown
const allGroupsFlat = computed(() => {
  const result: { id: string; name: string; depth: number }[] = []
  const traverse = (nodes: WarehousePositionGroup[], depth: number) => {
    for (const n of nodes) {
      result.push({ id: n.id, name: n.name, depth })
      traverse(n.children, depth + 1)
    }
  }
  traverse(groups.value, 0)
  return result
})

function toggleGroup(groupId: string) {
  if (expandedGroups.value.has(groupId)) {
    expandedGroups.value.delete(groupId)
  } else {
    expandedGroups.value.add(groupId)
  }
}

async function loadPositions() {
  if (!selectedWarehouseId.value) return
  positionsLoading.value = true
  try {
    await fetchGroups(selectedWarehouseId.value)
    await fetchPositions(selectedWarehouseId.value)
    // Auto-expand all groups
    const expandAll = (nodes: WarehousePositionGroup[]) => {
      for (const n of nodes) {
        expandedGroups.value.add(n.id)
        expandAll(n.children)
      }
    }
    expandAll(groups.value)
  } finally {
    positionsLoading.value = false
  }
  nextTick(() => { initSortables(); initGroupSortable() })
}

function debouncedSavePositions() {
  if (positionSaveTimer) clearTimeout(positionSaveTimer)
  positionSaveTimer = setTimeout(() => doSavePositions(), 500)
}

async function doSavePositions() {
  if (!selectedWarehouseId.value) return
  positionsSaving.value = true
  try {
    const items = positionedItems.value.map((p) => ({
      product_id: p.product_id,
      sort_order: p.sort_order,
      location_label: p.location_label,
      group_id: p.group_id,
    }))
    await savePositions(selectedWarehouseId.value, items)
  } catch (e) {
    console.error('Failed to save positions', e)
  } finally {
    positionsSaving.value = false
  }
}

// ── Group CRUD ──────────────────────────────────────────────────────────

function openAddGroup(parentId: string | null = null) {
  addGroupForm.value = { name: '', parent_id: parentId }
  showAddGroupModal.value = true
}

async function submitAddGroup() {
  if (!selectedWarehouseId.value || !addGroupForm.value.name.trim()) return
  try {
    await createGroup(selectedWarehouseId.value, {
      name: addGroupForm.value.name.trim(),
      parent_id: addGroupForm.value.parent_id,
    })
    showAddGroupModal.value = false
    await loadPositions()
  } catch (e) {
    console.error('Failed to create group', e)
  }
}

function startEditGroup(group: WarehousePositionGroup) {
  editingGroupId.value = group.id
  editingGroupName.value = group.name
}

async function saveEditGroup() {
  if (!editingGroupId.value || !editingGroupName.value.trim()) return
  try {
    await updateGroup(editingGroupId.value, { name: editingGroupName.value.trim() })
    editingGroupId.value = null
    await loadPositions()
  } catch (e) {
    console.error('Failed to update group', e)
  }
}

function cancelEditGroup() {
  editingGroupId.value = null
}

async function confirmDeleteGroup() {
  if (!deletingGroup.value) return
  try {
    await deleteGroup(deletingGroup.value.id)
    showDeleteGroupConfirm.value = false
    deletingGroup.value = null
    if (selectedWarehouseId.value) await loadPositions()
  } catch (e) {
    console.error('Failed to delete group', e)
  }
}

// ── Product operations ──────────────────────────────────────────────────

function addToPositions(item: WarehouseProductPosition, groupId: string | null = null) {
  // Snapshot positioned list BEFORE mutating item (item is reactive — mutating
  // sort_order would immediately make it appear in positionedItems computed)
  const currentPositioned = positions.value.filter(p => p.sort_order >= 0 && p.product_id !== item.product_id)
  item.sort_order = currentPositioned.length + 1
  item.group_id = groupId
  positions.value = [
    ...currentPositioned,
    item,
    ...positions.value.filter(p => p.sort_order < 0 && p.product_id !== item.product_id),
  ]
  debouncedSavePositions()
}

async function removeFromPositions(item: WarehouseProductPosition) {
  if (!selectedWarehouseId.value) return
  item.sort_order = -1
  item.group_id = null
  const list = positionedItems.value.filter(p => p.product_id !== item.product_id)
  list.forEach((p, i) => { p.sort_order = i + 1 })
  positions.value = [...list, ...unpositionedItems.value, item].filter((p, i, arr) =>
    arr.findIndex(x => x.product_id === p.product_id) === i
  )
  try {
    await removePosition(selectedWarehouseId.value, item.product_id)
    await doSavePositions()
  } catch (e) {
    console.error('Failed to remove position', e)
  }
}

function updateLocationLabel(item: WarehouseProductPosition, value: string) {
  item.location_label = value || null
  debouncedSavePositions()
}

// ── Multi-select ────────────────────────────────────────────────────────

function toggleSelectProduct(productId: string) {
  if (selectedProducts.value.has(productId)) {
    selectedProducts.value.delete(productId)
  } else {
    selectedProducts.value.add(productId)
  }
  selectedProducts.value = new Set(selectedProducts.value)
}

function deselectAll() {
  selectedProducts.value = new Set()
  showMoveToGroupMenu.value = false
}

/** Rebuild group.products arrays from current positions */
function rebuildGroupProducts() {
  const groupMap = new Map<string, WarehousePositionGroup>()
  const collect = (nodes: WarehousePositionGroup[]) => {
    for (const n of nodes) {
      n.products = []
      groupMap.set(n.id, n)
      collect(n.children)
    }
  }
  collect(groups.value)
  // In sort_order, not array order: `positions` isn't re-sorted after a move.
  for (const pos of [...positionedItems.value].sort((a, b) => a.sort_order - b.sort_order)) {
    if (pos.group_id && groupMap.has(pos.group_id)) {
      groupMap.get(pos.group_id)!.products.push(pos)
    }
  }
}

async function moveSelectedToGroup(groupId: string | null) {
  // Append to the end of the target group, keeping the selection's display order.
  const selected = positionedItems.value
    .filter(p => selectedProducts.value.has(p.product_id))
    .sort((a, b) => a.sort_order - b.sort_order)
  for (const item of selected) {
    moveProductPosition(positions.value, item.product_id, groupId, Number.MAX_SAFE_INTEGER)
  }
  rebuildGroupProducts()
  deselectAll()
  showMoveToGroupMenu.value = false
  debouncedSavePositions()
}

// ── Sortable.js integration ─────────────────────────────────────────────

// Product lists and the group list are separate instances: expanding or
// collapsing a group re-creates only the product lists (their containers are
// v-if'd). Destroying everything there used to kill group dragging for good.
let productSortables: any[] = []
let groupSortables: any[] = []

function destroySortables() {
  for (const s of [...productSortables, ...groupSortables]) s.destroy()
  productSortables = []
  groupSortables = []
}

function initSortables() {
  if (import.meta.server) return
  for (const s of productSortables) s.destroy()
  productSortables = []

  nextTick(() => {
    if (!_Sortable) return
    for (const el of document.querySelectorAll('[data-sortable-group]')) {
      productSortables.push(_Sortable.create(el as HTMLElement, {
        group: 'products', // allows cross-group dragging
        handle: '.drag-handle',
        animation: 150,
        ghostClass: 'opacity-30',
        dragClass: 'shadow-lg',
        onEnd(evt) {
          const productId = evt.item.getAttribute('data-product-id')
          if (!productId || evt.newIndex === undefined) return
          if (evt.from === evt.to && evt.oldIndex === evt.newIndex) return

          const toGroupId = evt.to.getAttribute('data-sortable-group')
          const targetGroupId = !toGroupId || toGroupId === '__root__' ? null : toGroupId

          // SortableJS already moved the row in the DOM. Put it back and let
          // Vue render the move from the data — otherwise Vue patches a DOM it
          // no longer owns and the row jumps (to its old array position when
          // moved into another group).
          revertSortableMove(evt as { item: HTMLElement; from: HTMLElement; oldIndex?: number })
          moveProductPosition(positions.value, productId, targetGroupId, evt.newIndex)
          rebuildGroupProducts()
          debouncedSavePositions()
        },
      }))
    }
  })
}

// ── Sortable for groups themselves ───────────────────────────────────────

function initGroupSortable() {
  if (import.meta.server) return
  for (const s of groupSortables) s.destroy()
  groupSortables = []
  nextTick(() => {
    const container = document.querySelector('[data-sortable-groups]')
    if (!container || !_Sortable) return
    groupSortables.push(_Sortable.create(container as HTMLElement, {
      handle: '.group-drag-handle',
      animation: 150,
      ghostClass: 'opacity-30',
      onEnd(evt) {
        if (evt.oldIndex === undefined || evt.newIndex === undefined) return
        if (evt.oldIndex === evt.newIndex) return
        revertSortableMove(evt as { item: HTMLElement; from: HTMLElement; oldIndex?: number })
        const list = [...groups.value]
        const [moved] = list.splice(evt.oldIndex, 1)
        list.splice(evt.newIndex, 0, moved!)
        list.forEach((g, i) => { g.sort_order = i + 1 })
        groups.value = list
        rebuildGroupProducts()
        // Save group order
        if (selectedWarehouseId.value) {
          saveGroupOrder(selectedWarehouseId.value, list.map(g => ({
            id: g.id,
            sort_order: g.sort_order,
            parent_id: g.parent_id,
          }))).catch(e => console.error('Failed to save group order', e))
        }
      },
    }))
  })
}

// Re-init sortables when groups expand/collapse
watch(expandedGroups, () => { nextTick(() => initSortables()) }, { deep: true })

// Load positions when tab switches to positions
watch(positionsVisible, (visible) => {
  if (visible && selectedWarehouseId.value) {
    loadPositions()
  }
}, { immediate: true })

// ── Incoming tab state ──────────────────────────────────────────────────────

const incomingProductId = ref('')
const incomingQuantity = ref<number | null>(null)
const incomingQuantityRaw = ref('')

function evaluateQuantityFormula(raw: string): number | null {
  const expr = raw.replace(/\s/g, '')
  if (!expr) return null
  if (!/^[\d+\-*/.()]+$/.test(expr)) return null
  try {
    const result = Function(`"use strict"; return (${expr})`)()
    if (typeof result !== 'number' || !isFinite(result) || result <= 0) return null
    return Math.round(result)
  } catch { return null }
}

function onQuantityBlur() {
  const result = evaluateQuantityFormula(incomingQuantityRaw.value)
  incomingQuantity.value = result
  if (result !== null) {
    incomingQuantityRaw.value = String(result)
  }
}
const incomingExpiration = ref('')
const incomingBatch = ref('')
const incomingLoading = ref(false)
const incomingError = ref('')
const recentBookings = ref<{ product_id: string; product_name: string; product_image: string | null; quantity: number; expiration: string | null }[]>([])

function productImagePath(productId: string): string | null {
  return products.value.find(p => p.id === productId)?.image_path ?? null
}
const showScanner = ref(false)
const scannedBarcode = ref('')

// ── Quick-create product modal ───────────────────────────────────────────────
const { images: qcSuggestedImages, searching: qcSearchingImages, searchDebounced: qcSearchDebounced, downloadImage: qcDownloadSuggestedImage, clear: qcClearImageSearch } = useProductImageSearch()
const showQuickCreateModal = ref(false)
const quickCreateForm = ref({ name: '', sellprice: null as number | null, description: '', category: '' })
const quickCreateImageFile = ref<File | null>(null)
const quickCreateImagePreview = ref<string | null>(null)
const quickCreateSelectedImageUrl = ref<string | null>(null)
const quickCreateLoading = ref(false)
const quickCreateError = ref('')
// Tracks where the new product should go after creation
const quickCreateTarget = ref<'incoming' | 'assign'>('incoming')

// Watch quick-create product name for image suggestions
watch(() => quickCreateForm.value.name, (name) => {
  if (!quickCreateImageFile.value && !quickCreateSelectedImageUrl.value) {
    qcSearchDebounced(name)
  }
})

function selectQcSuggestedImage(thumbnail: string, imageUrl: string) {
  quickCreateImagePreview.value = thumbnail
  quickCreateSelectedImageUrl.value = imageUrl
  quickCreateImageFile.value = null
  qcClearImageSearch()
}

function openQuickCreateProduct(name: string, target: 'incoming' | 'assign') {
  quickCreateForm.value = { name: name.trim(), sellprice: null, description: '', category: '' }
  quickCreateImageFile.value = null
  quickCreateImagePreview.value = null
  quickCreateSelectedImageUrl.value = null
  qcClearImageSearch()
  quickCreateError.value = ''
  quickCreateTarget.value = target
  showQuickCreateModal.value = true
}

function onQuickCreateImageSelected(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  quickCreateImageFile.value = file
  const reader = new FileReader()
  reader.onload = (e) => { quickCreateImagePreview.value = e.target?.result as string }
  reader.readAsDataURL(file)
}

function clearQuickCreateImage() {
  quickCreateImageFile.value = null
  quickCreateImagePreview.value = null
  quickCreateSelectedImageUrl.value = null
}

async function submitQuickCreate() {
  if (!quickCreateForm.value.name.trim() || !organization.value) {
    quickCreateError.value = t('products.nameRequired')
    return
  }
  quickCreateLoading.value = true
  quickCreateError.value = ''
  try {
    const newId = await createProduct({
      name: quickCreateForm.value.name.trim(),
      sellprice: quickCreateForm.value.sellprice,
      description: quickCreateForm.value.description.trim() || null,
      category: quickCreateForm.value.category || null,
      company: organization.value.id,
    })
    // Download suggested image if selected
    if (quickCreateSelectedImageUrl.value && !quickCreateImageFile.value) {
      const file = await qcDownloadSuggestedImage(quickCreateSelectedImageUrl.value)
      if (file) quickCreateImageFile.value = file
    }
    if (quickCreateImageFile.value) {
      await uploadProductImage(newId, quickCreateImageFile.value)
    }
    // Select the new product in the appropriate context
    if (quickCreateTarget.value === 'incoming') {
      incomingProductId.value = newId
    } else {
      assignBarcodeProductId.value = newId
    }
    showQuickCreateModal.value = false
  } catch (err: any) {
    quickCreateError.value = err.message ?? t('products.failedToSave')
  } finally {
    quickCreateLoading.value = false
  }
}

// Barcode assign flow (when barcode not found)
const showAssignBarcodeFlow = ref(false)
const assignBarcodeValue = ref('')
const assignBarcodeProductId = ref('')
const assignBarcodeLoading = ref(false)
const assignBarcodeError = ref('')

// Products that don't have any barcode yet
const productsWithoutBarcode = computed(() => {
  const barcodeProductIds = new Set(barcodes.value.map(b => b.product_id))
  return products.value.filter(p => !barcodeProductIds.has(p.id))
})

async function onBarcodeDetected(barcode: string) {
  showScanner.value = false
  scannedBarcode.value = barcode
  incomingError.value = ''
  showAssignBarcodeFlow.value = false
  const result = await lookupBarcode(barcode)
  if (result) {
    incomingProductId.value = result.product_id
  } else {
    // Show assign flow
    assignBarcodeValue.value = barcode
    assignBarcodeProductId.value = ''
    assignBarcodeError.value = ''
    showAssignBarcodeFlow.value = true
  }
}

async function assignBarcodeAndSelect() {
  if (!assignBarcodeProductId.value || !assignBarcodeValue.value) {
    assignBarcodeError.value = t('warehouse.selectProductForBarcode')
    return
  }
  assignBarcodeLoading.value = true
  assignBarcodeError.value = ''
  try {
    await addBarcode({ product_id: assignBarcodeProductId.value, barcode: assignBarcodeValue.value })
    // Select the product for incoming
    incomingProductId.value = assignBarcodeProductId.value
    showAssignBarcodeFlow.value = false
  } catch (err: any) {
    assignBarcodeError.value = err.message ?? t('warehouse.failedToAssignBarcode')
  } finally {
    assignBarcodeLoading.value = false
  }
}

async function submitIncoming() {
  if (!selectedWarehouseId.value || !incomingProductId.value || !incomingQuantity.value) {
    incomingError.value = t('warehouse.selectProductAndQuantity')
    return
  }
  incomingLoading.value = true
  incomingError.value = ''
  try {
    await bookIncoming({
      warehouse_id: selectedWarehouseId.value,
      product_id: incomingProductId.value,
      quantity: incomingQuantity.value,
      expiration_date: incomingExpiration.value || null,
      batch_number: incomingBatch.value.trim() || undefined,
    })
    const product = products.value.find(p => p.id === incomingProductId.value)
    recentBookings.value.unshift({
      product_id: incomingProductId.value,
      product_name: product?.name ?? 'Unknown',
      product_image: product?.image_path ?? null,
      quantity: incomingQuantity.value,
      expiration: incomingExpiration.value || null,
    })
    // Reset form for next scan
    incomingProductId.value = ''
    incomingQuantity.value = null
    incomingQuantityRaw.value = ''
    incomingExpiration.value = ''
    incomingBatch.value = ''
    scannedBarcode.value = ''
    showAssignBarcodeFlow.value = false
    // Refresh data
    await loadWarehouseData()
  } catch (err: any) {
    incomingError.value = err.message ?? t('warehouse.failedToBookIncoming')
  } finally {
    incomingLoading.value = false
  }
}

// ── Adjustment modal state ──────────────────────────────────────────────────

const showAdjustModal = ref(false)
const adjustBatch = ref<StockBatch | null>(null)
const adjustDirection = ref<'remove' | 'add'>('remove')
const adjustQuantity = ref<number | null>(null)
const adjustReason = ref<
  'adjustment_damage' | 'adjustment_expired' | 'adjustment_correction' | 'adjustment_refill_return'
>('adjustment_damage')
const adjustNotes = ref('')
const adjustLoading = ref(false)
const adjustError = ref('')

/** Default reason per direction — must be a valid option for the active direction. */
function defaultReasonFor(direction: 'remove' | 'add') {
  return direction === 'remove' ? 'adjustment_damage' : 'adjustment_refill_return'
}

function openAdjust(batch: StockBatch) {
  adjustBatch.value = batch
  adjustDirection.value = 'remove'
  adjustQuantity.value = null
  adjustReason.value = defaultReasonFor('remove')
  adjustNotes.value = ''
  adjustError.value = ''
  showAdjustModal.value = true
}

/**
 * Called when the direction toggle flips. Always resets to the default reason
 * for the new direction, even though `adjustment_correction` is valid in both
 * — this prevents stale negative-only reasons (Damaged/Expired) leaking into
 * the Add flow. A future polish could be "only reset when current reason is
 * not valid for the new direction."
 */
function onAdjustDirectionChange() {
  adjustReason.value = defaultReasonFor(adjustDirection.value)
}

async function submitAdjust() {
  if (!adjustBatch.value || !adjustQuantity.value) {
    adjustError.value = t('warehouse.enterQuantity')
    return
  }
  adjustLoading.value = true
  adjustError.value = ''
  try {
    const magnitude = Math.abs(adjustQuantity.value)
    const signed = adjustDirection.value === 'remove' ? -magnitude : magnitude
    await adjustStock({
      batch_id: adjustBatch.value.id,
      warehouse_id: adjustBatch.value.warehouse_id,
      product_id: adjustBatch.value.product_id,
      quantity_change: signed,
      reason: adjustReason.value,
      notes: adjustNotes.value.trim() || undefined,
    })
    showAdjustModal.value = false
    await loadWarehouseData()
  } catch (err: any) {
    adjustError.value = err.message ?? t('warehouse.failedToAdjustStock')
  } finally {
    adjustLoading.value = false
  }
}

// ── History tab state ───────────────────────────────────────────────────────

const historyFilterType = ref('')
const HISTORY_TYPES = [
  { value: '', label: 'warehouse.allTypes' },
  { value: 'incoming', label: 'warehouse.incomingFilter' },
  { value: 'outgoing_refill', label: 'warehouse.refillFilter' },
  { value: 'adjustment_damage', label: 'warehouse.damagedFilter' },
  { value: 'adjustment_expired', label: 'warehouse.expiredFilter' },
  { value: 'adjustment_correction', label: 'warehouse.correctionFilter' },
  { value: 'adjustment_refill_return', label: 'warehouse.refillReturnFilter' },
]
const historyFilterProduct = ref('')
const historyLoaded = ref(false)

async function loadHistory() {
  if (!selectedWarehouseId.value) return
  historyLoaded.value = true
  await fetchTransactions(selectedWarehouseId.value, {
    type: historyFilterType.value || undefined,
    product_id: historyFilterProduct.value || undefined,
  })
}

async function loadMoreHistory() {
  if (!selectedWarehouseId.value) return
  await fetchMoreTransactions(selectedWarehouseId.value, {
    type: historyFilterType.value || undefined,
    product_id: historyFilterProduct.value || undefined,
  })
}

watch([historyFilterType, historyFilterProduct], () => {
  if (historyLoaded.value) loadHistory()
})

watch(activeTab, (tab) => {
  if (tab === 'history' && !historyLoaded.value) loadHistory()
})

// ── Warehouse settings modal state ──────────────────────────────────────────

const showWarehouseModal = ref(false)
const editingWarehouse = ref<Warehouse | null>(null)
const warehouseForm = ref({ name: '', address: '', notes: '' })
const warehouseLoading = ref(false)
const warehouseError = ref('')

function openAddWarehouse() {
  editingWarehouse.value = null
  warehouseForm.value = { name: '', address: '', notes: '' }
  warehouseError.value = ''
  showWarehouseModal.value = true
}

function openEditWarehouse(wh: Warehouse) {
  editingWarehouse.value = wh
  warehouseForm.value = { name: wh.name, address: wh.address ?? '', notes: wh.notes ?? '' }
  warehouseError.value = ''
  showWarehouseModal.value = true
}

async function submitWarehouse() {
  if (!warehouseForm.value.name.trim()) {
    warehouseError.value = t('warehouse.nameRequired')
    return
  }
  warehouseLoading.value = true
  warehouseError.value = ''
  try {
    if (editingWarehouse.value) {
      await updateWarehouse(editingWarehouse.value.id, {
        name: warehouseForm.value.name.trim(),
        address: warehouseForm.value.address.trim() || undefined,
        notes: warehouseForm.value.notes.trim() || undefined,
      })
    } else {
      const id = await createWarehouse({
        name: warehouseForm.value.name.trim(),
        address: warehouseForm.value.address.trim() || undefined,
        notes: warehouseForm.value.notes.trim() || undefined,
      })
      selectedWarehouseId.value = id
    }
    showWarehouseModal.value = false
  } catch (err: any) {
    warehouseError.value = err.message ?? t('warehouse.failedToSaveWarehouse')
  } finally {
    warehouseLoading.value = false
  }
}

const showDeleteWarehouseConfirm = ref(false)
const deletingWarehouse = ref<Warehouse | null>(null)

async function confirmDeleteWarehouse() {
  if (!deletingWarehouse.value) return
  warehouseLoading.value = true
  try {
    await deleteWarehouse(deletingWarehouse.value.id)
    if (selectedWarehouseId.value === deletingWarehouse.value.id) {
      selectedWarehouseId.value = warehouses.value[0]?.id ?? null
    }
    showDeleteWarehouseConfirm.value = false
  } catch (err: any) {
    warehouseError.value = err.message ?? t('warehouse.failedToDeleteWarehouse')
  } finally {
    warehouseLoading.value = false
  }
}

// ── Barcode modal state ─────────────────────────────────────────────────────

const showBarcodeModal = ref(false)
const barcodeForm = ref({ product_id: '', barcode: '' })
const barcodeLoading = ref(false)
const barcodeError = ref('')
const barcodeSettingsLoaded = ref(false)

async function loadBarcodeSettings() {
  if (!barcodeSettingsLoaded.value) {
    await fetchBarcodes()
    barcodeSettingsLoaded.value = true
  }
}

watch([activeTab, setupSection], ([tab, section]) => {
  if (tab === 'setup' && section === 'barcodes') loadBarcodeSettings()
}, { immediate: true })

async function submitBarcode() {
  if (!barcodeForm.value.product_id || !barcodeForm.value.barcode.trim()) {
    barcodeError.value = t('warehouse.productAndBarcodeRequired')
    return
  }
  barcodeLoading.value = true
  barcodeError.value = ''
  try {
    await addBarcode({
      product_id: barcodeForm.value.product_id,
      barcode: barcodeForm.value.barcode.trim(),
    })
    showBarcodeModal.value = false
    barcodeForm.value = { product_id: '', barcode: '' }
  } catch (err: any) {
    barcodeError.value = err.message ?? t('warehouse.failedToAddBarcode')
  } finally {
    barcodeLoading.value = false
  }
}

async function onVelocityDaysChange(e: Event) {
  const val = Number((e.target as HTMLSelectElement).value)
  setVelocityDays(val)
  if (selectedWarehouseId.value) {
    await fetchProductSummaries(selectedWarehouseId.value)
  }
}

</script>

<template>
  <div class="flex flex-col gap-4 p-4 md:p-6 overflow-x-hidden">
    <!-- Header -->
    <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      <div class="min-w-0">
        <h1 class="text-2xl font-bold">{{ activeTab === 'setup' ? t('warehouse.setupTitle') : t('warehouse.title') }}</h1>
        <!-- One warehouse is the common case: show its name, offer a picker only from two on -->
        <p v-if="selectedWarehouse && warehouses.length === 1" class="text-sm text-muted-foreground">
          {{ selectedWarehouse.name }}<template v-if="selectedWarehouse.address"> · {{ selectedWarehouse.address }}</template>
        </p>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <select
          v-if="warehouses.length > 1"
          v-model="selectedWarehouseId"
          :aria-label="t('warehouse.warehouses')"
          class="h-9 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option v-for="wh in warehouses" :key="wh.id" :value="wh.id">{{ wh.name }}</option>
        </select>
        <template v-if="warehouses.length > 0">
          <button
            v-if="activeTab === 'setup'"
            class="inline-flex h-9 items-center gap-1.5 rounded-md border px-3 text-sm font-medium hover:bg-muted"
            @click="setTab('stock')"
          >
            <IconArrowLeft class="size-4" />
            {{ t('warehouse.backToWarehouse') }}
          </button>
          <template v-else>
            <button
              v-if="isAdmin"
              class="inline-flex h-9 items-center gap-1.5 rounded-md border px-3 text-sm font-medium hover:bg-muted"
              @click="setTab('setup')"
            >
              <IconSettings class="size-4" />
              {{ t('warehouse.setup') }}
            </button>
            <button
              v-if="activeTab !== 'incoming'"
              class="inline-flex h-9 items-center gap-1.5 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90"
              @click="setTab('incoming')"
            >
              <IconPlus class="size-4" />
              {{ t('warehouse.bookStock') }}
            </button>
          </template>
        </template>
      </div>
    </div>

    <!-- Empty state -->
    <div v-if="warehouses.length === 0 && !loading" class="flex flex-col items-center gap-4 py-16 text-center">
      <div class="rounded-full bg-muted p-4">
        <IconPackageImport class="size-8 text-muted-foreground" />
      </div>
      <div>
        <h2 class="text-lg font-semibold">{{ t('warehouse.noWarehousesYet') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('warehouse.createFirstWarehouse') }}</p>
      </div>
      <button
        v-if="isAdmin"
        class="inline-flex h-9 items-center gap-1.5 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90"
        @click="openAddWarehouse"
      >
        <IconPlus class="size-4" />
        {{ t('warehouse.createWarehouse') }}
      </button>
    </div>

    <div
      v-if="notice"
      role="status"
      class="rounded-md border px-3 py-2 text-sm"
      :class="notice.kind === 'ok' ? 'border-green-300 bg-green-50 text-green-800 dark:border-green-800 dark:bg-green-950/30 dark:text-green-300' : 'border-red-300 bg-red-50 text-red-800 dark:border-red-800 dark:bg-red-950/30 dark:text-red-300'"
    >
      {{ notice.text }}
    </div>

    <!-- Product sheet, shared by the stock and the order tab -->
    <WarehouseProductSheet
      :open="detailProductId !== null"
      :summary="detailSummary"
      :batches="detailProductId ? batchesForProduct(detailProductId) : []"
      :machine-stock="detailProductId ? machineStockFor(detailProductId) : 0"
      :assigned="detailProductId ? isAssignedToMachine(detailProductId) : false"
      :is-admin="isAdmin"
      :on-order="detailProductId ? ordering.onOrderFor(detailProductId) : 0"
      :auto-order="!!detailOrderLine?.auto"
      :manual-entry="detailOrderLine?.manual ?? manualEntries.find(m => m.product_id === detailProductId) ?? null"
      :suppliers="orderSuppliers"
      :supplier-id="detailProductId ? ordering.supplierFor(detailProductId) : null"
      :unit-size="detailProductId ? (productInfo.get(detailProductId)?.order_unit_size ?? 1) : 1"
      @update:open="(v: boolean) => { if (!v) detailProductId = null }"
      @adjust="openAdjust"
      @save-min-stock="onSaveMinStock"
      @toggle-discontinued="onToggleDiscontinued"
      @add-to-order-list="detailProductId && onAddToOrderList(detailProductId)"
      @remove-from-order-list="detailProductId && onRemoveFromOrderList(detailProductId)"
      @save-ordering="(u: { preferred_supplier_id?: string | null; order_unit_size?: number }) => detailProductId && onSaveOrdering(detailProductId, u)"
    />

    <!-- Tabs -->
    <Tabs v-if="warehouses.length > 0 && activeTab !== 'setup'" :model-value="activeTab" @update:model-value="setTab($event as WarehouseTab)">
      <div class="overflow-x-auto -mx-4 px-4 scrollbar-none">
        <TabsList>
          <TabsTrigger value="stock">{{ t('warehouse.stockTab') }}</TabsTrigger>
          <TabsTrigger value="order" class="gap-1.5">
            {{ t('warehouse.order.tab') }}
            <span v-if="orderCount" class="min-w-[1.125rem] rounded-full bg-violet-100 px-1.5 text-[11px] font-semibold leading-[1.125rem] text-violet-700 dark:bg-violet-950/50 dark:text-violet-300">{{ orderCount }}</span>
          </TabsTrigger>
          <TabsTrigger value="incoming" class="gap-1.5">
            {{ t('warehouse.incoming') }}
            <span v-if="openOrders.length" class="min-w-[1.125rem] rounded-full bg-violet-100 px-1.5 text-[11px] font-semibold leading-[1.125rem] text-violet-700 dark:bg-violet-950/50 dark:text-violet-300">{{ openOrders.length }}</span>
          </TabsTrigger>
          <TabsTrigger value="history">{{ t('warehouse.historyTab') }}</TabsTrigger>
        </TabsList>
      </div>


      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <!-- STOCK TAB (was: overview + stock)                                  -->
      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <TabsContent value="stock">
        <div class="flex flex-col gap-4">
          <!-- KPI cards -->
          <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <button
              type="button"
              class="rounded-xl border bg-card p-4 text-left transition-colors hover:bg-muted/40"
              @click="stockChip = 'action'"
            >
              <div class="text-sm text-muted-foreground">{{ t('warehouse.needsAction') }}</div>
              <div class="text-2xl font-bold tabular-nums" :class="chipCountsAll.action > 0 ? 'text-red-600 dark:text-red-400' : ''">{{ chipCountsAll.action }}</div>
              <div class="text-xs text-muted-foreground">{{ t('warehouse.needsActionHint', { empty: outOfStockCount, low: belowMinCount }) }}</div>
            </button>
            <button
              type="button"
              class="rounded-xl border bg-card p-4 text-left transition-colors hover:bg-muted/40"
              @click="stockChip = 'expiring'"
            >
              <div class="text-sm text-muted-foreground">{{ t('warehouse.expiringSoon') }}</div>
              <div class="text-2xl font-bold tabular-nums" :class="expiringSoonCount > 0 ? 'text-amber-600 dark:text-amber-400' : ''">{{ expiringSoonCount }}</div>
              <div class="text-xs text-muted-foreground">{{ t('warehouse.expiringSoonHint') }}</div>
            </button>
            <div class="rounded-xl border bg-card p-4">
              <div class="text-sm text-muted-foreground">{{ t('warehouse.totalUnits') }}</div>
              <div class="text-2xl font-bold tabular-nums">{{ totalUnits }}</div>
              <div class="text-xs text-muted-foreground">{{ t('warehouse.activeProductsCount', { count: totalProducts }) }}</div>
            </div>
            <div class="rounded-xl border bg-card p-4">
              <div class="text-sm text-muted-foreground">{{ t('warehouse.totalValue') }}</div>
              <div class="text-2xl font-bold tabular-nums">{{ formatCurrency(totalValue + machineStockValue, locale) }}</div>
              <div class="text-xs text-muted-foreground">{{ t('warehouse.valueSplit', { warehouse: formatCurrency(totalValue, locale), machines: formatCurrency(machineStockValue, locale) }) }}</div>
            </div>
          </div>

          <!-- Chips + search -->
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div class="flex flex-wrap gap-1.5" role="group" :aria-label="t('warehouse.filter')">
              <button
                v-for="chip in STOCK_CHIPS"
                :key="chip"
                type="button"
                class="inline-flex h-7 items-center gap-1.5 rounded-full border px-3 text-xs font-medium transition-colors"
                :class="stockChip === chip ? 'border-primary bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'"
                :aria-pressed="stockChip === chip"
                @click="stockChip = chip"
              >
                {{ t(`warehouse.chip.${chip}`) }}
                <span class="tabular-nums opacity-70">{{ chipCountsAll[chip] }}</span>
              </button>
            </div>
            <div class="relative">
              <IconSearch class="absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <input
                v-model="stockSearch"
                type="text"
                :placeholder="t('warehouse.searchProducts')"
                class="h-9 w-full rounded-md border border-input bg-background pl-8 pr-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring sm:w-64"
              />
            </div>
          </div>

          <!-- Stock table -->
          <div class="overflow-x-auto rounded-md border">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b bg-muted/50 text-left">
                  <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleSort('name')">
                    <div class="flex items-center gap-1">
                      {{ t('warehouse.productCol') }}
                      <component :is="stockSortKey === 'name' ? (stockSortDir === 'asc' ? IconArrowUp : IconArrowDown) : IconArrowsSort" class="size-3.5 text-muted-foreground" />
                    </div>
                  </th>
                  <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground text-right" @click="toggleSort('quantity')">
                    <div class="flex items-center justify-end gap-1">
                      {{ t('warehouse.quantityCol') }}
                      <component :is="stockSortKey === 'quantity' ? (stockSortDir === 'asc' ? IconArrowUp : IconArrowDown) : IconArrowsSort" class="size-3.5 text-muted-foreground" />
                    </div>
                  </th>
                  <th class="hidden px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground text-right md:table-cell" @click="toggleSort('min_stock')">
                    <div class="flex items-center justify-end gap-1">
                      {{ t('warehouse.minStockCol') }}
                      <component :is="stockSortKey === 'min_stock' ? (stockSortDir === 'asc' ? IconArrowUp : IconArrowDown) : IconArrowsSort" class="size-3.5 text-muted-foreground" />
                    </div>
                  </th>
                  <th class="hidden px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground text-right md:table-cell" @click="toggleSort('range')">
                    <div class="flex items-center justify-end gap-1">
                      {{ t('warehouse.estimatedRange') }}
                      <component :is="stockSortKey === 'range' ? (stockSortDir === 'asc' ? IconArrowUp : IconArrowDown) : IconArrowsSort" class="size-3.5 text-muted-foreground" />
                    </div>
                  </th>
                  <th class="hidden px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground md:table-cell" @click="toggleSort('expiration')">
                    <div class="flex items-center gap-1">
                      {{ t('warehouse.earliestMhd') }}
                      <component :is="stockSortKey === 'expiration' ? (stockSortDir === 'asc' ? IconArrowUp : IconArrowDown) : IconArrowsSort" class="size-3.5 text-muted-foreground" />
                    </div>
                  </th>
                  <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleSort('status')">
                    <div class="flex items-center gap-1">
                      {{ t('warehouse.statusCol') }}
                      <component :is="stockSortKey === 'status' ? (stockSortDir === 'asc' ? IconArrowUp : IconArrowDown) : IconArrowsSort" class="size-3.5 text-muted-foreground" />
                    </div>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr v-if="loading && filteredSummaries.length === 0">
                  <td colspan="6" class="px-4 py-8 text-center text-muted-foreground">{{ t('common.loading') }}</td>
                </tr>
                <tr v-else-if="filteredSummaries.length === 0">
                  <td colspan="6" class="px-4 py-8 text-center text-muted-foreground">
                    {{ stockSearch || stockChip !== 'all' ? t('warehouse.noMatchingProducts') : t('warehouse.noStock') }}
                  </td>
                </tr>
                <tr
                  v-for="p in filteredSummaries"
                  :key="p.product_id"
                  class="cursor-pointer border-b transition-colors last:border-0 hover:bg-muted/30"
                  :class="{ 'opacity-50': p.discontinued, 'opacity-70': !p.discontinued && !isAssignedToMachine(p.product_id) }"
                  tabindex="0"
                  @click="openDetail(p.product_id)"
                  @keydown.enter="openDetail(p.product_id)"
                >
                  <td class="px-4 py-3">
                    <div class="flex items-center gap-2">
                      <img
                        v-if="p.product_image_path"
                        :src="getProductImageUrl(p.product_image_path)"
                        class="size-8 rounded object-cover"
                        alt=""
                      />
                      <div v-else class="flex size-8 items-center justify-center rounded bg-muted text-xs font-medium text-muted-foreground">
                        {{ p.product_name.charAt(0) }}
                      </div>
                      <span class="font-medium" :class="{ 'line-through': p.discontinued }">{{ p.product_name }}</span>
                    </div>
                  </td>
                  <td class="px-4 py-3 text-right font-medium tabular-nums">{{ p.total_quantity }}</td>
                  <td class="hidden px-4 py-3 text-right tabular-nums text-muted-foreground md:table-cell">{{ p.min_stock || '—' }}</td>
                  <td class="hidden px-4 py-3 text-right tabular-nums md:table-cell">
                    <span v-if="p.estimated_days_remaining !== null" :class="p.estimated_days_remaining <= 7 ? 'text-red-600 dark:text-red-400 font-medium' : p.estimated_days_remaining <= 14 ? 'text-amber-600 dark:text-amber-400' : ''">
                      {{ t('warehouse.daysRemaining', { days: p.estimated_days_remaining }) }}
                    </span>
                    <span v-else class="text-muted-foreground">{{ p.total_quantity > 0 ? t('warehouse.noSalesData') : '—' }}</span>
                  </td>
                  <td class="hidden px-4 py-3 md:table-cell">{{ formatDate(p.earliest_expiration, locale) }}</td>
                  <td class="px-4 py-3">
                    <div class="flex flex-wrap gap-1.5">
                      <span v-if="p.discontinued" class="inline-flex items-center rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-400">
                        {{ t('warehouse.discontinuedBadge') }}
                      </span>
                      <span v-else-if="!isAssignedToMachine(p.product_id)" class="inline-flex items-center rounded-full bg-blue-50 px-2 py-0.5 text-xs font-medium text-blue-600 dark:bg-blue-950/30 dark:text-blue-400">
                        {{ t('warehouse.notAssignedBadge') }}
                      </span>
                      <span v-if="p.total_quantity === 0 && !p.discontinued" class="inline-flex items-center rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700 dark:bg-red-950/40 dark:text-red-400">
                        {{ t('warehouse.outOfStock') }}
                      </span>
                      <span v-else-if="p.is_below_min" class="inline-flex items-center rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700 dark:bg-red-950/40 dark:text-red-400">
                        {{ t('warehouse.lowStock') }}
                      </span>
                      <span v-if="p.expiration_status !== 'ok' && p.total_quantity > 0" :class="[expirationBadgeClass(p.expiration_status), 'inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium']">
                        {{ expirationLabel(p.expiration_status) }}
                      </span>
                      <span
                        v-if="ordering.onOrderFor(p.product_id) > 0"
                        class="inline-flex items-center rounded-full bg-violet-100 px-2 py-0.5 text-xs font-medium text-violet-700 dark:bg-violet-950/40 dark:text-violet-300"
                      >
                        {{ t('warehouse.order.onTheWayUnits', { count: ordering.onOrderFor(p.product_id) }) }}
                      </span>
                      <span
                        v-if="p.total_quantity > 0 && p.expiration_status === 'ok' && !p.is_below_min && !p.discontinued && isAssignedToMachine(p.product_id) && ordering.onOrderFor(p.product_id) === 0"
                        class="inline-flex items-center rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700 dark:bg-green-950/40 dark:text-green-400"
                      >
                        {{ t('warehouse.ok') }}
                      </span>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="text-xs text-muted-foreground">{{ t('warehouse.stockTableHint') }}</p>
        </div>

      </TabsContent>

      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <!-- ORDER TAB                                                          -->
      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <TabsContent value="order">
        <WarehouseOrderTab
          :groups="orderGroups"
          :open-orders="openOrders"
          :suppliers="orderSuppliers"
          :settings="orderSettings"
          :is-admin="isAdmin"
          :busy-supplier-id="placingSupplierId"
          @set-cartons="onSetCartons"
          @reset-cartons="onResetCartons"
          @remove-manual="onRemoveFromOrderList"
          @add-product="onAddToOrderList"
          @assign-supplier="onAssignSupplier"
          @place="onPlaceOrder"
          @cancel-order="onCancelOrder"
          @check-delivery="onCheckDelivery"
          @open-setup="(s: SetupSection) => { setupSection = s; setTab('setup') }"
          @open-product="openDetail"
        />
      </TabsContent>


      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <!-- INCOMING TAB                                                       -->
      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <TabsContent value="incoming">
        <div class="grid gap-8" :class="openOrders.length ? 'lg:grid-cols-[minmax(0,1fr)_minmax(0,28rem)]' : ''">
        <WarehouseExpectedDeliveries
          v-if="openOrders.length"
          :orders="openOrders"
          :focus-order-id="focusOrderId"
          :busy-order-id="receivingOrderId"
          @receive="onReceiveOrder"
          @close="onCloseOrder"
        />
        <div class="flex w-full flex-col gap-4" :class="openOrders.length ? '' : 'mx-auto max-w-lg'">
          <h2 class="text-lg font-semibold">{{ openOrders.length ? t('warehouse.order.singleIntake') : t('warehouse.incomingGoods') }}</h2>

          <!-- Barcode scanner area -->
          <div class="flex flex-col gap-2">
            <BarcodeScanner
              v-if="showScanner"
              @detected="onBarcodeDetected"
              @close="showScanner = false"
            />
            <div class="flex gap-2">
              <button
                class="inline-flex h-9 flex-1 items-center justify-center gap-1.5 rounded-md border border-input bg-background text-sm font-medium hover:bg-muted"
                @click="showScanner = !showScanner"
              >
                <IconBarcode class="size-4" />
                {{ showScanner ? t('warehouse.closeScanner') : t('warehouse.scanBarcode') }}
              </button>
            </div>
            <p v-if="scannedBarcode" class="text-xs text-muted-foreground">
              {{ t('warehouse.scanned', { barcode: scannedBarcode }) }}
            </p>
          </div>

          <!-- Barcode assign flow (when barcode not found) -->
          <div v-if="showAssignBarcodeFlow" class="rounded-md border border-amber-300 bg-amber-50 p-3 dark:border-amber-700 dark:bg-amber-950/20">
            <div class="mb-2 flex items-start justify-between gap-2">
              <p class="text-sm font-medium">{{ t('warehouse.unknownBarcode', { barcode: assignBarcodeValue }) }}</p>
              <button class="shrink-0 text-muted-foreground hover:text-foreground" @click="showAssignBarcodeFlow = false">
                <IconX class="size-4" />
              </button>
            </div>
            <div class="mb-2">
              <ProductCombobox
                v-model="assignBarcodeProductId"
                :products="productsWithoutBarcode"
                :placeholder="t('warehouse.selectProduct')"
                :allow-create="isAdmin"
                @create="(query: string) => openQuickCreateProduct(query, 'assign')"
              />
            </div>
            <button
              class="h-9 w-full rounded-md border border-input bg-background text-sm font-medium hover:bg-muted disabled:opacity-50"
              :disabled="assignBarcodeLoading || !assignBarcodeProductId"
              @click="assignBarcodeAndSelect"
            >
              {{ assignBarcodeLoading ? t('warehouse.assigningBarcode') : t('warehouse.assignBarcodeAndSelect') }}
            </button>
            <FormError :message="assignBarcodeError" />
          </div>

          <!-- Product selection -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.product') }} *</label>
            <ProductCombobox
              v-model="incomingProductId"
              :products="products"
              :placeholder="t('warehouse.selectProduct')"
              :allow-create="isAdmin"
              @create="(query: string) => openQuickCreateProduct(query, 'incoming')"
            />
          </div>

          <!-- Quantity -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.quantity') }} *</label>
            <input
              v-model="incomingQuantityRaw"
              type="text"
              inputmode="numeric"
              :placeholder="t('warehouse.quantityPlaceholder')"
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              @blur="onQuantityBlur"
            />
          </div>

          <!-- Expiration date (optional) -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.expirationDate') }}</label>
            <input
              v-model="incomingExpiration"
              type="date"
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
            <p class="mt-1 text-xs text-muted-foreground">{{ t('warehouse.expirationHint') }}</p>
          </div>

          <!-- Batch number -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.batchLotNumber') }}</label>
            <input
              v-model="incomingBatch"
              type="text"
              :placeholder="t('warehouse.optional')"
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>

          <!-- Error -->
          <FormError :message="incomingError" />

          <!-- Submit -->
          <button
            class="inline-flex h-10 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
            :disabled="incomingLoading || !incomingProductId || !incomingQuantity"
            @click="submitIncoming"
          >
            {{ incomingLoading ? t('warehouse.booking') : t('warehouse.bookIncoming') }}
          </button>

          <!-- Recent bookings -->
          <div v-if="recentBookings.length > 0" class="space-y-2">
            <h3 class="text-sm font-medium text-muted-foreground">{{ t('warehouse.justBooked') }}</h3>
            <div
              v-for="(item, i) in recentBookings"
              :key="i"
              class="flex items-center justify-between rounded-md border bg-green-50 px-3 py-2 text-sm dark:bg-green-950/20"
            >
              <NuxtLink
                :to="`/products/${item.product_id}`"
                class="flex items-center gap-2 hover:underline"
              >
                <img v-if="item.product_image" :src="getProductImageUrl(item.product_image)" class="size-5 rounded object-cover" alt="" />
                <div v-else class="flex size-5 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ item.product_name.charAt(0) }}</div>
                <span>{{ item.quantity }}x {{ item.product_name }}</span>
              </NuxtLink>
              <span v-if="item.expiration" class="text-muted-foreground">{{ t('warehouse.mhd', { date: formatDate(item.expiration, locale) }) }}</span>
            </div>
          </div>
        </div>
        </div>
      </TabsContent>

      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <!-- HISTORY TAB                                                        -->
      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <TabsContent value="history">
        <div class="flex flex-col gap-4">
          <!-- Filters -->
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div class="flex flex-wrap gap-1.5" role="group" :aria-label="t('warehouse.typeCol')">
              <button
                v-for="opt in HISTORY_TYPES"
                :key="opt.value"
                type="button"
                class="inline-flex h-7 items-center rounded-full border px-3 text-xs font-medium transition-colors"
                :class="historyFilterType === opt.value ? 'border-primary bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'"
                :aria-pressed="historyFilterType === opt.value"
                @click="historyFilterType = opt.value"
              >
                {{ t(opt.label) }}
              </button>
            </div>
            <select
              v-model="historyFilterProduct"
              class="h-9 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option value="">{{ t('warehouse.allProducts') }}</option>
              <option v-for="p in products" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
          </div>

          <!-- Transaction table -->
          <div class="overflow-x-auto rounded-md border">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b bg-muted/50 text-left">
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.timeCol') }}</th>
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.typeCol') }}</th>
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.productCol') }}</th>
                  <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.batchCol') }}</th>
                  <th class="px-4 py-3 font-medium text-right">{{ t('warehouse.qtyCol') }}</th>
                  <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.userCol') }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-if="transactionLoading && transactions.length === 0">
                  <td colspan="6" class="px-4 py-8 text-center text-muted-foreground">{{ t('common.loading') }}</td>
                </tr>
                <tr v-else-if="transactions.length === 0">
                  <td colspan="6" class="px-4 py-8 text-center text-muted-foreground">{{ t('warehouse.noTransactions') }}</td>
                </tr>
                <tr
                  v-for="t in transactions"
                  :key="t.id"
                  class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                >
                  <td class="px-4 py-3 text-muted-foreground">{{ timeAgo(t.created_at) }}</td>
                  <td class="px-4 py-3">
                    <span :class="[transactionTypeBadgeClass(t.transaction_type), 'inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium']">
                      {{ transactionTypeLabel(t.transaction_type) }}
                    </span>
                  </td>
                  <td class="px-4 py-3">
                    <NuxtLink
                      v-if="t.product_id"
                      :to="`/products/${t.product_id}`"
                      class="flex items-center gap-2 hover:underline"
                    >
                      <img v-if="productImagePath(t.product_id)" :src="getProductImageUrl(productImagePath(t.product_id)!)" class="size-6 rounded object-cover" alt="" />
                      <div v-else class="flex size-6 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ (t.product_name ?? '?').charAt(0) }}</div>
                      <span class="font-medium">{{ t.product_name ?? '—' }}</span>
                    </NuxtLink>
                    <div v-else class="flex items-center gap-2">
                      <div class="flex size-6 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ (t.product_name ?? '?').charAt(0) }}</div>
                      <span class="font-medium">{{ t.product_name ?? '—' }}</span>
                    </div>
                  </td>
                  <td class="hidden px-4 py-3 md:table-cell text-muted-foreground">{{ t.batch_number ?? '—' }}</td>
                  <td class="px-4 py-3 text-right tabular-nums" :class="t.quantity_change > 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'">
                    {{ t.quantity_change > 0 ? '+' : '' }}{{ t.quantity_change }}
                  </td>
                  <td class="hidden px-4 py-3 md:table-cell text-muted-foreground">{{ (t.metadata as any)?._user_email ?? '—' }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <button
            v-if="transactionHasMore"
            class="inline-flex h-9 items-center justify-center rounded-md border px-4 text-sm font-medium hover:bg-muted disabled:opacity-50"
            :disabled="transactionLoading"
            @click="loadMoreHistory"
          >
            {{ transactionLoading ? t('common.loading') : t('warehouse.loadMore') }}
          </button>
        </div>
      </TabsContent>
    </Tabs>

    <!-- ═══════════════════════════════════════════════════════════════════ -->
    <!-- SETUP (admin): warehouses, packing order, barcodes, calculation    -->
    <!-- ═══════════════════════════════════════════════════════════════════ -->
    <div v-else-if="warehouses.length > 0 && activeTab === 'setup' && isAdmin" class="grid gap-6 md:grid-cols-[200px_minmax(0,1fr)]">
      <nav class="flex gap-1 overflow-x-auto md:flex-col" :aria-label="t('warehouse.setup')">
        <button
          v-for="s in SETUP_SECTIONS"
          :key="s"
          type="button"
          class="shrink-0 rounded-md px-3 py-2 text-left text-sm transition-colors"
          :class="setupSection === s ? 'bg-muted font-medium text-foreground' : 'text-muted-foreground hover:bg-muted/50'"
          @click="setSection(s)"
        >
          {{ t(`warehouse.setupSection.${s}`) }}
          <span class="hidden text-xs font-normal text-muted-foreground md:block">{{ t(`warehouse.setupSectionHint.${s}`) }}</span>
        </button>
      </nav>
      <div class="min-w-0">
        <div v-if="setupSection === 'warehouses'" class="flex flex-col gap-6">
          <!-- Warehouses management -->
          <div>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">{{ t('warehouse.warehouses') }}</h2>
              <button
                class="inline-flex h-8 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
                @click="openAddWarehouse"
              >
                <IconPlus class="size-3.5" />
                {{ t('common.add') }}
              </button>
            </div>
            <div class="overflow-x-auto rounded-md border">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b bg-muted/50 text-left">
                    <th class="px-4 py-3 font-medium">{{ t('common.name') }}</th>
                    <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.warehouseAddress') }}</th>
                    <th class="px-4 py-3 font-medium text-right">{{ t('common.actions') }}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="wh in warehouses"
                    :key="wh.id"
                    class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                  >
                    <td class="px-4 py-3 font-medium">{{ wh.name }}</td>
                    <td class="hidden px-4 py-3 md:table-cell text-muted-foreground">{{ wh.address ?? '—' }}</td>
                    <td class="px-4 py-3 text-right">
                      <div class="flex items-center justify-end gap-1">
                        <button class="h-7 rounded-md border px-2 text-xs hover:bg-muted" @click="openEditWarehouse(wh)">{{ t('common.edit') }}</button>
                        <button
                          class="h-7 rounded-md border border-red-200 px-2 text-xs text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/20"
                          @click="deletingWarehouse = wh; showDeleteWarehouseConfirm = true"
                        >
                          <IconTrash class="size-3.5" />
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <!-- Packing order (was: positions tab) -->
        <div v-else-if="setupSection === 'positions'">
          <div class="relative flex flex-col gap-4">
            <!-- Saving indicator -->
            <div v-if="positionsSaving" class="absolute -top-5 right-0 text-xs text-muted-foreground">
              {{ t('common.saving') }}...
            </div>

            <div class="flex items-center justify-between">
              <p class="text-sm text-muted-foreground">{{ t('warehouse.positionsDescription') }}</p>
              <button
                class="inline-flex h-8 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
                @click="openAddGroup(null)"
              >
                <IconFolderPlus class="size-3.5" />
                {{ t('warehouse.addGroup') }}
              </button>
            </div>

            <!-- Loading -->
            <div v-if="positionsLoading" class="flex items-center justify-center py-12">
              <div class="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent" />
            </div>

            <!-- Empty state -->
            <div v-else-if="positions.length === 0 && groups.length === 0" class="rounded-lg border border-dashed p-8 text-center">
              <p class="text-muted-foreground">{{ t('warehouse.positionsEmpty') }}</p>
            </div>

            <template v-else>
              <!-- ── Group tree (sortable container) ─────────────────────── -->
              <div data-sortable-groups class="flex flex-col gap-3">
                <div v-for="group in groups" :key="group.id" class="rounded-md border transition-colors">
                  <!-- Group header -->
                  <div class="flex items-center gap-2 px-3 py-2 bg-muted/30 cursor-pointer select-none" @click="toggleGroup(group.id)">
                    <IconGripVertical class="group-drag-handle size-4 text-muted-foreground/40 cursor-grab active:cursor-grabbing shrink-0 touch-none" @click.stop />
                    <IconFolder class="size-4 text-muted-foreground" />
                    <component :is="expandedGroups.has(group.id) ? IconChevronDownSmall : IconChevronRightSmall" class="size-4 text-muted-foreground" />

                    <!-- Group name (inline edit) -->
                    <template v-if="editingGroupId === group.id">
                      <input
                        v-model="editingGroupName"
                        type="text"
                        class="h-7 flex-1 rounded-md border border-input bg-background px-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                        @click.stop
                        @keyup.enter="saveEditGroup"
                        @keyup.escape="cancelEditGroup"
                      />
                      <button class="h-6 rounded px-1.5 text-xs bg-primary text-primary-foreground" @click.stop="saveEditGroup">OK</button>
                      <button class="h-6 rounded px-1.5 text-xs border hover:bg-muted" @click.stop="cancelEditGroup">{{ t('common.cancel') }}</button>
                    </template>
                    <template v-else>
                      <span class="flex-1 text-sm font-semibold">{{ group.name }}</span>
                      <span class="text-xs text-muted-foreground">{{ group.products.length }} {{ group.products.length === 1 ? 'Produkt' : 'Produkte' }}</span>
                    </template>

                    <!-- Group actions -->
                    <div v-if="editingGroupId !== group.id" class="flex items-center gap-0.5" @click.stop>
                      <button class="h-6 w-6 inline-flex items-center justify-center rounded hover:bg-muted" @click="openAddGroup(group.id)" :title="t('warehouse.addSubGroup')">
                        <IconFolderPlus class="size-3.5" />
                      </button>
                      <button class="h-6 w-6 inline-flex items-center justify-center rounded hover:bg-muted" @click="startEditGroup(group)" :title="t('warehouse.editGroup')">
                        <IconEdit class="size-3.5" />
                      </button>
                      <button
                        class="h-6 w-6 inline-flex items-center justify-center rounded hover:bg-red-50 text-red-600 dark:hover:bg-red-950/20 dark:text-red-400"
                        @click="deletingGroup = group; showDeleteGroupConfirm = true"
                        :title="t('warehouse.deleteGroup')"
                      >
                        <IconTrash class="size-3.5" />
                      </button>
                    </div>
                  </div>

                  <!-- Group content (products + subgroups) -->
                  <div v-if="expandedGroups.has(group.id)" class="border-t">
                    <!-- Subgroups (recursive - one level shown inline) -->
                    <template v-for="child in group.children" :key="child.id">
                      <div class="ml-4 border-l transition-colors">
                        <div class="flex items-center gap-2 px-3 py-1.5 bg-muted/20 cursor-pointer select-none" @click="toggleGroup(child.id)">
                          <IconFolder class="size-3.5 text-muted-foreground" />
                          <component :is="expandedGroups.has(child.id) ? IconChevronDownSmall : IconChevronRightSmall" class="size-3.5 text-muted-foreground" />
                          <template v-if="editingGroupId === child.id">
                            <input v-model="editingGroupName" type="text" class="h-6 flex-1 rounded border border-input bg-background px-2 text-xs" @click.stop @keyup.enter="saveEditGroup" @keyup.escape="cancelEditGroup" />
                            <button class="h-5 rounded px-1 text-[10px] bg-primary text-primary-foreground" @click.stop="saveEditGroup">OK</button>
                          </template>
                          <template v-else>
                            <span class="flex-1 text-xs font-semibold">{{ child.name }}</span>
                            <span class="text-[10px] text-muted-foreground">{{ child.products.length }}</span>
                          </template>
                          <div v-if="editingGroupId !== child.id" class="flex items-center gap-0.5" @click.stop>
                            <button class="h-5 w-5 inline-flex items-center justify-center rounded hover:bg-muted" @click="openAddGroup(child.id)"><IconFolderPlus class="size-3" /></button>
                            <button class="h-5 w-5 inline-flex items-center justify-center rounded hover:bg-muted" @click="startEditGroup(child)"><IconEdit class="size-3" /></button>
                            <button class="h-5 w-5 inline-flex items-center justify-center rounded hover:bg-red-50 text-red-600 dark:hover:bg-red-950/20 dark:text-red-400" @click="deletingGroup = child; showDeleteGroupConfirm = true"><IconTrash class="size-3" /></button>
                          </div>
                        </div>
                        <!-- Child products (sortable) -->
                        <div v-if="expandedGroups.has(child.id)" :data-sortable-group="child.id" class="min-h-[2rem]">
                          <div
                            v-for="item in child.products"
                            :key="item.product_id"
                            :data-product-id="item.product_id"
                            class="flex items-center gap-2 border-t px-4 py-2 ml-2 hover:bg-muted/30 transition-colors"
                          >
                            <button class="shrink-0" @click.stop="toggleSelectProduct(item.product_id)">
                              <component :is="selectedProducts.has(item.product_id) ? IconSquareCheck : IconSquare" class="size-4 text-muted-foreground" />
                            </button>
                            <IconGripVertical class="drag-handle size-3.5 text-muted-foreground/40 cursor-grab active:cursor-grabbing shrink-0 touch-none" />
                            <NuxtLink
                              :to="`/products/${item.product_id}`"
                              class="flex min-w-0 flex-1 items-center gap-2 hover:underline"
                              @click.stop
                            >
                              <img v-if="item.image_path" :src="getProductImageUrl(item.image_path)" class="size-7 shrink-0 rounded object-cover" alt="" />
                              <div v-else class="flex size-7 shrink-0 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ item.product_name.charAt(0) }}</div>
                              <span class="min-w-0 flex-1 truncate text-xs font-medium">{{ item.product_name }}</span>
                            </NuxtLink>
                            <input type="text" :value="item.location_label ?? ''" :placeholder="t('warehouse.locationPlaceholder')" class="h-6 w-24 shrink-0 rounded border border-input bg-background px-1.5 text-[10px] sm:w-28" @input="updateLocationLabel(item, ($event.target as HTMLInputElement).value)" />
                            <button class="shrink-0 h-6 w-6 inline-flex items-center justify-center rounded border border-red-200 text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/20" @click="removeFromPositions(item)"><IconX class="size-3" /></button>
                          </div>
                        </div>
                      </div>
                    </template>

                    <!-- Products directly in this group (sortable) -->
                    <div :data-sortable-group="group.id" class="min-h-[2rem]">
                      <div
                        v-for="item in group.products"
                        :key="item.product_id"
                        :data-product-id="item.product_id"
                        class="flex items-center gap-2 border-t px-3 py-2 hover:bg-muted/30 transition-colors"
                      >
                        <button class="shrink-0" @click.stop="toggleSelectProduct(item.product_id)">
                          <component :is="selectedProducts.has(item.product_id) ? IconSquareCheck : IconSquare" class="size-4 text-muted-foreground" />
                        </button>
                        <IconGripVertical class="drag-handle size-4 text-muted-foreground/40 cursor-grab active:cursor-grabbing shrink-0 touch-none" />
                        <NuxtLink
                          :to="`/products/${item.product_id}`"
                          class="flex min-w-0 flex-1 items-center gap-2 hover:underline"
                          @click.stop
                        >
                          <img v-if="item.image_path" :src="getProductImageUrl(item.image_path)" class="size-8 shrink-0 rounded object-cover" alt="" />
                          <div v-else class="flex size-8 shrink-0 items-center justify-center rounded bg-muted text-xs font-medium text-muted-foreground">{{ item.product_name.charAt(0) }}</div>
                          <span class="min-w-0 flex-1 truncate text-sm font-medium">{{ item.product_name }}</span>
                        </NuxtLink>
                        <input type="text" :value="item.location_label ?? ''" :placeholder="t('warehouse.locationPlaceholder')" class="h-7 w-28 shrink-0 rounded-md border border-input bg-background px-2 text-xs sm:w-36" @input="updateLocationLabel(item, ($event.target as HTMLInputElement).value)" />
                        <button class="shrink-0 inline-flex h-7 items-center rounded-md border border-red-200 px-2 text-xs text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/20" @click.stop="removeFromPositions(item)"><IconX class="size-3" /></button>
                      </div>
                    </div>

                    <!-- Empty group hint -->
                    <div v-if="group.products.length === 0 && group.children.length === 0" class="px-4 py-3 text-xs text-muted-foreground text-center border-t">
                      {{ t('warehouse.positionsEmpty') }}
                    </div>
                  </div>
                </div>
              </div>

              <!-- ── Root-level products (no group, sortable) ─────────────── -->
              <div
                v-if="ungroupedPositioned.length > 0 || groups.length > 0"
                class="rounded-md border transition-colors"
              >
                <div class="px-3 py-2 bg-muted/20 text-xs font-medium text-muted-foreground">{{ t('warehouse.ungrouped') }}</div>
                <div data-sortable-group="__root__" class="min-h-[2rem]">
                  <div
                    v-for="item in ungroupedPositioned"
                    :key="item.product_id"
                    :data-product-id="item.product_id"
                    class="flex items-center gap-2 border-t px-3 py-2 hover:bg-muted/30 transition-colors"
                  >
                    <button class="shrink-0" @click.stop="toggleSelectProduct(item.product_id)">
                      <component :is="selectedProducts.has(item.product_id) ? IconSquareCheck : IconSquare" class="size-4 text-muted-foreground" />
                    </button>
                    <IconGripVertical class="drag-handle size-4 text-muted-foreground/40 cursor-grab active:cursor-grabbing shrink-0 touch-none" />
                    <NuxtLink
                      :to="`/products/${item.product_id}`"
                      class="flex min-w-0 flex-1 items-center gap-2 hover:underline"
                      @click.stop
                    >
                      <img v-if="item.image_path" :src="getProductImageUrl(item.image_path)" class="size-8 shrink-0 rounded object-cover" alt="" />
                      <div v-else class="flex size-8 shrink-0 items-center justify-center rounded bg-muted text-xs font-medium text-muted-foreground">{{ item.product_name.charAt(0) }}</div>
                      <span class="min-w-0 flex-1 truncate text-sm font-medium">{{ item.product_name }}</span>
                    </NuxtLink>
                    <input type="text" :value="item.location_label ?? ''" :placeholder="t('warehouse.locationPlaceholder')" class="h-7 w-28 shrink-0 rounded-md border border-input bg-background px-2 text-xs sm:w-36" @input="updateLocationLabel(item, ($event.target as HTMLInputElement).value)" />
                    <button class="shrink-0 inline-flex h-7 items-center rounded-md border border-red-200 px-2 text-xs text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/20" @click.stop="removeFromPositions(item)"><IconX class="size-3" /></button>
                  </div>
                </div>
              </div>

              <!-- ── Unpositioned products ──────────────────────────────── -->
              <div v-if="unpositionedItems.length > 0">
                <h3 class="mb-2 text-sm font-medium text-muted-foreground">{{ t('warehouse.unpositioned') }}</h3>
                <div class="rounded-md border border-dashed">
                  <div
                    v-for="item in unpositionedItems"
                    :key="item.product_id"
                    class="flex items-center gap-3 border-b border-dashed px-3 py-2.5 last:border-0 opacity-60 hover:opacity-100 transition-opacity"
                  >
                    <NuxtLink
                      :to="`/products/${item.product_id}`"
                      class="flex min-w-0 flex-1 items-center gap-3 hover:underline"
                      @click.stop
                    >
                      <img v-if="item.image_path" :src="getProductImageUrl(item.image_path)" class="size-8 shrink-0 rounded object-cover" alt="" />
                      <div v-else class="flex size-8 shrink-0 items-center justify-center rounded bg-muted text-xs font-medium text-muted-foreground">{{ item.product_name.charAt(0) }}</div>
                      <span class="min-w-0 flex-1 truncate text-sm">{{ item.product_name }}</span>
                    </NuxtLink>
                    <button class="inline-flex h-7 shrink-0 items-center gap-1 rounded-md border px-2 text-xs hover:bg-muted" @click.stop="addToPositions(item)">
                      <IconPlus class="size-3" />
                      {{ t('warehouse.addToPositions') }}
                    </button>
                  </div>
                </div>
              </div>
            </template>

            <!-- ── Multi-select floating bar ────────────────────────────── -->
            <div
              v-if="selectedProducts.size > 0"
              class="fixed bottom-4 left-1/2 -translate-x-1/2 z-50 flex items-center gap-3 rounded-lg border bg-background px-4 py-2.5 shadow-lg"
            >
              <span class="text-sm font-medium">{{ t('warehouse.nSelected', { count: selectedProducts.size }) }}</span>
              <div class="relative">
                <button
                  class="inline-flex h-8 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
                  @click="showMoveToGroupMenu = !showMoveToGroupMenu"
                >
                  <IconFolder class="size-3.5" />
                  {{ t('warehouse.moveToGroup') }}
                </button>
                <!-- Dropdown -->
                <div v-if="showMoveToGroupMenu" class="absolute bottom-full left-0 mb-1 w-56 rounded-md border bg-popover p-1 shadow-md">
                  <button class="w-full rounded px-2 py-1.5 text-left text-sm hover:bg-muted" @click="moveSelectedToGroup(null)">
                    {{ t('warehouse.rootLevel') }}
                  </button>
                  <button
                    v-for="g in allGroupsFlat"
                    :key="g.id"
                    class="w-full rounded px-2 py-1.5 text-left text-sm hover:bg-muted"
                    :style="{ paddingLeft: `${(g.depth + 1) * 12 + 8}px` }"
                    @click="moveSelectedToGroup(g.id)"
                  >
                    {{ g.name }}
                  </button>
                </div>
              </div>
              <button class="h-8 rounded-md border px-3 text-xs hover:bg-muted" @click="deselectAll">
                {{ t('warehouse.deselectAll') }}
              </button>
            </div>
          </div>
        </div>

        <div v-else-if="setupSection === 'suppliers'" class="flex flex-col gap-6">
          <h2 class="text-lg font-semibold">{{ t('warehouse.setupSection.suppliers') }}</h2>
          <WarehouseSupplierSettings
            :suppliers="orderSuppliers"
            :product-counts="supplierProductCounts"
            :settings="orderSettings"
            @update="onUpdateSupplier"
            @create="onCreateSupplier"
          />
        </div>

        <div v-else-if="setupSection === 'barcodes'" class="flex flex-col gap-6">
          <!-- Barcode management -->
          <div>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">{{ t('warehouse.barcodesSection') }}</h2>
              <button
                class="inline-flex h-8 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
                @click="barcodeForm = { product_id: '', barcode: '' }; barcodeError = ''; showBarcodeModal = true"
              >
                <IconPlus class="size-3.5" />
                {{ t('common.add') }}
              </button>
            </div>
            <div class="overflow-x-auto rounded-md border">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b bg-muted/50 text-left">
                    <th class="px-4 py-3 font-medium">{{ t('warehouse.barcodeCol') }}</th>
                    <th class="px-4 py-3 font-medium">{{ t('warehouse.productCol') }}</th>
                    <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.formatCol') }}</th>
                    <th class="px-4 py-3 font-medium text-right">{{ t('common.actions') }}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-if="barcodes.length === 0">
                    <td colspan="4" class="px-4 py-6 text-center text-muted-foreground">{{ t('warehouse.noBarcodesYet') }}</td>
                  </tr>
                  <tr
                    v-for="b in barcodes"
                    :key="b.id"
                    class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                  >
                    <td class="px-4 py-3 font-mono text-xs">{{ b.barcode }}</td>
                    <td class="px-4 py-3">
                      <NuxtLink
                        :to="`/products/${b.product_id}`"
                        class="flex items-center gap-2 hover:underline"
                      >
                        <img v-if="productImagePath(b.product_id)" :src="getProductImageUrl(productImagePath(b.product_id)!)" class="size-6 rounded object-cover" alt="" />
                        <div v-else class="flex size-6 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ (b.product_name ?? '?').charAt(0) }}</div>
                        <span>{{ b.product_name ?? '—' }}</span>
                      </NuxtLink>
                    </td>
                    <td class="hidden px-4 py-3 md:table-cell text-muted-foreground">{{ b.format }}</td>
                    <td class="px-4 py-3 text-right">
                      <button
                        class="h-7 rounded-md border border-red-200 px-2 text-xs text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/20"
                        @click="removeBarcode(b.id)"
                      >
                        <IconTrash class="size-3.5" />
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <div v-else-if="setupSection === 'calculation'" class="flex flex-col gap-6">
          <!-- Velocity calculation period -->
          <div>
            <h2 class="mb-3 text-lg font-semibold">{{ t('warehouse.velocitySettingTitle') }}</h2>
            <p class="mb-3 text-sm text-muted-foreground">{{ t('warehouse.velocitySettingDescription') }}</p>
            <div class="flex items-center gap-3">
              <select
                :value="velocityDays"
                class="h-9 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                @change="onVelocityDaysChange"
              >
                <option :value="7">{{ t('warehouse.velocityDays7') }}</option>
                <option :value="14">{{ t('warehouse.velocityDays14') }}</option>
                <option :value="30">{{ t('warehouse.velocityDays30') }}</option>
                <option :value="60">{{ t('warehouse.velocityDays60') }}</option>
                <option :value="90">{{ t('warehouse.velocityDays90') }}</option>
              </select>
            </div>
          </div>

          <!-- Order suggestion -->
          <div class="flex flex-col gap-4">
            <div>
              <h2 class="text-lg font-semibold">{{ t('warehouse.order.calcTitle') }}</h2>
              <p class="text-sm text-muted-foreground">{{ t('warehouse.order.calcDescription') }}</p>
            </div>
            <div class="flex items-start justify-between gap-4 rounded-lg border p-4">
              <div>
                <div class="text-sm font-medium">{{ t('warehouse.order.countMachineStock') }}</div>
                <p class="text-xs text-muted-foreground">{{ t('warehouse.order.countMachineStockHint') }}</p>
              </div>
              <button
                role="switch"
                :aria-checked="orderSettings.countMachineStock"
                :aria-label="t('warehouse.order.countMachineStock')"
                class="relative mt-0.5 inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors"
                :class="orderSettings.countMachineStock ? 'bg-primary' : 'bg-input'"
                @click="onSaveOrderSettings({ countMachineStock: !orderSettings.countMachineStock })"
              >
                <span class="inline-block size-4 rounded-full bg-background shadow transition-transform" :class="orderSettings.countMachineStock ? 'translate-x-4' : 'translate-x-0.5'" />
              </button>
            </div>
            <div class="grid gap-3 sm:grid-cols-3">
              <label class="flex flex-col gap-1 text-sm">
                <span class="font-medium">{{ t('warehouse.order.bufferDays') }}</span>
                <input type="number" min="0" :value="orderSettings.bufferDays" class="h-9 rounded-md border border-input bg-background px-3 text-sm" @change="onOrderSettingNumber('bufferDays', $event)" />
                <span class="text-xs text-muted-foreground">{{ t('warehouse.order.bufferDaysHint') }}</span>
              </label>
              <label class="flex flex-col gap-1 text-sm">
                <span class="font-medium">{{ t('warehouse.order.defaultLead') }}</span>
                <input type="number" min="0" :value="orderSettings.defaultLeadDays" class="h-9 rounded-md border border-input bg-background px-3 text-sm" @change="onOrderSettingNumber('defaultLeadDays', $event)" />
              </label>
              <label class="flex flex-col gap-1 text-sm">
                <span class="font-medium">{{ t('warehouse.order.defaultInterval') }}</span>
                <input type="number" min="1" :value="orderSettings.defaultIntervalDays" class="h-9 rounded-md border border-input bg-background px-3 text-sm" @change="onOrderSettingNumber('defaultIntervalDays', $event)" />
              </label>
            </div>
            <p class="text-xs text-muted-foreground">{{ t('warehouse.order.defaultsHint') }}</p>
          </div>
        </div>
      </div>
    </div>

    <!-- ── Add group modal ──────────────────────────────────────────── -->
    <AppModal v-model:open="showAddGroupModal" :title="t('warehouse.addGroup')" size="sm">
      <form class="flex flex-col gap-3" @submit.prevent="submitAddGroup">
        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('warehouse.groupName') }} *</label>
          <input v-model="addGroupForm.name" type="text" :placeholder="t('warehouse.groupNamePlaceholder')" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" />
        </div>
        <div class="flex justify-end gap-2">
          <button type="button" class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showAddGroupModal = false">{{ t('common.cancel') }}</button>
          <button type="submit" class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90" :disabled="!addGroupForm.name.trim()">{{ t('common.save') }}</button>
        </div>
      </form>
    </AppModal>

    <!-- ── Delete group confirm modal ──────────────────────────────── -->
    <AppModal v-model:open="showDeleteGroupConfirm" :title="t('warehouse.deleteGroup')" size="sm">
      <p class="text-sm text-muted-foreground">{{ t('warehouse.deleteGroupConfirm', { name: deletingGroup?.name ?? '' }) }}</p>
      <div class="flex justify-end gap-2 pt-2">
        <button class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showDeleteGroupConfirm = false">{{ t('common.cancel') }}</button>
        <button class="h-9 rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700" @click="confirmDeleteGroup">{{ t('common.delete') }}</button>
      </div>
    </AppModal>

    <!-- ═══════════════════════════════════════════════════════════════════── -->
    <!-- MODALS                                                               -->
    <!-- ═══════════════════════════════════════════════════════════════════── -->

    <!-- Warehouse add/edit modal -->
    <AppModal v-model:open="showWarehouseModal" :title="editingWarehouse ? t('warehouse.editWarehouseModal') : t('warehouse.addWarehouseModal')">
      <form class="flex flex-col gap-3" @submit.prevent="submitWarehouse">
        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('common.name') }} *</label>
          <input v-model="warehouseForm.name" type="text" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" />
        </div>
        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('warehouse.warehouseAddress') }}</label>
          <input v-model="warehouseForm.address" type="text" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" />
        </div>
        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('common.notes') }}</label>
          <textarea v-model="warehouseForm.notes" rows="2" class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"></textarea>
        </div>
        <FormError :message="warehouseError" />
        <div class="flex justify-end gap-2">
          <button type="button" class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showWarehouseModal = false">{{ t('common.cancel') }}</button>
          <button type="submit" class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50" :disabled="warehouseLoading">
            {{ warehouseLoading ? t('common.saving') : t('common.save') }}
          </button>
        </div>
      </form>
    </AppModal>

    <!-- Delete warehouse confirm modal -->
    <AppModal v-model:open="showDeleteWarehouseConfirm" :title="t('warehouse.deleteWarehouseTitle')" size="sm">
      <p class="text-sm text-muted-foreground">
        {{ t('warehouse.deleteWarehouseConfirm', { name: deletingWarehouse?.name ?? '' }) }}
      </p>
      <div class="flex justify-end gap-2 pt-2">
        <button class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showDeleteWarehouseConfirm = false">{{ t('common.cancel') }}</button>
        <button
          class="h-9 rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
          :disabled="warehouseLoading"
          @click="confirmDeleteWarehouse"
        >
          {{ t('common.delete') }}
        </button>
      </div>
    </AppModal>

    <!-- Adjustment modal -->
    <AppModal v-model:open="showAdjustModal" :title="t('warehouse.adjustStockTitle')">
      <p class="mb-3 text-sm text-muted-foreground">
        {{ t('warehouse.adjustBatchInfo', { product: adjustBatch?.product_name ?? '', batch: adjustBatch?.batch_number || t('warehouse.noBatchId'), quantity: adjustBatch?.quantity ?? 0 }) }}
      </p>
      <form class="flex flex-col gap-3" @submit.prevent="submitAdjust">
        <!-- Direction toggle -->
        <div class="inline-flex rounded-md border bg-muted/40 p-0.5">
          <button
            type="button"
            class="flex-1 rounded px-3 py-1.5 text-sm font-medium transition-colors"
            :class="adjustDirection === 'remove' ? 'bg-red-600 text-white shadow-sm' : 'text-muted-foreground hover:text-foreground'"
            @click="adjustDirection = 'remove'; onAdjustDirectionChange()"
          >
            − {{ t('warehouse.adjustDirectionRemove') }}
          </button>
          <button
            type="button"
            class="flex-1 rounded px-3 py-1.5 text-sm font-medium transition-colors"
            :class="adjustDirection === 'add' ? 'bg-green-600 text-white shadow-sm' : 'text-muted-foreground hover:text-foreground'"
            @click="adjustDirection = 'add'; onAdjustDirectionChange()"
          >
            + {{ t('warehouse.adjustDirectionAdd') }}
          </button>
        </div>

        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('warehouse.reason') }} *</label>
          <select v-model="adjustReason" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring">
            <template v-if="adjustDirection === 'remove'">
              <option value="adjustment_damage">{{ t('warehouse.damaged') }}</option>
              <option value="adjustment_expired">{{ t('warehouse.expiredDisposed') }}</option>
              <option value="adjustment_correction">{{ t('warehouse.inventoryCorrection') }}</option>
            </template>
            <template v-else>
              <option value="adjustment_refill_return">{{ t('warehouse.refillReturn') }}</option>
              <option value="adjustment_correction">{{ t('warehouse.inventoryCorrection') }}</option>
            </template>
          </select>
          <p v-if="adjustDirection === 'add' && adjustReason === 'adjustment_refill_return'" class="mt-1 text-xs text-muted-foreground">
            {{ t('warehouse.refillReturnDescription') }}
          </p>
        </div>

        <div>
          <label class="mb-1 block text-sm font-medium">
            {{ adjustDirection === 'remove' ? t('warehouse.quantityToRemove') : t('warehouse.quantityToAdd') }} *
          </label>
          <input
            v-model.number="adjustQuantity"
            type="number"
            min="1"
            :max="adjustDirection === 'remove' ? (adjustBatch?.quantity ?? undefined) : undefined"
            class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>

        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('common.notes') }}</label>
          <textarea v-model="adjustNotes" rows="2" class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" :placeholder="t('warehouse.optionalDetails')"></textarea>
        </div>

        <FormError :message="adjustError" />

        <div class="flex justify-end gap-2">
          <button type="button" class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showAdjustModal = false">{{ t('common.cancel') }}</button>
          <button
            type="submit"
            class="h-9 rounded-md px-4 text-sm font-medium text-white disabled:opacity-50"
            :class="adjustDirection === 'remove' ? 'bg-red-600 hover:bg-red-700' : 'bg-green-600 hover:bg-green-700'"
            :disabled="adjustLoading"
          >
            {{ adjustLoading
                ? t('warehouse.adjusting')
                : (adjustDirection === 'remove' ? t('warehouse.removeStock') : t('warehouse.addStockSubmit')) }}
          </button>
        </div>
      </form>
    </AppModal>

    <!-- Barcode add modal -->
    <AppModal v-model:open="showBarcodeModal" :title="t('warehouse.addBarcodeTitle')">
      <form class="flex flex-col gap-3" @submit.prevent="submitBarcode">
        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('warehouse.product') }} *</label>
          <ProductCombobox
            :model-value="barcodeForm.product_id || null"
            :products="products"
            :placeholder="t('warehouse.selectProduct')"
            @update:model-value="barcodeForm.product_id = $event ?? ''"
          />
        </div>
        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('warehouse.barcodeEan') }} *</label>
          <input v-model="barcodeForm.barcode" type="text" :placeholder="t('warehouse.barcodeEanPlaceholder')" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm font-mono focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" />
        </div>
        <FormError :message="barcodeError" />
        <div class="flex justify-end gap-2">
          <button type="button" class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showBarcodeModal = false">{{ t('common.cancel') }}</button>
          <button type="submit" class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50" :disabled="barcodeLoading">
            {{ barcodeLoading ? t('common.saving') : t('common.save') }}
          </button>
        </div>
      </form>
    </AppModal>

    <!-- Quick-create product modal -->
    <AppModal v-model:open="showQuickCreateModal" :title="t('products.addProduct')" size="sm">
      <form class="space-y-4" @submit.prevent="submitQuickCreate">
        <div class="space-y-1">
          <label class="text-sm font-medium" for="qc-product-name">{{ t('common.name') }} *</label>
          <input
            id="qc-product-name"
            v-model="quickCreateForm.name"
            type="text"
            required
            :placeholder="t('products.productName')"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>

        <!-- Image upload -->
        <div class="space-y-1">
          <label class="text-sm font-medium">{{ t('products.image') }}</label>
          <div v-if="quickCreateImagePreview" class="relative inline-block">
            <img :src="quickCreateImagePreview" :alt="t('common.preview')" class="h-24 w-24 rounded-lg object-cover border" />
            <button
              type="button"
              class="absolute -right-2 -top-2 flex h-5 w-5 items-center justify-center rounded-full bg-destructive text-destructive-foreground text-xs shadow"
              @click="clearQuickCreateImage"
            >
              &times;
            </button>
          </div>
          <div v-else>
            <label
              for="qc-product-image"
              class="flex h-24 w-full cursor-pointer items-center justify-center rounded-lg border-2 border-dashed border-muted-foreground/25 text-sm text-muted-foreground transition-colors hover:border-muted-foreground/50 hover:bg-muted/30"
            >
              <div class="text-center">
                <svg xmlns="http://www.w3.org/2000/svg" class="mx-auto mb-1 h-6 w-6" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" x2="12" y1="3" y2="15"/></svg>
                <span>{{ t('products.clickToUpload') }}</span>
              </div>
            </label>
            <input
              id="qc-product-image"
              type="file"
              accept="image/png,image/jpeg,image/webp"
              class="hidden"
              @change="onQuickCreateImageSelected"
            />
            <!-- Image suggestions -->
            <div v-if="!quickCreateImagePreview && (qcSearchingImages || qcSuggestedImages.length > 0)" class="mt-2">
              <p class="mb-1.5 text-xs text-muted-foreground">{{ qcSearchingImages ? t('products.searchingImages') : t('products.imageSuggestions') }}</p>
              <div v-if="qcSearchingImages" class="flex items-center gap-2 text-xs text-muted-foreground">
                <svg class="size-4 animate-spin" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/></svg>
              </div>
              <div v-else class="grid grid-cols-4 gap-1.5">
                <button
                  v-for="img in qcSuggestedImages"
                  :key="img.image"
                  type="button"
                  class="group relative aspect-square overflow-hidden rounded-md border hover:ring-2 hover:ring-primary"
                  :title="img.title"
                  @click="selectQcSuggestedImage(img.thumbnail, img.image)"
                >
                  <img :src="img.thumbnail" :alt="img.title" class="h-full w-full object-cover" loading="lazy" />
                </button>
              </div>
            </div>
          </div>
        </div>

        <div class="space-y-1">
          <label class="text-sm font-medium" for="qc-product-price">{{ t('products.price') }}</label>
          <input
            id="qc-product-price"
            v-model.number="quickCreateForm.sellprice"
            type="number"
            step="0.01"
            min="0"
            :placeholder="t('products.pricePlaceholder')"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <div class="space-y-1">
          <label class="text-sm font-medium" for="qc-product-category">{{ t('products.category') }}</label>
          <select
            id="qc-product-category"
            v-model="quickCreateForm.category"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option value="">—</option>
            <option v-for="cat in categories" :key="cat.id" :value="cat.id">{{ cat.name }}</option>
          </select>
        </div>
        <div class="space-y-1">
          <label class="text-sm font-medium" for="qc-product-description">{{ t('common.description') }}</label>
          <textarea
            id="qc-product-description"
            v-model="quickCreateForm.description"
            rows="2"
            :placeholder="t('products.optionalDescription')"
            class="flex w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>

        <FormError :message="quickCreateError" />
        <div class="flex gap-2">
          <button
            type="button"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm hover:bg-muted"
            @click="showQuickCreateModal = false"
          >
            {{ t('common.cancel') }}
          </button>
          <button
            type="submit"
            :disabled="quickCreateLoading"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
          >
            <span v-if="quickCreateLoading">{{ t('common.saving') }}</span>
            <span v-else>{{ t('common.create') }}</span>
          </button>
        </div>
      </form>
    </AppModal>
  </div>
</template>
