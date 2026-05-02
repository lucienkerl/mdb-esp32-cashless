<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import { VisAxis, VisStackedBar, VisXYContainer } from '@unovis/vue'
import { IconCreditCard, IconCoins, IconSend, IconSparkles, IconLoader2, IconRefresh, IconTrash, IconPlus, IconHistory, IconArrowUp, IconArrowDown, IconExternalLink } from '@tabler/icons-vue'
import { NuxtLink } from '#components'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Badge } from '@/components/ui/badge'
import { useInsights, sortedRecommendations, priorityVariant, recommendationTypeLabel } from '@/composables/useInsights'
import { useDeviceRestarts, reasonLabel, reasonVariant, formatUptime } from '@/composables/useDeviceRestarts'
import { timeAgo, formatCurrency, formatDate, formatTime, formatDateTime } from '@/lib/utils'
import MachineSettingsModal from '~/components/MachineSettingsModal.vue'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '~/components/ui/dropdown-menu'

const { t, locale } = useI18n()
const route = useRoute()
const defaultTab = computed(() => {
  const tab = route.query.tab as string
  if (tab === 'stock') return 'trays'
  if (tab === 'mdb') return 'mdb'
  if (tab === 'health') return 'health'
  return 'sales'
})
const supabase = useSupabaseClient()
const { role } = useOrganization()
const { products, categories, fetchProducts } = useProducts()

const { trays, loading: traysLoading, fetchTrays, upsertTray, updateTray, batchCreateTrays, refillToFull, refillAll, adjustStock: adjustStockDebounced, deleteTray, subscribeToTrayUpdates } = useMachineTrays()
const { fetchUnassignedEmbeddeds, swapDevice } = useMachines()
const { logs: mdbLogs, loading: mdbLogsLoading, hasMore: mdbHasMore, fetchLogs: fetchMdbLogs, fetchMore: fetchMoreMdbLogs, subscribe: subscribeMdbLog, stateLabel, stateVariant } = useMdbLog()
const { entries: stockHistoryEntries, loading: stockHistoryLoading, fetchHistory: fetchStockHistory, reset: resetStockHistory } = useStockHistory()
const { restarts, loading: restartsLoading, hasMore: restartsHasMore, fetchRestarts, fetchMore: fetchMoreRestarts, subscribe: subscribeRestarts } = useDeviceRestarts()
const { onResume } = useAppResume()

const isAdmin = computed(() => role.value === 'admin')

// ── SoftAP credentials modal ────────────────────────────────────────────
const softapModalOpen = ref(false)
function openSoftapModal() {
  softapModalOpen.value = true
}
function closeSoftapModal() {
  softapModalOpen.value = false
}

import { fuzzyFilter } from '@/lib/fuzzySearch'

const traySearch = ref('')
const { toggleSort: toggleTraySort, sortIcon: traySortIcon, sortKey: traySortKey, sortDir: traySortDir } = useTableSort<'slot' | 'product' | 'stock'>('slot')

const sortedTrays = computed(() => {
  const filtered = fuzzyFilter(trays.value, traySearch.value, [
    t => t.product_name,
    t => String(t.item_number),
  ])
  const dir = traySortDir.value === 'asc' ? 1 : -1
  return [...filtered].sort((a, b) => {
    if (traySortKey.value === 'slot') return dir * ((a.item_number ?? 0) - (b.item_number ?? 0))
    if (traySortKey.value === 'product') {
      const aName = saleProduct(a)?.name ?? ''
      const bName = saleProduct(b)?.name ?? ''
      return dir * aName.localeCompare(bName)
    }
    return dir * ((a.current_stock ?? 0) - (b.current_stock ?? 0))
  })
})

// Group sales by day for the sales history list
const salesByDay = computed(() => {
  const groups: { date: string; label: string; sales: typeof sales.value }[] = []
  let currentKey = ''
  let currentGroup: typeof groups[0] | null = null

  const today = new Date()
  const yesterday = new Date(today)
  yesterday.setDate(yesterday.getDate() - 1)
  const todayKey = today.toLocaleDateString(locale.value, { year: 'numeric', month: '2-digit', day: '2-digit' })
  const yesterdayKey = yesterday.toLocaleDateString(locale.value, { year: 'numeric', month: '2-digit', day: '2-digit' })

  for (const sale of sales.value) {
    const d = new Date(sale.created_at)
    const key = d.toLocaleDateString(locale.value, { year: 'numeric', month: '2-digit', day: '2-digit' })

    if (key !== currentKey) {
      let label: string
      if (key === todayKey) {
        label = t('machineDetail.today')
      } else if (key === yesterdayKey) {
        label = t('machineDetail.yesterday')
      } else {
        label = d.toLocaleDateString(locale.value, { weekday: 'long', day: 'numeric', month: 'long' })
      }
      currentKey = key
      currentGroup = { date: key, label, sales: [] }
      groups.push(currentGroup)
    }
    currentGroup!.sales.push(sale)
  }
  return groups
})

// AI Insights
const { data: insights, loading: insightsLoading, error: insightsError, fetchInsights, history: insightsHistory, historyLoading: insightsHistoryLoading, fetchHistory } = useInsights()
const insightsOpen = ref(false)
const historyExpanded = ref<string | null>(null)

function openInsights() {
  insightsOpen.value = true
  if (machine.value?.id) {
    fetchInsights(machine.value.id)
    fetchHistory(machine.value.id)
  }
}

function refreshInsights() {
  if (machine.value?.id) {
    fetchInsights(machine.value.id, 30, true)
  }
}

// Stock History Sheet
const stockHistoryOpen = ref(false)
const stockHistoryTray = ref<{ id: string; item_number: number; product_name: string | null } | null>(null)

function openStockHistory(tray: { id: string; item_number: number; product_name: string | null }) {
  stockHistoryTray.value = tray
  stockHistoryOpen.value = true
  const embeddedId = machine.value?.embeddeds?.id ?? null
  fetchStockHistory(machine.value.id, tray.item_number, embeddedId)
}

function closeStockHistory() {
  stockHistoryOpen.value = false
  stockHistoryTray.value = null
  resetStockHistory()
}

// Group stock history entries by date
const groupedStockHistory = computed(() => {
  const groups: { date: string; label: string; entries: typeof stockHistoryEntries.value }[] = []
  let currentDate = ''
  for (const entry of stockHistoryEntries.value) {
    const day = new Date(entry.created_at).toISOString().slice(0, 10)
    if (day !== currentDate) {
      currentDate = day
      const d = new Date(entry.created_at)
      const today = new Date()
      const yesterday = new Date()
      yesterday.setDate(yesterday.getDate() - 1)
      let label: string
      if (d.toDateString() === today.toDateString()) {
        label = t('history.today')
      } else if (d.toDateString() === yesterday.toDateString()) {
        label = t('history.yesterday')
      } else {
        label = formatDate(entry.created_at, locale)
      }
      groups.push({ date: day, label, entries: [] })
    }
    groups[groups.length - 1].entries.push(entry)
  }
  return groups
})

function toggleHistoryEntry(id: string) {
  historyExpanded.value = historyExpanded.value === id ? null : id
}

const machine = ref<any>(null)
const sales = ref<any[]>([])
const loading = ref(true)
const errorMsg = ref('')

async function fetchMachine() {
  const { data, error } = await supabase
    .from('vendingMachine')
    .select('id, name, location_lat, location_lon, embedded, country_code, public_listing, address_street, address_house_number, address_postal_code, address_city, formatted_address, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version, firmware_build_date, mdb_address, mdb_diagnostics, last_restart_reason, last_restart_at, online_since, softap_password)')
    .eq('id', route.params.id)
    .single()
  if (error) {
    errorMsg.value = error.message
    return
  }
  if (data) machine.value = data as any
}

// Re-fetch machine data when app resumes from background (iOS PWA etc.)
onResume(async () => {
  const id = route.params.id as string
  await Promise.all([
    fetchMachine(),
    fetchTrays(id),
  ])
})

onMounted(async () => {
  const id = route.params.id as string
  try {
    await fetchMachine()
    if (!machine.value) return

    // Fetch trays, products, and sales in parallel — sales query uses machine_id (not embedded_id)
    const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()
    const promises: PromiseLike<any>[] = [
      fetchTrays(id),
      fetchProducts(),
      supabase
        .from('sales')
        .select('id, created_at, item_price, item_number, channel, product_id, products(name, image_path)')
        .eq('machine_id', id)
        .gte('created_at', thirtyDaysAgo)
        .order('created_at', { ascending: false })
        .then(({ data: salesData, error: salesError }: any) => {
          if (salesError) throw salesError
          sales.value = salesData ?? []
        }),
    ]

    await Promise.all(promises)

    // Subscribe to live sales updates (by machine_id — works regardless of current device)
    const salesChannel = supabase
      .channel(`machine-sales-${id}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'sales',
          filter: `machine_id=eq.${id}`,
        },
        (payload) => {
          const newSale = payload.new as Record<string, any>
          if (sales.value.some(s => s.id === newSale.id)) return
          sales.value.push(newSale)
          sales.value.sort((a: any, b: any) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
        }
      )
      .on(
        'postgres_changes',
        {
          event: 'DELETE',
          schema: 'public',
          table: 'sales',
          filter: `machine_id=eq.${id}`,
        },
        (payload) => {
          const deleted = payload.old as Record<string, any>
          if (deleted?.id) {
            sales.value = sales.value.filter(s => s.id !== deleted.id)
          }
        }
      )
      .subscribe()

    onUnmounted(() => supabase.removeChannel(salesChannel))

    // Subscribe to embedded status updates (only if a device is assigned)
    if (machine.value?.embeddeds?.id) {
      const statusChannel = supabase
        .channel(`machine-status-${machine.value?.embeddeds.id}`)
        .on(
          'postgres_changes',
          {
            event: 'UPDATE',
            schema: 'public',
            table: 'embeddeds',
            filter: `id=eq.${machine.value?.embeddeds.id}`,
          },
          (payload) => {
            if (machine.value?.embeddeds) {
              machine.value.embeddeds.status = payload.new.status
              machine.value.embeddeds.status_at = payload.new.status_at
              if (payload.new.firmware_version) {
                machine.value.embeddeds.firmware_version = payload.new.firmware_version
              }
              if (payload.new.firmware_build_date) {
                machine.value.embeddeds.firmware_build_date = payload.new.firmware_build_date
              }
              if (payload.new.mdb_address !== undefined) {
                machine.value.embeddeds.mdb_address = payload.new.mdb_address
              }
              if (payload.new.mdb_diagnostics !== undefined) {
                machine.value.embeddeds.mdb_diagnostics = payload.new.mdb_diagnostics
              }
            }
          }
        )
        .subscribe()

      onUnmounted(() => supabase.removeChannel(statusChannel))

      // Fetch MDB log history + subscribe to live updates
      fetchMdbLogs(machine.value?.embeddeds.id)
      const unsubMdbLog = subscribeMdbLog(machine.value?.embeddeds.id)
      onUnmounted(unsubMdbLog)

      // Fetch device restart history + subscribe to live updates
      fetchRestarts(machine.value?.embeddeds.id)
      const unsubRestarts = subscribeRestarts(machine.value?.embeddeds.id)
      onUnmounted(unsubRestarts)
    }

    // Subscribe to tray realtime updates
    const unsubTrays = subscribeToTrayUpdates(id)
    onUnmounted(unsubTrays)
  } catch (err: unknown) {
    errorMsg.value = err instanceof Error ? err.message : t('machineDetail.failedToLoad')
  } finally {
    loading.value = false
  }
})

// Aggregate sales per day for the chart
const salesChartData = computed(() => {
  const byDay: Record<string, number> = {}
  for (const sale of sales.value) {
    const day = new Date(sale.created_at).toISOString().slice(0, 10)
    byDay[day] = (byDay[day] ?? 0) + (sale.item_price ?? 0)
  }
  return Object.entries(byDay)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, total]) => ({ date: new Date(date), total }))
})

type ChartPoint = { date: Date; total: number }

// Map item_number → product info from trays (used for tray display AND as fallback for old sales)
const trayProductMap = computed(() => {
  const map = new Map<number, { product_id: string | null; name: string; image_url: string | null; sellprice: number | null; discontinued: boolean }>()
  for (const t of trays.value) {
    if (t.product_name) {
      const product = products.value.find(p => p.id === t.product_id)
      map.set(t.item_number, {
        product_id: t.product_id ?? null,
        name: t.product_name,
        image_url: product?.image_url ?? null,
        // Prefer the tray-joined sellprice (always loaded with trays) and fall back
        // to the products list if present. This ensures the price renders even
        // before the separate products fetch completes.
        sellprice: t.product_sellprice ?? product?.sellprice ?? null,
        discontinued: t.product_discontinued ?? false,
      })
    }
  }
  return map
})

// Resolve product info for a sale: prefer snapshotted product_id FK join (immutable),
// fallback to tray lookup for old sales without product_id
function saleProduct(sale: any): { name: string; image_url: string | null } | null {
  if (sale.products?.name) {
    const imagePath = sale.products.image_path
    return {
      name: sale.products.name,
      image_url: imagePath ? getProductImageUrl(imagePath) : null,
    }
  }
  const tray = trayProductMap.value.get(sale.item_number)
  if (tray) return { name: tray.name, image_url: tray.image_url }
  return null
}

// Resolve product_id for a sale: prefer snapshotted product_id, fallback to tray.
function saleProductId(sale: any): string | null {
  if (sale.product_id) return sale.product_id
  const tray = trayProductMap.value.get(sale.item_number)
  return tray?.product_id ?? null
}

// Memoised product-id lookup per sale id, used by the sales list template to avoid
// calling saleProductId() multiple times per row render.
const saleRoutes = computed(() => {
  const m = new Map<number, string | null>()
  for (const s of sales.value) m.set(s.id, saleProductId(s))
  return m
})

// ── Inline name editing ─────────────────────────────────────────────────────
const editingName = ref(false)
const editName = ref('')
const savingName = ref(false)

function startEditName() {
  editName.value = machine.value?.name ?? ''
  editingName.value = true
  nextTick(() => {
    const input = document.getElementById('machine-name-input') as HTMLInputElement | null
    input?.focus()
    input?.select()
  })
}

function cancelEditName() {
  editingName.value = false
}

async function saveNameEdit() {
  const trimmed = editName.value.trim()
  if (!trimmed || trimmed === machine.value?.name) {
    editingName.value = false
    return
  }
  savingName.value = true
  try {
    const { error } = await supabase
      .from('vendingMachine')
      .update({ name: trimmed })
      .eq('id', machine.value.id)
    if (error) throw error
    machine.value.name = trimmed
  } catch (err: unknown) {
    // Revert on failure — no UI noise, just keep old name
  } finally {
    savingName.value = false
    editingName.value = false
  }
}

// ── Device info modal ────────────────────────────────────────────────────────
const showDeviceInfoModal = ref(false)
const showMachineSettingsModal = ref(false)

// ── Device swap ─────────────────────────────────────────────────────────────
const showDeviceModal = ref(false)
const availableDevices = ref<any[]>([])
const selectedDeviceId = ref('')
const deviceSwapLoading = ref(false)
const deviceSwapError = ref('')

async function openDeviceModal() {
  deviceSwapError.value = ''
  selectedDeviceId.value = ''
  deviceSwapLoading.value = false
  showDeviceModal.value = true
  try {
    availableDevices.value = await fetchUnassignedEmbeddeds()
  } catch {
    deviceSwapError.value = t('common.failedTo', { action: 'load devices' })
  }
}

async function submitDeviceSwap() {
  if (!selectedDeviceId.value) return
  deviceSwapLoading.value = true
  deviceSwapError.value = ''
  try {
    await swapDevice(machine.value.id, selectedDeviceId.value)
    // Re-fetch machine to get updated embeddeds join
    await fetchMachine()
    showDeviceModal.value = false
  } catch (err: unknown) {
    deviceSwapError.value = err instanceof Error ? err.message : t('machineDetail.failedToSwapDevice')
  } finally {
    deviceSwapLoading.value = false
  }
}

async function detachDevice() {
  deviceSwapLoading.value = true
  try {
    await swapDevice(machine.value.id, null)
    await fetchMachine()
  } catch (err: unknown) {
    // silent
  } finally {
    deviceSwapLoading.value = false
  }
}

// ── Send credit ─────────────────────────────────────────────────────────────
const showCreditModal = ref(false)
const creditAmount = ref('')
const creditLoading = ref(false)
const creditError = ref('')
const creditSuccess = ref('')

function openCreditModal() {
  creditAmount.value = ''
  creditError.value = ''
  creditSuccess.value = ''
  creditLoading.value = false
  showCreditModal.value = true
}

async function submitCredit() {
  const amount = parseFloat(creditAmount.value)
  if (!amount || amount <= 0) {
    creditError.value = t('machineDetail.enterValidAmount')
    return
  }
  creditLoading.value = true
  creditError.value = ''
  creditSuccess.value = ''
  try {
    const session = useSupabaseSession()
    const token = session.value?.access_token
    if (!token) throw new Error('Not authenticated')

    const result = await $fetch<{ status: string }>('/functions/v1/send-credit', {
      baseURL: useRuntimeConfig().public.supabase.url,
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: { device_id: machine.value.embeddeds.id, amount },
    })
    if (result?.status === 'online') {
      creditSuccess.value = t('machineDetail.creditSentSuccess', { amount: formatCurrency(amount, locale.value) })
    } else {
      creditSuccess.value = t('machineDetail.creditQueued', { status: result?.status ?? 'unknown' })
    }
    creditAmount.value = ''
  } catch (err: unknown) {
    const fetchErr = err as any
    creditError.value = fetchErr?.data?.error ?? fetchErr?.data?.message ?? fetchErr?.message ?? t('machineDetail.failedToSendCredit')
  } finally {
    creditLoading.value = false
  }
}

const cancelCreditLoading = ref(false)

async function cancelCredit() {
  cancelCreditLoading.value = true
  creditError.value = ''
  creditSuccess.value = ''
  try {
    const session = useSupabaseSession()
    const token = session.value?.access_token
    if (!token) throw new Error('Not authenticated')

    await $fetch<{ status: string }>('/functions/v1/send-credit', {
      baseURL: useRuntimeConfig().public.supabase.url,
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: { device_id: machine.value.embeddeds.id, amount: 0 },
    })
    creditSuccess.value = t('machineDetail.creditCancelled')
  } catch (err: unknown) {
    const fetchErr = err as any
    creditError.value = fetchErr?.data?.error ?? fetchErr?.data?.message ?? fetchErr?.message ?? t('machineDetail.failedToCancelCredit')
  } finally {
    cancelCreditLoading.value = false
  }
}

// ── MDB Address config ──────────────────────────────────────────────────────
const mdbAddressLoading = ref(false)
const mdbAddressError = ref('')

const restartLoading = ref(false)

async function restartDevice() {
  if (!machine.value?.embeddeds?.id) return

  restartLoading.value = true
  try {
    const session = useSupabaseSession()
    const token = session.value?.access_token
    if (!token) throw new Error('Not authenticated')

    await $fetch('/functions/v1/send-device-config', {
      baseURL: useRuntimeConfig().public.supabase.url,
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: { device_id: machine.value.embeddeds.id, config: { restart: true } },
    })
  } catch (err: unknown) {
    // Show error inline (reuse mdbAddressError for simplicity)
    mdbAddressError.value = err instanceof Error ? err.message : 'Restart failed'
  } finally {
    restartLoading.value = false
  }
}

async function setMdbAddress(address: 1 | 2) {
  if (!machine.value?.embeddeds?.id) return
  if ((machine.value.embeddeds as any).mdb_address === address) return

  mdbAddressLoading.value = true
  mdbAddressError.value = ''
  try {
    const session = useSupabaseSession()
    const token = session.value?.access_token
    if (!token) throw new Error('Not authenticated')

    const { data, error } = await useFetch('/functions/v1/send-device-config', {
      baseURL: useRuntimeConfig().public.supabase.url,
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: { device_id: machine.value.embeddeds.id, config: { mdb_address: address } },
    })

    if (error.value) throw new Error((error.value as any).data?.error ?? error.value.message ?? 'Failed to update config')

    // Optimistically update the local state
    ;(machine.value.embeddeds as any).mdb_address = address
  } catch (err: unknown) {
    mdbAddressError.value = err instanceof Error ? err.message : t('machineDetail.failedToUpdateMdb')
  } finally {
    mdbAddressLoading.value = false
  }
}

// ── Tray management ─────────────────────────────────────────────────────────
const trayModal = useModalForm({ item_number: 0, product_id: '' as string | null, capacity: 10, current_stock: 0 })

function openAddTray() {
  const maxSlot = trays.value.length > 0
    ? Math.max(...trays.value.map(t => t.item_number)) + 1
    : 0
  trayModal.openModal({ item_number: maxSlot, product_id: '', capacity: 10, current_stock: 0 })
}

async function submitTray() {
  if (trayModal.form.value.item_number < 0) {
    trayModal.error.value = t('machineDetail.slotMustBePositive')
    return
  }
  if (trayModal.form.value.capacity < 1) {
    trayModal.error.value = t('machineDetail.capacityAtLeastOne')
    return
  }
  if (trayModal.form.value.current_stock > trayModal.form.value.capacity) {
    trayModal.error.value = t('machineDetail.stockCannotExceed')
    return
  }
  await trayModal.submit(async () => {
    await upsertTray({
      machine_id: machine.value.id,
      item_number: trayModal.form.value.item_number,
      product_id: trayModal.form.value.product_id || null,
      capacity: trayModal.form.value.capacity,
      current_stock: trayModal.form.value.current_stock,
    })
  })
}

// ── Inline tray editing ─────────────────────────────────────────────────────
const activeAutocompleteTrayId = ref<string | null>(null)
const productQuery = ref('')
const highlightedIndex = ref(-1)

const filteredProducts = computed(() => {
  return fuzzyFilter(products.value, productQuery.value, [p => p.name])
})

// Auto-highlight best match as the user types
watch(productQuery, () => {
  if (!activeAutocompleteTrayId.value) return
  const q = productQuery.value.toLowerCase().trim()
  if (q && filteredProducts.value.length > 0) {
    // Prefer "starts with" match; fall back to first contains match
    const startsIdx = filteredProducts.value.findIndex(p => p.name.toLowerCase().startsWith(q))
    highlightedIndex.value = startsIdx >= 0 ? startsIdx + 1 : 1 // +1 because 0 = "None"
  } else {
    highlightedIndex.value = -1
  }
})

function openProductAutocomplete(tray: any) {
  activeAutocompleteTrayId.value = tray.id
  productQuery.value = ''
  highlightedIndex.value = -1
  nextTick(() => {
    const input = document.getElementById(`product-input-${tray.id}`) as HTMLInputElement | null
    input?.focus()
  })
}

async function selectProduct(trayId: string, productId: string | null) {
  activeAutocompleteTrayId.value = null
  // Focus stock input immediately so keyboard flow continues
  nextTick(() => {
    const el = document.getElementById(`stock-${trayId}`) as HTMLInputElement | null
    el?.focus()
    el?.select()
  })
  try {
    await updateTray(trayId, machine.value.id, { product_id: productId })
  } catch {
    // silent — tray reverts to previous value via fetchTrays
  }
}

function handleProductBlur(trayId: string) {
  // Delay to allow click on dropdown item to register first
  setTimeout(() => {
    if (activeAutocompleteTrayId.value === trayId) {
      activeAutocompleteTrayId.value = null
    }
  }, 200)
}

function handleProductKeydown(event: KeyboardEvent, trayId: string) {
  const itemCount = filteredProducts.value.length + 1 // +1 for "None" option
  if (event.key === 'Escape') {
    event.preventDefault()
    activeAutocompleteTrayId.value = null
    // Return focus to the product button
    nextTick(() => {
      const btn = document.getElementById(`product-btn-${trayId}`) as HTMLElement | null
      btn?.focus()
    })
    return
  }
  if (event.key === 'ArrowDown') {
    event.preventDefault()
    highlightedIndex.value = Math.min(highlightedIndex.value + 1, itemCount - 1)
    return
  }
  if (event.key === 'ArrowUp') {
    event.preventDefault()
    highlightedIndex.value = Math.max(highlightedIndex.value - 1, 0)
    return
  }
  if (event.key === 'Enter') {
    event.preventDefault()
    if (highlightedIndex.value === 0) {
      selectProduct(trayId, null)
    } else if (highlightedIndex.value > 0 && highlightedIndex.value <= filteredProducts.value.length) {
      selectProduct(trayId, filteredProducts.value[highlightedIndex.value - 1].id)
    }
    return
  }
  if (event.key === 'Tab' && !event.shiftKey) {
    event.preventDefault()
    // Auto-select highlighted product and advance to stock
    if (highlightedIndex.value === 0) {
      selectProduct(trayId, null)
    } else if (highlightedIndex.value > 0 && highlightedIndex.value <= filteredProducts.value.length) {
      selectProduct(trayId, filteredProducts.value[highlightedIndex.value - 1].id)
    } else {
      // Nothing highlighted — just close and advance to stock
      activeAutocompleteTrayId.value = null
      nextTick(() => {
        const el = document.getElementById(`stock-${trayId}`) as HTMLInputElement | null
        el?.focus()
        el?.select()
      })
    }
    return
  }
  // Shift+Tab: let default behaviour move focus backwards; blur handler closes the dropdown
}

async function saveInlineField(trayId: string, field: 'capacity' | 'current_stock' | 'min_stock' | 'fill_when_below', value: number) {
  const tray = trays.value.find(t => t.id === trayId)
  if (!tray) return

  // Validate
  if (field === 'capacity' && value < 1) return
  if (field === 'current_stock' && (value < 0 || value > (tray.capacity ?? 100))) return
  if (field === 'min_stock' && value < 0) return
  if (field === 'fill_when_below' && (value < 0 || (value > 0 && value < (tray.min_stock || 0)))) return

  // Skip save if value unchanged
  if (tray[field] === value) return

  // If min_stock is raised above fill_when_below, bump fill_when_below up too
  if (field === 'min_stock' && tray.fill_when_below > 0 && value > tray.fill_when_below) {
    try {
      await updateTray(trayId, machine.value.id, { min_stock: value, fill_when_below: value })
    } catch { /* silent */ }
    return
  }

  try {
    await updateTray(trayId, machine.value.id, { [field]: value })
  } catch {
    // silent — reverts via fetchTrays
  }
}

function handleStockKeydown(event: KeyboardEvent, trayId: string) {
  if (event.key === 'Enter') {
    event.preventDefault()
    const val = parseInt((event.target as HTMLInputElement).value) || 0
    saveInlineField(trayId, 'current_stock', val)
    // Advance to capacity input
    nextTick(() => {
      const el = document.getElementById(`capacity-${trayId}`) as HTMLInputElement | null
      el?.focus()
      el?.select()
    })
  }
  if (event.key === 'Escape') {
    (event.target as HTMLInputElement).blur()
  }
}

function handleCapacityKeydown(event: KeyboardEvent, trayId: string) {
  if (event.key === 'Enter') {
    event.preventDefault()
    const val = parseInt((event.target as HTMLInputElement).value) || 1
    saveInlineField(trayId, 'capacity', val)
    // Advance to min-stock input
    nextTick(() => {
      const el = document.getElementById(`min-stock-${trayId}`) as HTMLInputElement | null
      el?.focus()
      el?.select()
    })
  }
  if (event.key === 'Escape') {
    (event.target as HTMLInputElement).blur()
  }
}

function handleMinStockKeydown(event: KeyboardEvent, trayId: string) {
  if (event.key === 'Enter') {
    event.preventDefault()
    const val = parseInt((event.target as HTMLInputElement).value) || 0
    saveInlineField(trayId, 'min_stock', val)
    // Advance to fill-when-below input
    nextTick(() => {
      const el = document.getElementById(`fill-below-${trayId}`) as HTMLInputElement | null
      el?.focus()
      el?.select()
    })
  }
  if (event.key === 'Escape') {
    (event.target as HTMLInputElement).blur()
  }
}

function handleFillBelowKeydown(event: KeyboardEvent, trayId: string) {
  if (event.key === 'Enter') {
    event.preventDefault()
    const val = parseInt((event.target as HTMLInputElement).value) || 0
    saveInlineField(trayId, 'fill_when_below', val)
    // Advance to next row's product button (or blur if last row)
    const idx = trays.value.findIndex(t => t.id === trayId)
    const nextTray = trays.value[idx + 1]
    if (nextTray) {
      nextTick(() => {
        const el = document.getElementById(`product-btn-${nextTray.id}`) as HTMLElement | null
        el?.focus()
      })
    } else {
      (event.target as HTMLInputElement).blur()
    }
  }
  if (event.key === 'Escape') {
    (event.target as HTMLInputElement).blur()
  }
}

// Batch add trays
const batchModal = useModalForm({ startSlot: 0, count: 10, capacity: 10 })

function openBatchAdd() {
  const maxSlot = trays.value.length > 0
    ? Math.max(...trays.value.map(t => t.item_number)) + 1
    : 0
  batchModal.openModal({ startSlot: maxSlot, count: 10, capacity: 10 })
}

async function submitBatch() {
  if (batchModal.form.value.count < 1) {
    batchModal.error.value = t('machineDetail.countAtLeastOne')
    return
  }
  if (batchModal.form.value.count > 100) {
    batchModal.error.value = t('machineDetail.maxTrays')
    return
  }
  if (batchModal.form.value.startSlot < 0) {
    batchModal.error.value = t('machineDetail.startSlotPositive')
    return
  }
  if (batchModal.form.value.capacity < 1) {
    batchModal.error.value = t('machineDetail.capacityAtLeastOne')
    return
  }
  await batchModal.submit(async () => {
    await batchCreateTrays(machine.value.id, batchModal.form.value.startSlot, batchModal.form.value.count, batchModal.form.value.capacity)
  })
}

// One-click "Full" refill (no warehouse deduction — that happens at the packing list stage)
async function handleRefillFull(trayId: string) {
  await refillToFull(trayId, machine.value.id)
}

// Quick +/- stock adjustment (mobile) — debounced to prevent UI glitches
function adjustStock(trayId: string, delta: number) {
  adjustStockDebounced(trayId, machine.value.id, delta)
}

// Mobile: expanded tray for threshold editing
const expandedMobileTray = ref<string | null>(null)

// Refill all below-minimum trays
// When coming from the packing list flow, only refill by the packed amount
const refillAllLoading = ref(false)
const packedQuantities = ref<Record<string, number> | null>(null)

// Read packed quantities from sessionStorage (set by index page's packing list)
onMounted(() => {
  const machineId = route.params.id as string
  const key = `refill-packed-${machineId}`
  const stored = sessionStorage.getItem(key)
  if (stored) {
    try {
      packedQuantities.value = JSON.parse(stored)
    } catch { /* ignore */ }
    sessionStorage.removeItem(key)
  }
})

async function handleRefillAll() {
  refillAllLoading.value = true
  try {
    await refillAll(machine.value.id, packedQuantities.value ?? undefined)
    // Clear packed quantities after successful refill
    packedQuantities.value = null
  } finally {
    refillAllLoading.value = false
  }
}

async function handleDeleteTray(trayId: string) {
  try {
    await deleteTray(trayId, machine.value.id)
  } catch {
    // silent
  }
}

// Summary computed
const lowStockCount = computed(() =>
  trays.value.filter(t => t.min_stock > 0 && t.current_stock <= t.min_stock).length
)

const fillBelowCount = computed(() =>
  trays.value.filter(t =>
    !isLowStock(t) && t.fill_when_below > 0 && t.current_stock <= t.fill_when_below && t.current_stock > 0
  ).length
)

// Packing list: group needed items by product for low-stock and fill-when-below trays, ordered by first slot appearance
const packingList = computed(() => {
  const hasCritical = trays.value.some(t => isLowStock(t))
  const map = new Map<string, { product_id: string | null; name: string; needed: number; packed: number | null; image_url: string | null; firstSlot: number; critical: boolean }>()
  for (const tray of trays.value) {
    const critical = isLowStock(tray)
    const soft = hasCritical && isFillBelow(tray)
    if (!critical && !soft) continue
    const deficit = tray.capacity - tray.current_stock
    if (deficit <= 0) continue
    const key = tray.product_id || `slot-${tray.item_number}`
    const name = tray.product_name || `${t('machineDetail.slot')} ${tray.item_number}`
    const existing = map.get(key)
    if (existing) {
      existing.needed += deficit
      if (critical) existing.critical = true
    } else {
      const product = products.value.find(p => p.id === tray.product_id)
      map.set(key, { product_id: tray.product_id, name, needed: deficit, packed: null, image_url: product?.image_url ?? null, firstSlot: tray.item_number, critical })
    }
  }
  // When packed quantities are available, annotate each item with the packed amount
  if (packedQuantities.value) {
    for (const item of map.values()) {
      item.packed = item.product_id ? (packedQuantities.value[item.product_id] ?? 0) : null
    }
  }
  return Array.from(map.values()).sort((a, b) => a.firstSlot - b.firstSlot)
})

const isRefillMode = computed(() => route.query.tab === 'stock')

function isLowStock(tray: any) {
  return tray.min_stock > 0 && tray.current_stock <= tray.min_stock
}

function isFillBelow(tray: any) {
  return !isLowStock(tray) && tray.fill_when_below > 0 && tray.current_stock <= tray.fill_when_below && tray.current_stock > 0
}

function isHealthyInRefillMode(tray: any) {
  return isRefillMode.value && !isLowStock(tray) && !isFillBelow(tray) && tray.current_stock > 0
}

function trayDeficit(tray: any) {
  return Math.max(0, tray.capacity - tray.current_stock)
}

function stockPercent(tray: any) {
  if (tray.capacity === 0) return 0
  return Math.round((tray.current_stock / tray.capacity) * 100)
}

function minStockPercent(tray: any) {
  if (tray.capacity === 0 || !tray.min_stock) return 0
  return Math.round((tray.min_stock / tray.capacity) * 100)
}

function fillBelowPercent(tray: any) {
  if (tray.capacity === 0 || !tray.fill_when_below) return 0
  return Math.round((tray.fill_when_below / tray.capacity) * 100)
}

function stockColor(tray: any) {
  if (isLowStock(tray)) return 'bg-red-500'
  if (isFillBelow(tray)) return 'bg-amber-500'
  const pct = stockPercent(tray)
  if (pct > 50) return 'bg-green-500'
  if (pct > 20) return 'bg-yellow-500'
  return 'bg-red-500'
}

// ── Manual sale delete / insert ──────────────────────────────────────────────

const showDeleteSaleConfirm = ref(false)
const deletingSale = ref<any>(null)
const deletingSaleLoading = ref(false)

const showAddSaleModal = ref(false)
const addSaleLoading = ref(false)
const addSaleForm = reactive({
  item_number: null as number | null,
  item_price: 0,
  channel: 'cash',
  created_at: '',
})

function resetAddSaleForm() {
  addSaleForm.item_number = null
  addSaleForm.item_price = 0
  addSaleForm.channel = 'cash'
  addSaleForm.created_at = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 19)
}

function openAddSaleModal() {
  resetAddSaleForm()
  showAddSaleModal.value = true
}

// Auto-fill price when slot changes
watch(() => addSaleForm.item_number, (num) => {
  if (num == null) return
  const info = trayProductMap.value.get(num)
  if (info?.sellprice) addSaleForm.item_price = info.sellprice
})

function confirmDeleteSale(sale: any) {
  deletingSale.value = sale
  showDeleteSaleConfirm.value = true
}

async function logSaleActivity(action: string, entityId: string | null, metadata: Record<string, unknown>) {
  try {
    const { data: { session } } = await supabase.auth.getSession()
    const u = session?.user ?? null
    const fullName = [u?.user_metadata?.first_name, u?.user_metadata?.last_name].filter(Boolean).join(' ').trim()
    const userDisplay = fullName || u?.email || null
    const { organization } = useOrganization()
    await (supabase as any).from('activity_log').insert({
      company_id: organization.value?.id,
      user_id: u?.id ?? null,
      entity_type: 'sale',
      entity_id: entityId,
      action,
      metadata: { ...metadata, _user_email: u?.email ?? null, _user_display: userDisplay },
    })
  } catch (err) {
    console.warn('activity_log insert failed:', err)
  }
}

async function handleDeleteSale() {
  if (!deletingSale.value?.id || !machine.value) return
  deletingSaleLoading.value = true
  try {
    const { error } = await (supabase as any).rpc('delete_sale_and_restore_stock', { p_sale_id: deletingSale.value.id })
    if (error) throw error
    // Optimistically remove from local list
    sales.value = sales.value.filter(s => s.id !== deletingSale.value.id)
    // Refresh trays to show updated stock
    await fetchTrays(machine.value.id, { silent: true })
    // Log to activity log
    await logSaleActivity('sale_deleted', deletingSale.value.id, {
      machine_id: machine.value.id,
      machine_name: machine.value.name,
      item_number: deletingSale.value.item_number,
      item_price: deletingSale.value.item_price,
      channel: deletingSale.value.channel,
      sale_created_at: deletingSale.value.created_at,
    })
  } catch (err: any) {
    console.error('Failed to delete sale:', err)
  } finally {
    deletingSaleLoading.value = false
    showDeleteSaleConfirm.value = false
    deletingSale.value = null
  }
}

async function handleAddSale() {
  if (!machine.value || addSaleForm.item_number == null) return
  addSaleLoading.value = true
  try {
    const { data, error } = await (supabase as any).rpc('insert_manual_sale', {
      p_machine_id: machine.value.id,
      p_item_number: addSaleForm.item_number,
      p_item_price: addSaleForm.item_price,
      p_channel: addSaleForm.channel,
      p_created_at: new Date(addSaleForm.created_at).toISOString(),
    })
    if (error) throw error
    // Prepend to local list if returned
    if (data) {
      const newSale = typeof data === 'string' ? JSON.parse(data) : data
      // Check if not already in list (realtime might have added it)
      if (!sales.value.some(s => s.id === newSale.id)) {
        sales.value.unshift(newSale)
        sales.value.sort((a: any, b: any) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
      }
    }
    // Refresh trays to show updated stock
    await fetchTrays(machine.value.id, { silent: true })
    // Log to activity log
    await logSaleActivity('sale_inserted', data?.id ?? null, {
      machine_id: machine.value.id,
      machine_name: machine.value.name,
      item_number: addSaleForm.item_number,
      item_price: addSaleForm.item_price,
      channel: addSaleForm.channel,
      sale_created_at: addSaleForm.created_at,
      source: 'manual',
    })
    showAddSaleModal.value = false
  } catch (err: any) {
    console.error('Failed to add sale:', err)
  } finally {
    addSaleLoading.value = false
  }
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
        <div v-if="loading" class="text-muted-foreground">{{ t('common.loading') }}</div>
        <div v-else-if="errorMsg" class="text-destructive">{{ errorMsg }}</div>
        <template v-else-if="machine">
          <!-- Machine info -->
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <div v-if="editingName" class="flex items-center gap-2">
                <input
                  id="machine-name-input"
                  v-model="editName"
                  type="text"
                  class="h-9 w-full rounded-md border bg-transparent px-3 text-xl font-semibold shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring sm:text-2xl"
                  @keydown.enter="saveNameEdit"
                  @keydown.escape="cancelEditName"
                  @blur="saveNameEdit"
                />
              </div>
              <h1
                v-else
                class="group flex cursor-pointer items-center gap-2 text-xl font-semibold sm:text-2xl"
                @click="startEditName"
              >
                {{ machine.name ?? t('machines.unnamedMachine') }}
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/><path d="m15 5 4 4"/></svg>
              </h1>
              <p
                v-if="machine.location_lat != null && machine.location_lon != null"
                class="mt-1 text-sm text-muted-foreground"
                :class="{ 'cursor-pointer hover:text-foreground transition-colors': isAdmin }"
                @click="isAdmin && (showMachineSettingsModal = true)"
              >
                {{ machine.location_lat.toFixed(5) }}, {{ machine.location_lon.toFixed(5) }}
              </p>
            </div>
            <!-- Device: compact header row -->
            <div class="flex items-center gap-2 shrink-0">
              <template v-if="machine.embeddeds">
                <span
                  class="rounded-full px-3 py-1 text-xs font-medium"
                  :class="{
                    'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400': machine.embeddeds.status === 'online' || machine.embeddeds.status === 'ota_success',
                    'bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400': machine.embeddeds.status === 'ota_updating',
                    'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400': machine.embeddeds.status === 'ota_failed',
                    'bg-muted text-muted-foreground': !['online', 'ota_updating', 'ota_success', 'ota_failed'].includes(machine.embeddeds.status),
                  }"
                >
                  {{ machine.embeddeds.status === 'ota_updating' ? t('machineDetail.updating') : machine.embeddeds.status === 'ota_success' ? t('machineDetail.updated') : machine.embeddeds.status === 'ota_failed' ? t('machineDetail.updateFailed') : machine.embeddeds.status === 'online' ? t('machineDetail.online') : machine.embeddeds.status === 'offline' ? t('machineDetail.offline') : machine.embeddeds.status }}
                </span>
                <button
                  class="inline-flex items-center gap-1 rounded-md border px-3 py-1.5 text-xs font-medium text-muted-foreground shadow-sm transition-colors hover:bg-muted hover:text-foreground"
                  @click="openInsights"
                >
                  <IconSparkles class="size-3" />
                  <span class="hidden sm:inline">{{ t('machineDetail.aiInsights') }}</span>
                </button>
                <button
                  v-if="isAdmin"
                  class="inline-flex items-center gap-1 rounded-md bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground shadow-sm transition-colors hover:bg-primary/90"
                  @click="openCreditModal"
                >
                  <IconSend class="size-3" />
                  <span class="hidden sm:inline">{{ t('machineDetail.sendCredit') }}</span>
                </button>
                <DropdownMenu>
                  <DropdownMenuTrigger as-child>
                    <button
                      class="inline-flex h-8 w-8 items-center justify-center rounded-md border text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                      :title="t('machineDetail.settings')"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/></svg>
                    </button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end">
                    <DropdownMenuItem v-if="isAdmin" @click="showMachineSettingsModal = true">
                      {{ t('machineSettings.title') }}
                    </DropdownMenuItem>
                    <DropdownMenuItem @click="showDeviceInfoModal = true">
                      {{ t('machineDetail.deviceDetails') }}
                    </DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenu>
              </template>
              <template v-else>
                <span class="rounded-full bg-muted px-3 py-1 text-xs font-medium text-muted-foreground">
                  {{ t('machineDetail.noDevice') }}
                </span>
                <button
                  v-if="isAdmin"
                  class="text-xs text-primary hover:underline"
                  @click="openDeviceModal"
                >
                  {{ t('machineDetail.assignDevice') }}
                </button>
                <DropdownMenu v-if="isAdmin">
                  <DropdownMenuTrigger as-child>
                    <button
                      class="inline-flex h-8 w-8 items-center justify-center rounded-md border text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                      :title="t('machineDetail.settings')"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/></svg>
                    </button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end">
                    <DropdownMenuItem @click="showMachineSettingsModal = true">
                      {{ t('machineSettings.title') }}
                    </DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenu>
              </template>
            </div>
          </div>

          <!-- Tabs: Sales | Trays & Stock | MDB -->
          <Tabs :default-value="defaultTab">
            <TabsList>
              <TabsTrigger value="sales">{{ t('machineDetail.sales') }}</TabsTrigger>
              <TabsTrigger v-if="isAdmin" value="mdb">{{ t('machineDetail.mdb') }}</TabsTrigger>
              <TabsTrigger value="trays">{{ t('machineDetail.traysAndStock') }}</TabsTrigger>
              <TabsTrigger v-if="machine?.embeddeds" value="health">{{ t('machineDetail.deviceHealth') }}</TabsTrigger>
            </TabsList>

            <!-- Sales tab -->
            <TabsContent value="sales" class="mt-4 space-y-6">
              <!-- Sales chart -->
              <div v-if="salesChartData.length > 0" class="rounded-xl border bg-card p-4 sm:p-6">
                <h2 class="mb-4 text-sm font-medium">{{ t('machineDetail.dailyRevenue') }}</h2>
                <VisXYContainer :data="salesChartData" class="h-48 w-full">
                  <VisStackedBar :x="(d: ChartPoint) => d.date" :y="[(d: ChartPoint) => d.total]" color="var(--primary)" :bar-padding="0.2" :rounded-corners="4" />
                  <VisAxis
                    type="x"
                    :x="(d: ChartPoint) => d.date"
                    :tick-format="(d: number) => new Date(d).toLocaleDateString(locale, { month: 'short', day: 'numeric' })"
                    :num-ticks="4"
                    :tick-line="false"
                    :domain-line="false"
                    :grid-line="false"
                  />
                  <VisAxis type="y" :num-ticks="3" :tick-line="false" :domain-line="false" />
                </VisXYContainer>
              </div>

              <!-- Sales list -->
              <div>
                <div class="mb-3 flex items-center justify-between">
                  <h2 class="text-lg font-medium">{{ t('machineDetail.salesHistory') }}</h2>
                  <button
                    v-if="isAdmin"
                    class="inline-flex h-8 items-center gap-1.5 rounded-md border border-input px-2.5 text-xs font-medium text-muted-foreground hover:bg-muted hover:text-foreground transition-colors"
                    @click="openAddSaleModal"
                  >
                    <IconPlus class="size-3.5" />
                    {{ t('machineDetail.addSale') }}
                  </button>
                </div>
                <div v-if="sales.length === 0" class="text-sm text-muted-foreground">{{ t('machineDetail.noSalesLast30') }}</div>
                <div v-else class="space-y-4">
                  <div v-for="group in salesByDay" :key="group.date">
                    <div class="sticky top-0 z-10 mb-2 flex items-center gap-3">
                      <span class="text-xs font-medium text-muted-foreground">{{ group.label }}</span>
                      <span class="text-[10px] tabular-nums text-muted-foreground/60">{{ t('machineDetail.saleCount', { count: group.sales.length }, group.sales.length) }}</span>
                      <div class="h-px flex-1 bg-border" />
                    </div>
                    <div class="rounded-xl border bg-card divide-y">
                      <SwipeToDelete
                        v-for="sale in group.sales"
                        :key="sale.id"
                        :disabled="!isAdmin"
                        @delete="confirmDeleteSale(sale)"
                      >
                        <component
                          :is="saleRoutes.get(sale.id) ? NuxtLink : 'div'"
                          :to="saleRoutes.get(sale.id) ? `/products/${saleRoutes.get(sale.id)}` : undefined"
                          class="group/sale flex items-start gap-3 px-4 py-3"
                          :class="{ 'cursor-pointer hover:bg-muted/50 transition-colors': saleRoutes.get(sale.id) }"
                        >
                          <!-- Product image or amount badge -->
                          <img
                            v-if="saleProduct(sale)?.image_url"
                            :src="saleProduct(sale)!.image_url!"
                            :alt="saleProduct(sale)!.name"
                            class="h-9 w-9 shrink-0 rounded-full object-cover mt-0.5"
                          />
                          <div v-else class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-primary/10 text-xs font-semibold text-primary mt-0.5">
                            {{ formatCurrency(sale.item_price, locale) }}
                          </div>
                          <!-- Main info -->
                          <div class="flex-1 min-w-0">
                            <div class="flex items-start justify-between gap-2">
                              <p class="text-sm font-medium break-words">
                                {{ saleProduct(sale)?.name ?? `${t('machineDetail.item')} #${sale.item_number}` }}
                                <!-- Desktop delete button (inline after title) -->
                                <button
                                  v-if="isAdmin"
                                  class="hidden sm:inline-flex ml-1 align-middle rounded-md p-0.5 text-muted-foreground/0 transition-colors group-hover/sale:text-muted-foreground hover:!text-destructive"
                                  @click.stop.prevent="confirmDeleteSale(sale)"
                                >
                                  <IconTrash class="size-3.5" />
                                </button>
                              </p>
                              <span class="shrink-0 text-sm font-semibold tabular-nums">{{ formatCurrency(sale.item_price, locale) }}</span>
                            </div>
                            <div class="mt-0.5 flex items-center justify-between">
                              <div class="flex items-center gap-1.5 text-xs text-muted-foreground">
                                <span class="whitespace-nowrap">{{ t('machineDetail.slot') }} {{ sale.item_number }}</span>
                                <span class="text-muted-foreground/40">·</span>
                                <span
                                  class="inline-flex items-center gap-0.5 text-[10px] font-medium uppercase tracking-wide"
                                  :class="sale.channel === 'card'
                                    ? 'text-blue-600 dark:text-blue-400'
                                    : sale.channel === 'cashless'
                                      ? 'text-violet-600 dark:text-violet-400'
                                      : 'text-emerald-600 dark:text-emerald-400'"
                                >
                                  <IconCreditCard v-if="sale.channel === 'card'" class="size-3" />
                                  <IconDeviceMobile v-else-if="sale.channel === 'cashless'" class="size-3" />
                                  <IconCoins v-else class="size-3" />
                                  {{ sale.channel }}
                                </span>
                              </div>
                              <span class="shrink-0 text-[11px] text-muted-foreground tabular-nums">{{ new Date(sale.created_at).toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit', second: '2-digit' }) }}</span>
                            </div>
                          </div>
                        </component>
                      </SwipeToDelete>
                    </div>
                  </div>
                </div>
              </div>
            </TabsContent>

            <!-- Trays & Stock tab -->
            <TabsContent value="trays" class="mt-4">
              <div class="mb-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                <h2 class="text-base font-medium">{{ t('machineDetail.trayConfiguration') }}</h2>
                <div v-if="isAdmin" class="flex items-center gap-2">
                  <button
                    class="inline-flex h-9 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
                    @click="openBatchAdd"
                  >
                    {{ t('machineDetail.batchAdd') }}
                  </button>
                  <button
                    class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
                    @click="openAddTray"
                  >
                    {{ t('machineDetail.addTray') }}
                  </button>
                </div>
              </div>

              <div v-if="traysLoading" class="text-sm text-muted-foreground">{{ t('machineDetail.loadingTrays') }}</div>
              <div v-else-if="trays.length === 0" class="text-sm text-muted-foreground">{{ t('machineDetail.noTraysConfiguredDetail') }}</div>
              <template v-else>
                <SearchInput v-model="traySearch" :placeholder="t('common.search') + '...'" class="max-w-xs mb-3" />
                <div v-if="sortedTrays.length === 0" class="text-sm text-muted-foreground">{{ t('common.noResults') }}</div>
                <!-- ── Mobile card layout ── -->
                <div class="space-y-3 md:hidden">
                  <SwipeRight
                    v-for="tray in sortedTrays"
                    :key="'m-' + tray.id"
                    :label="t('machineDetail.stockHistory')"
                    @action="openStockHistory(tray)"
                  >
                    <template #icon>
                      <IconHistory class="size-5" />
                    </template>
                  <div
                    class="rounded-lg border p-3 transition-colors"
                    :class="[
                      isLowStock(tray) ? 'border-amber-300 bg-amber-50/60 dark:border-amber-700 dark:bg-amber-950/20'
                        : isFillBelow(tray) && lowStockCount > 0 ? 'border-blue-300 bg-blue-50/40 dark:border-blue-700 dark:bg-blue-950/10'
                        : 'bg-card',
                      isHealthyInRefillMode(tray) ? 'opacity-40' : '',
                    ]"
                  >
                    <!-- Row 1: image + slot + product + actions -->
                    <div class="flex items-center gap-3">
                      <!-- Product image -->
                      <img
                        v-if="trayProductMap.get(tray.item_number)?.image_url"
                        :src="trayProductMap.get(tray.item_number)!.image_url!"
                        :alt="tray.product_name ?? ''"
                        class="h-10 w-10 shrink-0 rounded-lg object-cover"
                      />
                      <div v-else class="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-muted text-xs font-semibold text-muted-foreground">
                        {{ (tray.product_name ?? '?').charAt(0) }}
                      </div>
                      <!-- Slot badge -->
                      <span class="inline-flex h-6 min-w-[1.5rem] shrink-0 items-center justify-center rounded-md bg-foreground/10 px-1 text-[10px] font-bold tabular-nums text-foreground">
                        #{{ tray.item_number }}
                      </span>
                      <!-- Product name -->
                      <div class="min-w-0 flex-1">
                        <template v-if="isAdmin">
                          <div v-if="activeAutocompleteTrayId === tray.id" class="relative">
                            <input
                              :id="`product-input-${tray.id}`"
                              v-model="productQuery"
                              type="text"
                              :placeholder="t('machineDetail.searchProducts')"
                              role="combobox"
                              aria-expanded="true"
                              aria-autocomplete="list"
                              autocomplete="off"
                              class="h-8 w-full rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                              @blur="handleProductBlur(tray.id)"
                              @keydown="(e: KeyboardEvent) => handleProductKeydown(e, tray.id)"
                            />
                            <div class="absolute left-0 top-full z-50 mt-1 max-h-48 w-full min-w-[200px] overflow-auto rounded-md border bg-popover shadow-md" role="listbox">
                              <button
                                type="button"
                                tabindex="-1"
                                class="w-full px-3 py-1.5 text-left text-sm hover:bg-accent"
                                :class="{ 'bg-accent': highlightedIndex === 0 }"
                                role="option"
                                @mousedown.prevent="selectProduct(tray.id, null)"
                              >
                                <span class="text-muted-foreground italic">{{ t('machineDetail.none') }}</span>
                              </button>
                              <button
                                v-for="(p, idx) in filteredProducts"
                                :key="p.id"
                                type="button"
                                tabindex="-1"
                                class="w-full px-3 py-1.5 text-left text-sm hover:bg-accent"
                                :class="{ 'bg-accent': highlightedIndex === idx + 1 }"
                                role="option"
                                @mousedown.prevent="selectProduct(tray.id, p.id)"
                              >
                                {{ p.name }}
                              </button>
                              <div v-if="filteredProducts.length === 0 && productQuery.trim()" class="px-3 py-2 text-xs text-muted-foreground">
                                {{ t('machineDetail.noProductsFound') }}
                              </div>
                            </div>
                          </div>
                          <div v-else class="flex items-center gap-1">
                            <button
                              :id="`product-btn-${tray.id}`"
                              type="button"
                              class="block flex-1 truncate text-left text-sm font-medium transition-colors hover:text-primary"
                              @click="openProductAutocomplete(tray)"
                            >
                              {{ tray.product_name ?? '—' }}
                            </button>
                            <NuxtLink
                              v-if="tray.product_id"
                              :to="`/products/${tray.product_id}`"
                              class="shrink-0 text-muted-foreground transition-colors hover:text-primary"
                              @click.stop
                            >
                              <IconExternalLink class="size-3.5" />
                            </NuxtLink>
                          </div>
                        </template>
                        <NuxtLink
                          v-else-if="tray.product_id"
                          :to="`/products/${tray.product_id}`"
                          class="block truncate text-sm font-medium hover:underline"
                        >
                          {{ tray.product_name ?? '—' }}
                        </NuxtLink>
                        <span v-else class="block truncate text-sm font-medium">{{ tray.product_name ?? '—' }}</span>
                        <div class="flex items-center gap-1.5">
                          <span v-if="trayProductMap.get(tray.item_number)?.sellprice" class="text-xs text-muted-foreground">
                            {{ formatCurrency(trayProductMap.get(tray.item_number)!.sellprice!, locale) }}
                          </span>
                          <span v-if="tray.product_discontinued" class="rounded bg-gray-200 px-1 py-px text-[9px] font-medium text-gray-500 dark:bg-gray-700 dark:text-gray-400">{{ t('warehouse.discontinuedBadge') }}</span>
                        </div>
                      </div>
                      <!-- Actions: Full on mobile (History via swipe right) -->
                      <button
                        v-if="isAdmin"
                        class="inline-flex h-8 shrink-0 items-center rounded-md px-3 text-xs font-medium transition-colors"
                        :class="tray.current_stock < tray.capacity
                          ? 'bg-primary/10 text-primary hover:bg-primary/20'
                          : 'text-muted-foreground cursor-default opacity-50'"
                        :disabled="tray.current_stock >= tray.capacity"
                        @click="handleRefillFull(tray.id)"
                      >
                        {{ t('machineDetail.full') }}
                      </button>
                    </div>
                    <!-- Row 2: level bar -->
                    <div class="relative mt-2 h-2 w-full rounded-full bg-muted">
                      <div
                        class="h-2 rounded-full transition-all"
                        :class="stockColor(tray)"
                        :style="{ width: `${stockPercent(tray)}%` }"
                      />
                      <div
                        v-if="tray.min_stock > 0 && minStockPercent(tray) > 0 && minStockPercent(tray) < 100"
                        class="absolute top-0 h-2 w-0.5 bg-amber-600 dark:bg-amber-400"
                        :style="{ left: `${minStockPercent(tray)}%` }"
                      />
                      <div
                        v-if="tray.fill_when_below > 0 && fillBelowPercent(tray) > 0 && fillBelowPercent(tray) < 100"
                        class="absolute top-0 h-2 w-0.5 bg-blue-500 dark:bg-blue-400"
                        :style="{ left: `${fillBelowPercent(tray)}%` }"
                      />
                    </div>
                    <!-- Row 3: +/- stock controls + info -->
                    <div class="mt-2 flex items-center justify-between">
                      <template v-if="isAdmin">
                        <div class="flex items-center gap-2">
                          <button
                            class="inline-flex h-8 w-8 items-center justify-center rounded-md border text-lg font-medium transition-colors hover:bg-muted active:bg-muted/80"
                            :disabled="tray.current_stock <= 0"
                            :class="tray.current_stock <= 0 ? 'opacity-30' : ''"
                            @click="adjustStock(tray.id, -1)"
                          >
                            −
                          </button>
                          <span class="min-w-[3.5rem] text-center text-sm font-semibold tabular-nums">
                            {{ tray.current_stock }} / {{ tray.capacity }}
                          </span>
                          <button
                            class="inline-flex h-8 w-8 items-center justify-center rounded-md border text-lg font-medium transition-colors hover:bg-muted active:bg-muted/80"
                            :disabled="tray.current_stock >= tray.capacity"
                            :class="tray.current_stock >= tray.capacity ? 'opacity-30' : ''"
                            @click="adjustStock(tray.id, 1)"
                          >
                            +
                          </button>
                        </div>
                      </template>
                      <span v-else class="text-xs text-muted-foreground">{{ tray.current_stock }} / {{ tray.capacity }}</span>
                      <div class="flex items-center gap-2 text-xs text-muted-foreground">
                        <button
                          v-if="isAdmin"
                          type="button"
                          class="inline-flex items-center gap-1 rounded px-1 py-0.5 transition-colors hover:bg-muted active:bg-muted/80"
                          @click="expandedMobileTray = expandedMobileTray === tray.id ? null : tray.id"
                        >
                          <span v-if="tray.min_stock">{{ t('machineDetail.min') }}: {{ tray.min_stock }}</span>
                          <span v-if="tray.fill_when_below">{{ t('machineDetail.fill') }}: {{ tray.fill_when_below }}</span>
                          <span v-if="!tray.min_stock && !tray.fill_when_below" class="italic">{{ t('machineDetail.setThresholds') }}</span>
                          <svg
                            xmlns="http://www.w3.org/2000/svg" class="h-3 w-3 transition-transform" :class="expandedMobileTray === tray.id ? 'rotate-180' : ''"
                            viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
                          ><polyline points="6 9 12 15 18 9" /></svg>
                        </button>
                        <template v-else>
                          <span v-if="tray.min_stock">{{ t('machineDetail.min') }}: {{ tray.min_stock }}</span>
                          <span v-if="tray.fill_when_below">{{ t('machineDetail.fill') }}: {{ tray.fill_when_below }}</span>
                        </template>
                        <span
                          v-if="trayDeficit(tray) > 0 && isLowStock(tray)"
                          class="font-semibold text-red-600 dark:text-red-400"
                        >
                          -{{ trayDeficit(tray) }}
                        </span>
                        <span
                          v-else-if="trayDeficit(tray) > 0 && isFillBelow(tray) && lowStockCount > 0"
                          class="font-semibold text-blue-600 dark:text-blue-400"
                        >
                          -{{ trayDeficit(tray) }}
                        </span>
                      </div>
                    </div>
                    <!-- Expandable thresholds row (mobile, admin only) -->
                    <div
                      v-if="isAdmin && expandedMobileTray === tray.id"
                      class="mt-2 flex items-center gap-4 rounded-md bg-muted/50 px-3 py-2"
                    >
                      <label class="flex items-center gap-1.5 text-xs text-muted-foreground">
                        {{ t('machineDetail.min') }}
                        <input
                          type="number"
                          :value="tray.min_stock"
                          min="0"
                          :max="tray.capacity"
                          class="h-7 w-14 rounded border border-input bg-background px-1.5 text-center text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                          @change="(e: Event) => saveInlineField(tray.id, 'min_stock', parseInt((e.target as HTMLInputElement).value) || 0)"
                        />
                      </label>
                      <label class="flex items-center gap-1.5 text-xs text-muted-foreground">
                        {{ t('machineDetail.fill') }}
                        <input
                          type="number"
                          :value="tray.fill_when_below"
                          min="0"
                          :max="tray.capacity"
                          class="h-7 w-14 rounded border border-input bg-background px-1.5 text-center text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                          @change="(e: Event) => saveInlineField(tray.id, 'fill_when_below', parseInt((e.target as HTMLInputElement).value) || 0)"
                        />
                      </label>
                    </div>
                  </div>
                  </SwipeRight>
                </div>

                <!-- ── Desktop table layout ── -->
                <div class="hidden md:block rounded-md border overflow-visible">
                  <table class="w-full text-sm">
                    <thead>
                      <tr class="border-b bg-muted/50 text-left">
                        <th class="w-20 px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleTraySort('slot')">
                          <SortHeader :icon="traySortIcon('slot')">{{ t('machineDetail.slot') }}</SortHeader>
                        </th>
                        <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleTraySort('product')">
                          <SortHeader :icon="traySortIcon('product')">{{ t('machineDetail.product') }}</SortHeader>
                        </th>
                        <th class="w-36 px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleTraySort('stock')">
                          <SortHeader :icon="traySortIcon('stock')">{{ t('machineDetail.stock') }}</SortHeader>
                        </th>
                        <th class="w-16 px-4 py-3 font-medium">
                          <TooltipProvider>
                            <Tooltip>
                              <TooltipTrigger as-child>
                                <span class="inline-flex cursor-help items-center gap-1">
                                  {{ t('machineDetail.min') }}
                                  <span class="inline-flex h-3.5 w-3.5 items-center justify-center rounded-full bg-muted-foreground/20 text-[9px] font-semibold leading-none text-muted-foreground">i</span>
                                </span>
                              </TooltipTrigger>
                              <TooltipContent>
                                <p class="max-w-48">{{ t('machineDetail.minStockTooltip') }}</p>
                              </TooltipContent>
                            </Tooltip>
                          </TooltipProvider>
                        </th>
                        <th class="w-16 px-4 py-3 font-medium">
                          <TooltipProvider>
                            <Tooltip>
                              <TooltipTrigger as-child>
                                <span class="inline-flex cursor-help items-center gap-1">
                                  {{ t('machineDetail.fill') }}
                                  <span class="inline-flex h-3.5 w-3.5 items-center justify-center rounded-full bg-muted-foreground/20 text-[9px] font-semibold leading-none text-muted-foreground">i</span>
                                </span>
                              </TooltipTrigger>
                              <TooltipContent>
                                <p class="max-w-48">{{ t('machineDetail.fillThresholdTooltip') }}</p>
                              </TooltipContent>
                            </Tooltip>
                          </TooltipProvider>
                        </th>
                        <th class="w-32 px-4 py-3 font-medium">{{ t('machineDetail.level') }}</th>
                        <th v-if="isAdmin" class="w-24 px-4 py-3 font-medium">{{ t('common.actions') }}</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        v-for="tray in sortedTrays"
                        :key="tray.id"
                        class="border-b last:border-0 transition-colors"
                        :class="[
                          isLowStock(tray) ? 'bg-amber-50/60 hover:bg-amber-100/60 dark:bg-amber-950/20 dark:hover:bg-amber-950/40'
                            : isFillBelow(tray) && lowStockCount > 0 ? 'bg-blue-50/40 hover:bg-blue-100/40 dark:bg-blue-950/10 dark:hover:bg-blue-950/20'
                            : 'hover:bg-muted/30',
                          isHealthyInRefillMode(tray) ? 'opacity-40' : '',
                        ]"
                      >
                        <!-- Slot # + price (read-only) -->
                        <td class="px-4 py-2">
                          <span class="font-mono">{{ tray.item_number }}</span>
                          <span v-if="trayProductMap.get(tray.item_number)?.sellprice" class="ml-1 text-xs text-muted-foreground">
                            {{ formatCurrency(trayProductMap.get(tray.item_number)!.sellprice!, locale) }}
                          </span>
                        </td>

                        <!-- Product (inline autocomplete for admins) -->
                        <td class="px-4 py-2 relative">
                          <template v-if="isAdmin">
                            <div v-if="activeAutocompleteTrayId === tray.id" class="relative">
                              <input
                                :id="`product-input-${tray.id}`"
                                v-model="productQuery"
                                type="text"
                                :placeholder="t('machineDetail.searchProducts')"
                                role="combobox"
                                aria-expanded="true"
                                aria-autocomplete="list"
                                autocomplete="off"
                                class="h-8 w-full rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                                @blur="handleProductBlur(tray.id)"
                                @keydown="(e: KeyboardEvent) => handleProductKeydown(e, tray.id)"
                              />
                              <div class="absolute left-0 top-full z-50 mt-1 max-h-48 w-full min-w-[200px] overflow-auto rounded-md border bg-popover shadow-md" role="listbox">
                                <button
                                  type="button"
                                  tabindex="-1"
                                  class="w-full px-3 py-1.5 text-left text-sm hover:bg-accent"
                                  :class="{ 'bg-accent': highlightedIndex === 0 }"
                                  role="option"
                                  @mousedown.prevent="selectProduct(tray.id, null)"
                                >
                                  <span class="text-muted-foreground italic">{{ t('machineDetail.none') }}</span>
                                </button>
                                <button
                                  v-for="(p, idx) in filteredProducts"
                                  :key="p.id"
                                  type="button"
                                  tabindex="-1"
                                  class="w-full px-3 py-1.5 text-left text-sm hover:bg-accent"
                                  :class="{ 'bg-accent': highlightedIndex === idx + 1 }"
                                  role="option"
                                  @mousedown.prevent="selectProduct(tray.id, p.id)"
                                >
                                  {{ p.name }}
                                </button>
                                <div v-if="filteredProducts.length === 0 && productQuery.trim()" class="px-3 py-2 text-xs text-muted-foreground">
                                  {{ t('machineDetail.noProductsFound') }}
                                </div>
                              </div>
                            </div>
                            <div v-else class="flex items-center gap-1">
                              <button
                                :id="`product-btn-${tray.id}`"
                                type="button"
                                class="flex-1 text-left transition-colors hover:text-primary"
                                @click="openProductAutocomplete(tray)"
                                @keydown.enter.prevent="openProductAutocomplete(tray)"
                              >
                                {{ tray.product_name ?? '—' }}
                              </button>
                              <NuxtLink
                                v-if="tray.product_id"
                                :to="`/products/${tray.product_id}`"
                                class="shrink-0 text-muted-foreground transition-colors hover:text-primary"
                                @click.stop
                              >
                                <IconExternalLink class="size-3.5" />
                              </NuxtLink>
                            </div>
                          </template>
                          <NuxtLink
                            v-else-if="tray.product_id"
                            :to="`/products/${tray.product_id}`"
                            class="hover:underline"
                          >
                            {{ tray.product_name ?? '—' }}
                          </NuxtLink>
                          <span v-else>{{ tray.product_name ?? '—' }}</span>
                          <span v-if="tray.product_discontinued" class="ml-1.5 inline-flex items-center rounded bg-gray-200 px-1 py-px text-[9px] font-medium text-gray-500 dark:bg-gray-700 dark:text-gray-400">{{ t('warehouse.discontinuedBadge') }}</span>
                        </td>

                        <!-- Stock (inline editable for admins) -->
                        <td class="px-4 py-2">
                          <template v-if="isAdmin">
                            <div class="flex items-center gap-1">
                              <input
                                :id="`stock-${tray.id}`"
                                type="number"
                                :value="tray.current_stock"
                                min="0"
                                :max="tray.capacity"
                                class="h-7 w-12 rounded border border-transparent bg-transparent px-1 text-center text-sm hover:border-input focus:border-input focus:bg-background focus:shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                                @change="(e: Event) => saveInlineField(tray.id, 'current_stock', parseInt((e.target as HTMLInputElement).value) || 0)"
                                @keydown="(e: KeyboardEvent) => handleStockKeydown(e, tray.id)"
                              />
                              <span class="text-muted-foreground">/</span>
                              <input
                                :id="`capacity-${tray.id}`"
                                type="number"
                                :value="tray.capacity"
                                min="1"
                                class="h-7 w-12 rounded border border-transparent bg-transparent px-1 text-center text-sm hover:border-input focus:border-input focus:bg-background focus:shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                                @change="(e: Event) => saveInlineField(tray.id, 'capacity', parseInt((e.target as HTMLInputElement).value) || 1)"
                                @keydown="(e: KeyboardEvent) => handleCapacityKeydown(e, tray.id)"
                              />
                              <span
                                v-if="trayDeficit(tray) > 0 && isLowStock(tray)"
                                class="ml-1 text-xs font-semibold text-red-600 dark:text-red-400"
                                :title="`${trayDeficit(tray)} items needed to fill`"
                              >
                                -{{ trayDeficit(tray) }}
                              </span>
                              <span
                                v-else-if="trayDeficit(tray) > 0 && isFillBelow(tray) && lowStockCount > 0"
                                class="ml-1 text-xs font-semibold text-blue-600 dark:text-blue-400"
                                :title="`${trayDeficit(tray)} items to top up`"
                              >
                                -{{ trayDeficit(tray) }}
                              </span>
                            </div>
                          </template>
                          <div v-else class="flex items-center gap-1">
                            <span class="text-muted-foreground">{{ tray.current_stock }} / {{ tray.capacity }}</span>
                            <span
                              v-if="trayDeficit(tray) > 0 && isLowStock(tray)"
                              class="ml-1 text-xs font-semibold text-red-600 dark:text-red-400"
                            >
                              -{{ trayDeficit(tray) }}
                            </span>
                            <span
                              v-else-if="trayDeficit(tray) > 0 && isFillBelow(tray) && lowStockCount > 0"
                              class="ml-1 text-xs font-semibold text-blue-600 dark:text-blue-400"
                            >
                              -{{ trayDeficit(tray) }}
                            </span>
                          </div>
                        </td>

                        <!-- Min stock threshold -->
                        <td class="px-4 py-2">
                          <template v-if="isAdmin">
                            <input
                              :id="`min-stock-${tray.id}`"
                              type="number"
                              :value="tray.min_stock"
                              min="0"
                              :max="tray.capacity"
                              class="h-7 w-12 rounded border border-transparent bg-transparent px-1 text-center text-sm hover:border-input focus:border-input focus:bg-background focus:shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                              @change="(e: Event) => saveInlineField(tray.id, 'min_stock', parseInt((e.target as HTMLInputElement).value) || 0)"
                              @keydown="(e: KeyboardEvent) => handleMinStockKeydown(e, tray.id)"
                            />
                          </template>
                          <span v-else class="text-muted-foreground">{{ tray.min_stock || '—' }}</span>
                        </td>

                        <!-- Fill when below threshold -->
                        <td class="px-4 py-2">
                          <template v-if="isAdmin">
                            <input
                              :id="`fill-below-${tray.id}`"
                              type="number"
                              :value="tray.fill_when_below"
                              min="0"
                              :max="tray.capacity"
                              class="h-7 w-12 rounded border border-transparent bg-transparent px-1 text-center text-sm hover:border-input focus:border-input focus:bg-background focus:shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                              @change="(e: Event) => saveInlineField(tray.id, 'fill_when_below', parseInt((e.target as HTMLInputElement).value) || 0)"
                              @keydown="(e: KeyboardEvent) => handleFillBelowKeydown(e, tray.id)"
                            />
                          </template>
                          <span v-else class="text-muted-foreground">{{ tray.fill_when_below || '—' }}</span>
                        </td>

                        <!-- Level bar with threshold markers -->
                        <td class="px-4 py-2">
                          <div class="relative h-2 w-full rounded-full bg-muted">
                            <div
                              class="h-2 rounded-full transition-all"
                              :class="stockColor(tray)"
                              :style="{ width: `${stockPercent(tray)}%` }"
                            />
                            <div
                              v-if="tray.min_stock > 0 && minStockPercent(tray) > 0 && minStockPercent(tray) < 100"
                              class="absolute top-0 h-2 w-0.5 bg-amber-600 dark:bg-amber-400"
                              :style="{ left: `${minStockPercent(tray)}%` }"
                              :title="`Min stock: ${tray.min_stock}`"
                            />
                            <div
                              v-if="tray.fill_when_below > 0 && fillBelowPercent(tray) > 0 && fillBelowPercent(tray) < 100"
                              class="absolute top-0 h-2 w-0.5 bg-blue-500 dark:bg-blue-400"
                              :style="{ left: `${fillBelowPercent(tray)}%` }"
                              :title="`Fill when below: ${tray.fill_when_below}`"
                            />
                          </div>
                        </td>

                        <!-- Actions (Full + History + Remove) -->
                        <td v-if="isAdmin" class="px-4 py-2">
                          <div class="flex items-center gap-2">
                            <button
                              class="inline-flex h-7 items-center rounded px-2 text-xs font-medium transition-colors"
                              :class="tray.current_stock < tray.capacity
                                ? 'bg-primary/10 text-primary hover:bg-primary/20'
                                : 'text-muted-foreground cursor-default opacity-50'"
                              :disabled="tray.current_stock >= tray.capacity"
                              @click="handleRefillFull(tray.id)"
                            >
                              {{ t('machineDetail.full') }}
                            </button>
                            <button
                              class="inline-flex h-7 items-center gap-1 rounded px-2 text-xs font-medium text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                              @click="openStockHistory(tray)"
                            >
                              <IconHistory class="h-3.5 w-3.5" />
                              {{ t('machineDetail.stockHistory') }}
                            </button>
                            <button
                              class="text-xs text-destructive hover:underline"
                              @click="handleDeleteTray(tray.id)"
                            >
                              {{ t('common.remove') }}
                            </button>
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </template>

                <!-- Done navigation (visible in refill mode) -->
                <div v-if="isRefillMode" class="mt-6 flex justify-center">
                  <NuxtLink
                    to="/machines"
                    class="inline-flex h-10 items-center justify-center rounded-md border px-6 text-sm font-medium hover:bg-muted"
                  >
                    &larr; {{ t('machineDetail.doneBackToMachines') }}
                  </NuxtLink>
                </div>
            </TabsContent>

            <!-- ── MDB Diagnostics Tab ── -->
            <TabsContent v-if="isAdmin" value="mdb" class="mt-4 space-y-6">

              <!-- Current MDB Status Card -->
              <div class="rounded-xl border bg-card p-4 sm:p-6">
                <h2 class="mb-4 text-sm font-medium text-muted-foreground uppercase tracking-wide">{{ t('machineDetail.currentMdbStatus') }}</h2>
                <template v-if="machine.embeddeds?.mdb_diagnostics">
                  <div class="grid grid-cols-2 gap-3 sm:gap-4 sm:grid-cols-3 lg:grid-cols-6">
                    <div class="min-w-0">
                      <p class="text-xs text-muted-foreground">{{ t('machineDetail.state') }}</p>
                      <span
                        class="mt-1 inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium"
                        :class="{
                          'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400': stateVariant(machine.embeddeds.mdb_diagnostics.state) === 'destructive',
                          'bg-gray-100 text-gray-800 dark:bg-gray-800 dark:text-gray-300': stateVariant(machine.embeddeds.mdb_diagnostics.state) === 'outline',
                          'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400': stateVariant(machine.embeddeds.mdb_diagnostics.state) === 'secondary',
                          'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400': stateVariant(machine.embeddeds.mdb_diagnostics.state) === 'default',
                        }"
                      >
                        {{ stateLabel(machine.embeddeds.mdb_diagnostics.state) }}
                      </span>
                    </div>
                    <div class="min-w-0">
                      <p class="text-xs text-muted-foreground">{{ t('machineDetail.address') }}</p>
                      <p class="mt-1 text-sm font-mono font-medium truncate">{{ machine.embeddeds.mdb_diagnostics.addr }}</p>
                    </div>
                    <div class="min-w-0">
                      <p class="text-xs text-muted-foreground">{{ t('machineDetail.vmcLevel') }}</p>
                      <p class="mt-1 text-sm font-medium">
                        {{ machine.embeddeds.mdb_diagnostics.vmcLevel ? `Level ${machine.embeddeds.mdb_diagnostics.vmcLevel}` : '–' }}
                      </p>
                    </div>
                    <div class="min-w-0">
                      <p class="text-xs text-muted-foreground">{{ t('machineDetail.polls') }}</p>
                      <p class="mt-1 text-sm font-medium">{{ Number(machine.embeddeds.mdb_diagnostics.polls ?? 0).toLocaleString() }}</p>
                    </div>
                    <div class="min-w-0">
                      <p class="text-xs text-muted-foreground">{{ t('machineDetail.checksumErrors') }}</p>
                      <p class="mt-1 text-sm font-medium" :class="machine.embeddeds.mdb_diagnostics.chkErr > 0 ? 'text-red-500' : ''">
                        {{ machine.embeddeds.mdb_diagnostics.chkErr ?? 0 }}
                      </p>
                    </div>
                    <div class="min-w-0">
                      <p class="text-xs text-muted-foreground">{{ t('machineDetail.lastCommand') }}</p>
                      <p class="mt-1 text-sm font-mono truncate">{{ machine.embeddeds.mdb_diagnostics.lastCmd }}</p>
                    </div>
                  </div>
                  <p class="mt-3 text-xs text-muted-foreground">
                    Updated {{ timeAgo(machine.embeddeds.mdb_diagnostics.updated_at, t) }}
                  </p>
                </template>
                <p v-else class="text-sm text-muted-foreground">
                  {{ t('machineDetail.noMdbDiagnostics') }}
                </p>
              </div>

              <!-- State Change History -->
              <div>
                <h2 class="mb-3 text-sm font-medium text-muted-foreground uppercase tracking-wide">{{ t('machineDetail.stateChangeHistory') }}</h2>

                <div v-if="mdbLogs.length === 0 && !mdbLogsLoading" class="rounded-xl border bg-card p-6 text-center text-sm text-muted-foreground">
                  {{ t('machineDetail.noStateChanges') }}
                </div>

                <div v-else class="space-y-2">
                  <div
                    v-for="entry in mdbLogs"
                    :key="entry.id"
                    class="flex items-center gap-2 sm:gap-3 rounded-lg border bg-card px-3 sm:px-4 py-3"
                  >
                    <!-- State badge -->
                    <span
                      class="inline-flex shrink-0 items-center rounded-full px-2.5 py-0.5 text-xs font-medium"
                      :class="{
                        'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400': stateVariant(entry.state) === 'destructive',
                        'bg-gray-100 text-gray-800 dark:bg-gray-800 dark:text-gray-300': stateVariant(entry.state) === 'outline',
                        'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400': stateVariant(entry.state) === 'secondary',
                        'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400': stateVariant(entry.state) === 'default',
                      }"
                    >
                      {{ stateLabel(entry.state) }}
                    </span>

                    <!-- Transition description -->
                    <div class="min-w-0 flex-1">
                      <p class="text-sm">
                        <template v-if="entry.prev_state">
                          {{ stateLabel(entry.prev_state) }} &rarr; {{ stateLabel(entry.state) }}
                        </template>
                        <template v-else>
                          Initial: {{ stateLabel(entry.state) }}
                        </template>
                      </p>
                      <p class="text-xs text-muted-foreground">
                        <span v-if="entry.last_cmd">Cmd: {{ entry.last_cmd }}</span>
                        <span v-if="entry.last_cmd && entry.polls != null"> · </span>
                        <span v-if="entry.polls != null">{{ entry.polls.toLocaleString() }} polls</span>
                        <span v-if="entry.chk_err"> · {{ entry.chk_err }} errors</span>
                      </p>
                    </div>

                    <!-- Timestamp -->
                    <div class="shrink-0 text-right text-xs text-muted-foreground">
                      <p>{{ timeAgo(entry.created_at, t) }}</p>
                      <p class="tabular-nums">{{ new Date(entry.created_at).toLocaleString() }}</p>
                    </div>
                  </div>
                </div>

                <!-- Load more -->
                <div v-if="mdbHasMore && mdbLogs.length > 0" class="mt-4 text-center">
                  <button
                    class="text-sm text-primary hover:underline disabled:opacity-50"
                    :disabled="mdbLogsLoading"
                    @click="machine.embeddeds?.id && fetchMoreMdbLogs(machine.embeddeds.id)"
                  >
                    {{ mdbLogsLoading ? t('common.loading') : t('history.loadMore') }}
                  </button>
                </div>
              </div>

            </TabsContent>

            <!-- Device Health tab -->
            <TabsContent v-if="machine?.embeddeds" value="health" class="mt-4 space-y-6">
              <!-- Current uptime -->
              <div class="rounded-xl border bg-card p-4 sm:p-6">
                <h2 class="mb-3 text-sm font-medium">{{ t('machineDetail.uptime') }}</h2>
                <div class="flex items-center gap-3">
                  <span
                    class="inline-block h-3 w-3 rounded-full"
                    :class="machine.embeddeds.status === 'online' ? 'bg-green-500' : 'bg-red-500'"
                  />
                  <span v-if="machine.embeddeds.status === 'online' && (machine.embeddeds.online_since || machine.embeddeds.status_at)" class="text-2xl font-semibold tabular-nums">
                    {{ formatUptime(Math.floor((Date.now() - new Date(machine.embeddeds.online_since ?? machine.embeddeds.status_at).getTime()) / 1000)) }}
                  </span>
                  <span v-else class="text-2xl font-semibold text-muted-foreground">{{ t('machineDetail.offline') }}</span>
                </div>
                <p v-if="machine.embeddeds.last_restart_at" class="mt-2 text-xs text-muted-foreground">
                  {{ t('machineDetail.restartReason') }}: {{ reasonLabel(machine.embeddeds.last_restart_reason ?? 'unknown') }}
                  &middot; {{ timeAgo(machine.embeddeds.last_restart_at) }}
                </p>
              </div>

              <!-- Restart history table -->
              <div class="rounded-xl border bg-card p-4 sm:p-6">
                <h2 class="mb-3 text-sm font-medium">{{ t('machineDetail.restartHistory') }}</h2>

                <div v-if="restartsLoading && restarts.length === 0" class="text-sm text-muted-foreground">{{ t('common.loading') }}</div>
                <div v-else-if="restarts.length === 0" class="text-sm text-muted-foreground">{{ t('machineDetail.noRestarts') }}</div>
                <div v-else class="overflow-x-auto">
                  <table class="w-full text-sm">
                    <thead>
                      <tr class="border-b text-left text-xs text-muted-foreground">
                        <th class="pb-2 pr-4 font-medium">{{ t('machineDetail.time') }}</th>
                        <th class="pb-2 pr-4 font-medium">{{ t('machineDetail.restartReason') }}</th>
                        <th class="pb-2 pr-4 font-medium">{{ t('machineDetail.uptimeBefore') }}</th>
                        <th class="pb-2 font-medium">{{ t('machineDetail.firmwareLabel') }}</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr v-for="r in restarts" :key="r.id" class="border-b last:border-0">
                        <td class="py-2 pr-4 text-xs text-muted-foreground whitespace-nowrap">{{ formatDateTime(r.created_at, locale) }}</td>
                        <td class="py-2 pr-4">
                          <Badge :variant="reasonVariant(r.reason)">{{ reasonLabel(r.reason) }}</Badge>
                        </td>
                        <td class="py-2 pr-4 tabular-nums">{{ formatUptime(r.uptime_sec) }}</td>
                        <td class="py-2 text-xs text-muted-foreground">{{ r.firmware_version ?? '—' }}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <div v-if="restartsHasMore" class="mt-3 flex justify-center">
                  <button
                    class="rounded-md border px-3 py-1.5 text-xs text-muted-foreground hover:bg-muted transition-colors"
                    :disabled="restartsLoading"
                    @click="fetchMoreRestarts(machine!.embeddeds!.id)"
                  >
                    {{ restartsLoading ? t('common.loading') : t('history.loadMore') }}
                  </button>
                </div>
              </div>
            </TabsContent>

          </Tabs>
        </template>
      </div>

      <!-- Delete sale confirmation modal -->
      <AppModal v-model:open="showDeleteSaleConfirm" :title="t('machineDetail.deleteSale')" size="sm">
        <p class="text-sm text-muted-foreground">{{ t('machineDetail.deleteSaleConfirm') }}</p>
        <div v-if="deletingSale" class="mt-3 rounded-md border bg-muted/30 p-3 text-sm">
          <div class="flex items-center justify-between">
            <span class="font-medium">{{ saleProduct(deletingSale)?.name ?? `${t('machineDetail.item')} #${deletingSale.item_number}` }}</span>
            <span class="font-medium">{{ formatCurrency(deletingSale.item_price, locale) }}</span>
          </div>
          <p class="mt-1 text-xs text-muted-foreground">{{ formatDateTime(deletingSale.created_at, locale) }}</p>
        </div>
        <div class="mt-4 flex justify-end gap-2">
          <button class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showDeleteSaleConfirm = false">{{ t('common.cancel') }}</button>
          <button
            class="h-9 rounded-md bg-destructive px-4 text-sm font-medium text-destructive-foreground hover:bg-destructive/90 disabled:opacity-50"
            :disabled="deletingSaleLoading"
            @click="handleDeleteSale"
          >
            {{ deletingSaleLoading ? t('common.deleting') : t('common.delete') }}
          </button>
        </div>
      </AppModal>

      <!-- Add sale modal -->
      <AppModal v-model:open="showAddSaleModal" :title="t('machineDetail.addSale')" :description="t('machineDetail.addSaleDescription')" size="sm">
        <form class="flex flex-col gap-3" @submit.prevent="handleAddSale">
          <!-- Slot / Tray select -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('machineDetail.selectSlot') }} *</label>
            <select
              v-model.number="addSaleForm.item_number"
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              required
            >
              <option :value="null" disabled>{{ t('machineDetail.selectSlot') }}</option>
              <option v-for="tray in trays" :key="tray.id" :value="tray.item_number">
                {{ t('machineDetail.slot') }} {{ tray.item_number }} — {{ tray.product_name ?? '—' }}
              </option>
            </select>
          </div>
          <!-- Price -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('machineDetail.price') }} *</label>
            <input
              v-model.number="addSaleForm.item_price"
              type="number"
              step="0.01"
              min="0"
              required
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm tabular-nums focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>
          <!-- Channel -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('machineDetail.saleChannel') }}</label>
            <select
              v-model="addSaleForm.channel"
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option value="cash">{{ t('machineDetail.channelCash') }}</option>
              <option value="cashless">{{ t('machineDetail.channelCashless') }}</option>
              <option value="card">{{ t('machineDetail.channelCard') }}</option>
            </select>
          </div>
          <!-- Date & time -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('machineDetail.saleDate') }}</label>
            <input
              v-model="addSaleForm.created_at"
              type="datetime-local"
              step="1"
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
            <p class="mt-1 text-xs text-muted-foreground">{{ t('machineDetail.saleDateHint') }}</p>
          </div>
          <div class="flex justify-end gap-2 pt-1">
            <button type="button" class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showAddSaleModal = false">{{ t('common.cancel') }}</button>
            <button
              type="submit"
              class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
              :disabled="addSaleLoading || addSaleForm.item_number == null"
            >
              {{ addSaleLoading ? t('common.saving') : t('machineDetail.addSale') }}
            </button>
          </div>
        </form>
      </AppModal>

      <!-- Device info modal -->
      <AppModal v-if="machine?.embeddeds" v-model:open="showDeviceInfoModal" :title="t('machineDetail.deviceDetails')" size="sm">
          <div class="space-y-3 text-sm">
            <!-- Status -->
            <div class="flex justify-between items-center">
              <span class="text-muted-foreground">{{ t('common.status') }}</span>
              <span
                class="rounded-full px-2.5 py-0.5 text-xs font-medium"
                :class="{
                  'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400': machine.embeddeds.status === 'online' || machine.embeddeds.status === 'ota_success',
                  'bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400': machine.embeddeds.status === 'ota_updating',
                  'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400': machine.embeddeds.status === 'ota_failed',
                  'bg-muted text-muted-foreground': !['online', 'ota_updating', 'ota_success', 'ota_failed'].includes(machine.embeddeds.status),
                }"
              >
                {{ machine.embeddeds.status === 'ota_updating' ? t('machineDetail.updating') : machine.embeddeds.status === 'ota_success' ? t('machineDetail.updated') : machine.embeddeds.status === 'ota_failed' ? t('machineDetail.updateFailed') : machine.embeddeds.status === 'online' ? t('machineDetail.online') : machine.embeddeds.status === 'offline' ? t('machineDetail.offline') : machine.embeddeds.status }}
              </span>
            </div>

            <!-- MAC Address -->
            <div class="flex justify-between items-center gap-2">
              <span class="shrink-0 text-muted-foreground">{{ t('machineDetail.macAddress') }}</span>
              <div class="flex items-center gap-2 min-w-0">
                <span class="font-mono text-xs truncate">{{ machine.embeddeds.mac_address ?? '—' }}</span>
                <button
                  v-if="isAdmin"
                  type="button"
                  class="inline-flex h-7 shrink-0 items-center gap-1 rounded-md border px-2 text-xs hover:bg-muted"
                  @click="openSoftapModal"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M5 12.55a11 11 0 0 1 14.08 0"/>
                    <path d="M1.42 9a16 16 0 0 1 21.16 0"/>
                    <path d="M8.53 16.11a6 6 0 0 1 6.95 0"/>
                    <line x1="12" x2="12.01" y1="20" y2="20"/>
                  </svg>
                  {{ t('softap.title') }}
                </button>
              </div>
            </div>

            <!-- Subdomain -->
            <div class="flex justify-between items-center gap-2">
              <span class="shrink-0 text-muted-foreground">{{ t('machineDetail.subdomain') }}</span>
              <span class="font-mono text-xs">{{ machine.embeddeds.subdomain }}</span>
            </div>

            <!-- Firmware -->
            <div class="flex justify-between items-center gap-2">
              <span class="shrink-0 text-muted-foreground">{{ t('machineDetail.firmwareLabel') }}</span>
              <span v-if="machine.embeddeds.firmware_version" class="text-right">
                <span class="font-mono text-xs">v{{ machine.embeddeds.firmware_version }}</span>
                <span v-if="machine.embeddeds.firmware_build_date" class="block text-xs text-muted-foreground">
                  {{ t('settings.built') }} {{ formatDate(machine.embeddeds.firmware_build_date, locale) }}
                </span>
              </span>
              <span v-else class="text-xs text-muted-foreground">—</span>
            </div>

            <!-- Last seen -->
            <div class="flex justify-between items-center">
              <span class="text-muted-foreground">{{ t('machineDetail.lastSeen') }}</span>
              <span class="text-xs">{{ formatDateTime(machine.embeddeds.status_at, locale) }}</span>
            </div>

            <!-- MDB Address -->
            <div class="flex justify-between items-center gap-2">
              <span class="shrink-0 text-muted-foreground">{{ t('machineDetail.mdbAddress') }}</span>
              <template v-if="isAdmin">
                <div class="flex items-center gap-2">
                  <div class="inline-flex rounded-md border">
                    <button
                      class="px-2.5 py-1 text-xs font-medium transition-colors rounded-l-md"
                      :class="((machine.embeddeds as any).mdb_address ?? 1) === 1
                        ? 'bg-primary text-primary-foreground'
                        : 'hover:bg-muted'"
                      :disabled="mdbAddressLoading"
                      @click="setMdbAddress(1)"
                    >
                      #1 (0x10)
                    </button>
                    <button
                      class="px-2.5 py-1 text-xs font-medium transition-colors rounded-r-md border-l"
                      :class="(machine.embeddeds as any).mdb_address === 2
                        ? 'bg-primary text-primary-foreground'
                        : 'hover:bg-muted'"
                      :disabled="mdbAddressLoading"
                      @click="setMdbAddress(2)"
                    >
                      #2 (0x60)
                    </button>
                  </div>
                  <span v-if="mdbAddressLoading" class="text-xs text-muted-foreground">...</span>
                </div>
              </template>
              <span v-else class="text-xs font-medium">
                #{{ (machine.embeddeds as any).mdb_address ?? 1 }} ({{ ((machine.embeddeds as any).mdb_address ?? 1) === 1 ? '0x10' : '0x60' }})
              </span>
            </div>
            <FormError :message="mdbAddressError" />
          </div>

          <!-- Actions -->
          <div v-if="isAdmin" class="mt-5 space-y-3 border-t pt-4">
            <div class="flex gap-2">
              <button
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md border text-sm font-medium transition-colors hover:bg-muted"
                @click="showDeviceInfoModal = false; openDeviceModal()"
              >
                {{ t('machineDetail.changeDevice') }}
              </button>
              <button
                class="inline-flex h-9 items-center justify-center rounded-md px-4 text-sm font-medium text-destructive transition-colors hover:bg-destructive/10"
                :disabled="deviceSwapLoading"
                @click="detachDevice(); showDeviceInfoModal = false"
              >
                {{ t('machineDetail.detach') }}
              </button>
            </div>
            <button
              class="inline-flex h-9 w-full items-center justify-center gap-2 rounded-md border text-sm font-medium transition-colors hover:bg-muted disabled:opacity-50"
              :disabled="restartLoading"
              @click="restartDevice"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16"/><path d="M16 16h5v5"/></svg>
              {{ restartLoading ? t('common.loading') : t('machineDetail.restartDevice') }}
            </button>
          </div>
      </AppModal>

      <!-- Device swap/assign modal -->
      <AppModal v-model:open="showDeviceModal" :title="machine?.embeddeds ? t('machineDetail.changeDevice') : t('machineDetail.assignDevice')" :description="t('machineDetail.selectDevice')" size="sm">
          <form class="space-y-4" @submit.prevent="submitDeviceSwap">
            <div class="space-y-1">
              <label class="text-sm font-medium" for="device-select">{{ t('machineDetail.availableDevices') }}</label>
              <select
                id="device-select"
                v-model="selectedDeviceId"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              >
                <option value="" disabled>{{ t('machineDetail.selectADevice') }}</option>
                <option v-for="d in availableDevices" :key="d.id" :value="d.id">
                  {{ d.mac_address ?? 'Unknown MAC' }} — subdomain {{ d.subdomain }} ({{ d.status }}{{ d.firmware_version ? `, v${d.firmware_version}` : '' }})
                </option>
              </select>
              <p v-if="availableDevices.length === 0" class="text-xs text-muted-foreground">{{ t('machineDetail.noUnassignedDevices') }}</p>
            </div>
            <FormError :message="deviceSwapError" />
            <div class="flex gap-2">
              <button
                type="button"
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
                @click="showDeviceModal = false"
              >
                {{ t('common.cancel') }}
              </button>
              <button
                type="submit"
                :disabled="deviceSwapLoading || !selectedDeviceId"
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
              >
                <span v-if="deviceSwapLoading">{{ t('machineDetail.assigning') }}</span>
                <span v-else>{{ t('common.assign') }}</span>
              </button>
            </div>
          </form>
      </AppModal>

      <!-- Add Tray modal -->
      <AppModal v-model:open="trayModal.open.value" :title="t('machineDetail.addTray')" size="sm">
          <form class="space-y-4" @submit.prevent="submitTray">
            <div class="space-y-1">
              <label class="text-sm font-medium" for="tray-slot">{{ t('machineDetail.slot') }}</label>
              <input
                id="tray-slot"
                v-model.number="trayModal.form.value.item_number"
                type="number"
                min="0"
                required
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <div class="space-y-1">
              <label class="text-sm font-medium">{{ t('machineDetail.product') }}</label>
              <ProductCombobox
                v-model="trayModal.form.value.product_id"
                :products="products"
                :placeholder="t('machineDetail.selectProduct')"
              />
            </div>
            <div class="space-y-1">
              <label class="text-sm font-medium" for="tray-capacity">{{ t('machineDetail.capacity') }}</label>
              <input
                id="tray-capacity"
                v-model.number="trayModal.form.value.capacity"
                type="number"
                min="1"
                required
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <div class="space-y-1">
              <label class="text-sm font-medium" for="tray-stock">{{ t('machineDetail.currentStock') }}</label>
              <input
                id="tray-stock"
                v-model.number="trayModal.form.value.current_stock"
                type="number"
                min="0"
                :max="trayModal.form.value.capacity"
                required
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <FormError :message="trayModal.error.value" />
            <div class="flex gap-2">
              <button
                type="button"
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
                @click="trayModal.closeModal()"
              >
                {{ t('common.cancel') }}
              </button>
              <button
                type="submit"
                :disabled="trayModal.loading.value"
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
              >
                <span v-if="trayModal.loading.value">{{ t('common.creating') }}</span>
                <span v-else>{{ t('common.create') }}</span>
              </button>
            </div>
          </form>
      </AppModal>

      <!-- Batch add trays modal -->
      <AppModal v-model:open="batchModal.open.value" :title="t('machineDetail.batchAddTrays')" :description="t('machineDetail.batchDescription')" size="sm">
          <form class="space-y-4" @submit.prevent="submitBatch">
            <div class="space-y-1">
              <label class="text-sm font-medium" for="batch-start">{{ t('machineDetail.startingSlot') }}</label>
              <input
                id="batch-start"
                v-model.number="batchModal.form.value.startSlot"
                type="number"
                min="0"
                required
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <div class="space-y-1">
              <label class="text-sm font-medium" for="batch-count">{{ t('machineDetail.numberOfTrays') }}</label>
              <input
                id="batch-count"
                v-model.number="batchModal.form.value.count"
                type="number"
                min="1"
                max="100"
                required
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <div class="space-y-1">
              <label class="text-sm font-medium" for="batch-capacity">{{ t('machineDetail.capacityPerTray') }}</label>
              <input
                id="batch-capacity"
                v-model.number="batchModal.form.value.capacity"
                type="number"
                min="1"
                required
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <p class="text-xs text-muted-foreground">
              {{ t('machineDetail.batchSlots', { start: batchModal.form.value.startSlot, end: batchModal.form.value.startSlot + batchModal.form.value.count - 1 }) }}
            </p>
            <FormError :message="batchModal.error.value" />
            <div class="flex gap-2">
              <button
                type="button"
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
                @click="batchModal.closeModal()"
              >
                {{ t('common.cancel') }}
              </button>
              <button
                type="submit"
                :disabled="batchModal.loading.value"
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
              >
                <span v-if="batchModal.loading.value">{{ t('common.creating') }}</span>
                <span v-else>{{ t('machineDetail.createCount', { count: batchModal.form.value.count }) }}</span>
              </button>
            </div>
          </form>
      </AppModal>

      <!-- Send credit modal -->
      <AppModal v-model:open="showCreditModal" :title="t('machineDetail.sendCredit')" :description="t('machineDetail.sendCreditDescription', { name: machine?.name ?? '' })" size="sm">
          <form class="space-y-4" @submit.prevent="submitCredit">
            <div class="space-y-1">
              <label class="text-sm font-medium" for="credit-amount">{{ t('machineDetail.creditAmount') }}</label>
              <input
                id="credit-amount"
                v-model="creditAmount"
                type="number"
                step="0.01"
                min="0.01"
                placeholder="1.50"
                required
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <FormError :message="creditError" />
            <p v-if="creditSuccess" class="text-sm text-green-600 dark:text-green-400">{{ creditSuccess }}</p>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-3 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
                @click="showCreditModal = false"
              >
                {{ t('common.close') }}
              </button>
              <button
                type="button"
                :disabled="cancelCreditLoading"
                class="inline-flex h-9 items-center justify-center gap-1.5 rounded-md border border-destructive px-3 text-sm font-medium text-destructive shadow-sm transition-colors hover:bg-destructive/10 disabled:opacity-50"
                @click="cancelCredit"
              >
                <span v-if="cancelCreditLoading">…</span>
                <span v-else>{{ t('machineDetail.cancelCredit') }}</span>
              </button>
              <button
                type="submit"
                :disabled="creditLoading"
                class="inline-flex h-9 flex-1 items-center justify-center gap-1.5 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
              >
                <span v-if="creditLoading">{{ t('machineDetail.sending') }}</span>
                <template v-else>
                  <IconSend class="size-3.5" />
                  {{ t('common.send') }}
                </template>
              </button>
            </div>
          </form>
      </AppModal>

      <!-- AI Insights Sheet -->
      <Sheet v-model:open="insightsOpen">
        <SheetContent side="right" class="w-full sm:max-w-lg overflow-y-auto">
          <SheetHeader>
            <SheetTitle class="flex items-center gap-2">
              <IconSparkles class="size-5 text-primary" />
              {{ t('machineDetail.aiInsights') }}
            </SheetTitle>
            <p v-if="machine" class="text-sm text-muted-foreground">
              {{ t('machineDetail.aiInsightsFor', { name: machine.name }) }}
            </p>
          </SheetHeader>

          <div class="mt-6 space-y-4">
            <!-- Loading -->
            <template v-if="insightsLoading">
              <div class="flex items-center gap-2 text-sm text-muted-foreground">
                <IconLoader2 class="size-4 animate-spin" />
                {{ t('machineDetail.aiLoading') }}
              </div>
              <div class="space-y-3">
                <div v-for="i in 3" :key="i" class="rounded-lg border p-4 space-y-2">
                  <div class="h-4 w-24 animate-pulse rounded bg-muted" />
                  <div class="h-3 w-full animate-pulse rounded bg-muted" />
                  <div class="h-3 w-3/4 animate-pulse rounded bg-muted" />
                </div>
              </div>
            </template>

            <!-- Error -->
            <div v-else-if="insightsError" class="rounded-lg border border-destructive/20 bg-destructive/5 p-4">
              <p class="text-sm text-destructive">{{ t('machineDetail.aiError', { error: insightsError }) }}</p>
            </div>

            <!-- Results -->
            <template v-else-if="insights">
              <!-- Trends -->
              <div v-if="insights.trends && (insights.trends.revenue_change_pct !== null || insights.trends.units_change_pct !== null)" class="flex flex-wrap gap-2">
                <span
                  v-if="insights.trends.revenue_change_pct !== null"
                  class="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium"
                  :class="insights.trends.revenue_change_pct >= 0 ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300' : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'"
                >
                  <svg v-if="insights.trends.revenue_change_pct >= 0" xmlns="http://www.w3.org/2000/svg" class="size-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="18 15 12 9 6 15"/></svg>
                  <svg v-else xmlns="http://www.w3.org/2000/svg" class="size-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
                  {{ insights.trends.revenue_change_pct >= 0 ? '+' : '' }}{{ insights.trends.revenue_change_pct }}%
                  {{ t('machineDetail.aiTrendRevenue', { days: insights.period_days }) }}
                </span>
                <span
                  v-if="insights.trends.units_change_pct !== null"
                  class="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium"
                  :class="insights.trends.units_change_pct >= 0 ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300' : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'"
                >
                  <svg v-if="insights.trends.units_change_pct >= 0" xmlns="http://www.w3.org/2000/svg" class="size-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="18 15 12 9 6 15"/></svg>
                  <svg v-else xmlns="http://www.w3.org/2000/svg" class="size-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
                  {{ insights.trends.units_change_pct >= 0 ? '+' : '' }}{{ insights.trends.units_change_pct }}%
                  {{ t('machineDetail.aiTrendUnits', { days: insights.period_days }) }}
                </span>
              </div>

              <!-- Recommendations -->
              <template v-if="sortedRecommendations(insights.recommendations).length > 0">
                <div
                  v-for="(rec, idx) in sortedRecommendations(insights.recommendations)"
                  :key="idx"
                  class="rounded-lg border p-4 space-y-2"
                >
                  <div class="flex items-center gap-2 flex-wrap">
                    <Badge :variant="priorityVariant(rec.priority)" class="text-xs">
                      {{ rec.priority }}
                    </Badge>
                    <span class="text-xs text-muted-foreground">{{ t(recommendationTypeLabel(rec.type)) }}</span>
                    <span v-if="rec.item_number != null" class="text-xs text-muted-foreground">
                      {{ t('machineDetail.aiSlot', { number: rec.item_number }) }}
                    </span>
                  </div>
                  <p class="text-sm font-medium">{{ rec.title }}</p>
                  <p class="text-sm text-muted-foreground">{{ rec.detail }}</p>
                </div>
              </template>

              <!-- Empty -->
              <div v-else class="rounded-lg border bg-muted/50 p-4 text-center">
                <p class="text-sm text-muted-foreground">{{ t('machineDetail.aiNoRecommendations') }}</p>
              </div>

              <!-- Summary -->
              <div class="rounded-lg border bg-card p-4 space-y-2">
                <h3 class="text-sm font-medium">{{ t('machineDetail.aiSummary') }}</h3>
                <p class="text-sm text-muted-foreground leading-relaxed">{{ insights.summary }}</p>
              </div>

              <!-- Generated timestamp + cache badge + refresh -->
              <div class="flex items-center gap-2">
                <span v-if="insights.cached" class="inline-flex items-center rounded-full bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
                  {{ t('machineDetail.aiCached') }}
                </span>
                <p class="flex-1 text-xs text-muted-foreground">
                  {{ t('machineDetail.aiGenerated', { time: timeAgo(insights.generated_at, t) }) }}
                </p>
                <button
                  class="inline-flex h-7 items-center gap-1.5 rounded-md border px-2.5 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                  :title="t('machineDetail.aiRefresh')"
                  @click="refreshInsights"
                >
                  <IconRefresh class="size-3" />
                  {{ t('machineDetail.aiRefresh') }}
                </button>
              </div>
            </template>

            <!-- Insights History -->
            <div v-if="!insightsLoading && !insightsError" class="mt-6 border-t pt-4">
              <h3 class="mb-3 text-sm font-medium">{{ t('machineDetail.aiHistory') }}</h3>
              <div v-if="insightsHistoryLoading" class="space-y-2">
                <div v-for="i in 3" :key="i" class="h-12 animate-pulse rounded-lg bg-muted" />
              </div>
              <div v-else-if="insightsHistory.length === 0" class="text-sm text-muted-foreground">
                {{ t('machineDetail.aiHistoryEmpty') }}
              </div>
              <div v-else class="space-y-2">
                <div
                  v-for="entry in insightsHistory"
                  :key="entry.id"
                  class="rounded-lg border"
                >
                  <button
                    class="flex w-full items-center justify-between px-3 py-2.5 text-left text-sm transition-colors hover:bg-muted/50"
                    @click="toggleHistoryEntry(entry.id)"
                  >
                    <span class="text-muted-foreground">{{ new Date(entry.generated_at).toLocaleDateString() }}</span>
                    <div class="flex items-center gap-2">
                      <span class="text-xs text-muted-foreground">{{ (entry.recommendations ?? []).length }} {{ t('machineDetail.aiHistoryRecs') }}</span>
                      <svg
                        xmlns="http://www.w3.org/2000/svg" class="size-3.5 text-muted-foreground transition-transform"
                        :class="{ 'rotate-180': historyExpanded === entry.id }"
                        viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
                      ><polyline points="6 9 12 15 18 9"/></svg>
                    </div>
                  </button>
                  <div v-if="historyExpanded === entry.id" class="border-t px-3 py-3 space-y-2">
                    <p class="text-sm text-muted-foreground leading-relaxed">{{ entry.summary }}</p>
                    <div
                      v-for="(rec, idx) in sortedRecommendations(entry.recommendations ?? [])"
                      :key="idx"
                      class="flex items-start gap-2 text-xs"
                    >
                      <Badge :variant="priorityVariant(rec.priority)" class="mt-0.5 shrink-0 text-[10px]">{{ rec.priority }}</Badge>
                      <span class="text-muted-foreground">{{ rec.title }}</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </SheetContent>
      </Sheet>

      <!-- Stock History Sheet -->
      <Sheet v-model:open="stockHistoryOpen" @update:open="(v: boolean) => { if (!v) closeStockHistory() }">
        <SheetContent side="right" class="w-full sm:max-w-lg overflow-y-auto">
          <SheetHeader>
            <SheetTitle class="flex items-center gap-2">
              <IconHistory class="h-5 w-5" />
              {{ t('machineDetail.stockHistory') }}
            </SheetTitle>
            <p v-if="stockHistoryTray" class="text-sm text-muted-foreground">
              {{ t('machineDetail.slot') }} #{{ stockHistoryTray.item_number }}
              <span v-if="stockHistoryTray.product_name"> &middot; {{ stockHistoryTray.product_name }}</span>
            </p>
          </SheetHeader>

          <div class="mt-4 space-y-3 px-4">
            <div v-if="stockHistoryLoading" class="py-8 text-center text-sm text-muted-foreground">
              <IconLoader2 class="mx-auto h-5 w-5 animate-spin" />
              <p class="mt-2">{{ t('common.loading') }}</p>
            </div>

            <div v-else-if="stockHistoryEntries.length === 0" class="py-8 text-center text-sm text-muted-foreground">
              {{ t('machineDetail.noStockHistory') }}
            </div>

            <template v-else>
              <div v-for="group in groupedStockHistory" :key="group.date" class="space-y-2">
                <!-- Date header -->
                <h4 class="sticky top-0 z-10 text-xs font-semibold uppercase tracking-wider text-muted-foreground bg-background py-1">
                  {{ group.label }}
                </h4>
                <div
                  v-for="entry in group.entries"
                  :key="entry.id"
                  class="flex items-start gap-3 rounded-lg border px-3 py-2.5"
                  :class="{
                    'border-red-200 bg-red-50/50 dark:border-red-800 dark:bg-red-950/20': entry.type === 'decrement_failed',
                  }"
                >
                  <!-- Icon -->
                  <div class="mt-0.5 shrink-0">
                    <span
                      v-if="entry.type === 'sale'"
                      class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400"
                    >
                      <IconCoins class="h-3.5 w-3.5" />
                    </span>
                    <span
                      v-else-if="entry.type === 'manual_change' && entry.new_stock != null && entry.old_stock != null && entry.new_stock > entry.old_stock"
                      class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-400"
                    >
                      <IconArrowUp class="h-3.5 w-3.5" />
                    </span>
                    <span
                      v-else-if="entry.type === 'manual_change' && entry.new_stock != null && entry.old_stock != null && entry.new_stock < entry.old_stock"
                      class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"
                    >
                      <IconArrowDown class="h-3.5 w-3.5" />
                    </span>
                    <span
                      v-else-if="entry.type === 'manual_change'"
                      class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400"
                    >
                      <IconRefresh class="h-3.5 w-3.5" />
                    </span>
                    <span
                      v-else-if="entry.type === 'decrement_failed'"
                      class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"
                    >
                      <IconTrash class="h-3.5 w-3.5" />
                    </span>
                  </div>

                  <!-- Content -->
                  <div class="min-w-0 flex-1">
                    <!-- Sale -->
                    <template v-if="entry.type === 'sale'">
                      <p class="text-sm font-medium">{{ t('machineDetail.stockHistorySale') }}</p>
                      <p class="text-xs text-muted-foreground">
                        {{ formatCurrency(entry.item_price ?? 0, locale) }}
                        &middot; {{ entry.channel === 'cash' ? t('machineDetail.channelCash') : entry.channel === 'card' ? t('machineDetail.channelCard') : t('machineDetail.channelCashless') }}
                      </p>
                    </template>

                    <!-- Manual change -->
                    <template v-else-if="entry.type === 'manual_change'">
                      <p class="text-sm font-medium">
                        <template v-if="entry.action === 'stock_refill_all'">{{ t('machineDetail.stockHistoryRefillAll') }}</template>
                        <template v-else-if="entry.source === 'refill_wizard'">{{ t('activity.sourceRefill') }}</template>
                        <template v-else-if="entry.source === 'refill_full'">{{ t('activity.sourceRefillFull') }}</template>
                        <template v-else>{{ t('machineDetail.stockHistoryManual') }}</template>
                      </p>
                      <p v-if="entry.old_stock != null && entry.new_stock != null" class="text-xs">
                        <span
                          class="inline-flex items-center gap-0.5 font-medium"
                          :class="{
                            'text-emerald-700 dark:text-emerald-400': entry.new_stock > entry.old_stock,
                            'text-red-700 dark:text-red-400': entry.new_stock < entry.old_stock,
                            'text-muted-foreground': entry.new_stock === entry.old_stock,
                          }"
                        >
                          {{ entry.old_stock }}
                          <span v-if="entry.new_stock > entry.old_stock">&uarr;</span>
                          <span v-else-if="entry.new_stock < entry.old_stock">&darr;</span>
                          <span v-else>&rarr;</span>
                          {{ entry.new_stock }}
                          <span class="ml-0.5 text-[10px] opacity-75">({{ entry.new_stock > entry.old_stock ? '+' : '' }}{{ entry.new_stock - entry.old_stock }})</span>
                        </span>
                        <span v-if="entry.user_display" class="text-muted-foreground"> &middot; {{ entry.user_display }}</span>
                      </p>
                      <p v-else-if="entry.user_display" class="text-xs text-muted-foreground">
                        {{ entry.user_display }}
                      </p>
                    </template>

                    <!-- Decrement failed -->
                    <template v-else-if="entry.type === 'decrement_failed'">
                      <p class="text-sm font-medium text-red-600 dark:text-red-400">{{ t('machineDetail.stockHistoryDecrementFailed') }}</p>
                      <p class="text-xs text-muted-foreground">
                        {{ entry.reason === 'no_machine_for_device' ? t('machineDetail.stockHistoryNoMachine') : t('machineDetail.stockHistoryNoTray') }}
                        <span v-if="entry.item_price"> &middot; {{ formatCurrency(entry.item_price, locale) }}</span>
                      </p>
                    </template>
                  </div>

                  <!-- Timestamp (time with seconds) -->
                  <span class="shrink-0 text-xs tabular-nums text-muted-foreground">
                    {{ formatTime(entry.created_at, locale) }}
                  </span>
                </div>
              </div>
            </template>
          </div>
        </SheetContent>
      </Sheet>

      <MachineSettingsModal
        v-if="machine"
        v-model:open="showMachineSettingsModal"
        :machine-id="machine.id"
        :public-listing="machine.public_listing !== false"
        :initial="{
          location_lat: machine.location_lat,
          location_lon: machine.location_lon,
          address_street: (machine as any).address_street ?? null,
          address_house_number: (machine as any).address_house_number ?? null,
          address_postal_code: (machine as any).address_postal_code ?? null,
          address_city: (machine as any).address_city ?? null,
          formatted_address: (machine as any).formatted_address ?? null,
          country_code: machine.country_code,
        }"
        @saved="fetchMachine"
      />

      <SoftApCredentialsModal
        :open="softapModalOpen"
        :device="machine?.embeddeds ? {
          id: (machine.embeddeds as any).id,
          mac_address: (machine.embeddeds as any).mac_address ?? null,
          subdomain: (machine.embeddeds as any).subdomain ?? null,
          softap_password: (machine.embeddeds as any).softap_password ?? null,
        } : null"
        @close="closeSoftapModal"
      />
</template>
