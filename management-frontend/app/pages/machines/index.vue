<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { IconTruck, IconPlayerPlay, IconArrowsExchange, IconRefresh, IconPrinter } from '@tabler/icons-vue'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import { reasonLabel } from '@/composables/useDeviceRestarts'
import { formatCurrency } from '@/lib/utils'
import { getProductImageUrl } from '@/composables/useProducts'
import { hasSavedTour, clearSavedTourState } from '@/composables/useRefillWizard'
import LocationPicker, { type LocationModel } from '~/components/LocationPicker.vue'
import { usePosterFreshness } from '@/composables/usePosterFreshness'

const { t, locale } = useI18n()
const { organization } = useOrganization()
const {
  machines, loading, fetchMachines, subscribeToStatusUpdates, createMachine,
} = useMachines()
const { onResume } = useAppResume()
const savedTourAvailable = ref(false)

onMounted(() => { savedTourAvailable.value = hasSavedTour() })

function startNewTour() {
  clearSavedTourState()
  savedTourAvailable.value = false
  navigateTo('/refill')
}

// Re-fetch all machine data when app resumes from background (iOS PWA etc.)
onResume(() => fetchMachines())
usePullToRefresh(() => fetchMachines())

// Signs whose contact data has drifted since they were printed. Loaded
// separately from the machine list: it is a cheap, independent lookup and must
// not delay the numbers people actually came for.
const posters = usePosterFreshness()

onMounted(async () => {
  await fetchMachines()
  posters.load()
  const unsubscribe = subscribeToStatusUpdates()
  onUnmounted(unsubscribe)
})

// ── Search & Sorting ─────────────────────────────────────────────────────────
import { fuzzyFilter } from '@/lib/fuzzySearch'

const machineSearch = ref('')
const machineSortKey = ref<'name' | 'todayRevenue' | 'monthRevenue' | 'stockHealth'>('name')

const sortedMachines = computed(() => {
  const filtered = fuzzyFilter(machines.value, machineSearch.value, [
    m => m.name,
  ])
  const key = machineSortKey.value
  return [...filtered].sort((a, b) => {
    if (key === 'name') return (a.name ?? '').localeCompare(b.name ?? '')
    if (key === 'todayRevenue') return (b.today_revenue ?? 0) - (a.today_revenue ?? 0)
    if (key === 'monthRevenue') return (b.this_month_revenue ?? 0) - (a.this_month_revenue ?? 0)
    // stockHealth: critical > low > fill > ok
    const healthOrder: Record<string, number> = { critical: 0, low: 1, fill: 2, ok: 3 }
    return (healthOrder[a.stock_health ?? 'ok'] ?? 3) - (healthOrder[b.stock_health ?? 'ok'] ?? 3)
  })
})

// ── Add Machine modal ────────────────────────────────────────────────────────
const { open: showMachineModal, form: machineForm, loading: creatingMachine, error: machineError, openModal: openMachineModal, closeModal, submit } = useModalForm({ name: '' })

// Collapsible location section state
const includeLocation = ref(false)
const locationForm = ref<LocationModel>({
  location_lat: null,
  location_lon: null,
  address_street: null,
  address_house_number: null,
  address_postal_code: null,
  address_city: null,
  formatted_address: null,
  country_code: null,
})

watch(showMachineModal, (isOpen) => {
  if (!isOpen) {
    includeLocation.value = false
    locationForm.value = {
      location_lat: null,
      location_lon: null,
      address_street: null,
      address_house_number: null,
      address_postal_code: null,
      address_city: null,
      formatted_address: null,
      country_code: null,
    }
  }
})

// Restart within last 24h = show indicator
function isRecentRestart(restartAt: string): boolean {
  return Date.now() - new Date(restartAt).getTime() < 24 * 60 * 60 * 1000
}
// Restart within last hour = red (very recent)
function isVeryRecentRestart(restartAt: string): boolean {
  return Date.now() - new Date(restartAt).getTime() < 60 * 60 * 1000
}

async function submitCreateMachine() {
  if (!machineForm.value.name.trim()) {
    machineError.value = t('machines.nameRequired')
    return
  }
  const locationPayload = includeLocation.value && locationForm.value.location_lat != null && locationForm.value.location_lon != null
    ? {
        location_lat: locationForm.value.location_lat!,
        location_lon: locationForm.value.location_lon!,
        address_street: locationForm.value.address_street,
        address_house_number: locationForm.value.address_house_number,
        address_postal_code: locationForm.value.address_postal_code,
        address_city: locationForm.value.address_city,
        formatted_address: locationForm.value.formatted_address,
        country_code: locationForm.value.country_code,
      }
    : undefined
  await submit(() => createMachine(machineForm.value.name.trim(), organization.value!.id, locationPayload))
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-4 p-4 md:p-6">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-2xl font-semibold">{{ t('machines.title') }}</h1>
          <div class="flex flex-wrap items-center gap-2">
            <NuxtLink
              v-if="savedTourAvailable"
              to="/refill"
              class="inline-flex h-9 items-center justify-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
            >
              <IconPlayerPlay class="h-4 w-4" />
              {{ t('refill.resumeTour') }}
            </NuxtLink>
            <button
              v-if="machines.some(m => (m.stock_health ?? 'ok') !== 'ok')"
              class="inline-flex h-9 items-center justify-center gap-2 rounded-md border border-primary bg-primary/10 px-4 text-sm font-medium text-primary shadow-sm transition-colors hover:bg-primary/20"
              @click="startNewTour"
            >
              <IconTruck class="h-4 w-4" />
              {{ t('machines.startRefillTour') }}
            </button>
            <button
              class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
              @click="openMachineModal"
            >
              {{ t('machines.addMachine') }}
            </button>
          </div>
        </div>

        <div v-if="loading" class="text-muted-foreground">{{ t('machines.loadingMachines') }}</div>

        <div v-else-if="machines.length === 0" class="text-muted-foreground">
          {{ t('machines.noMachinesYet') }}
        </div>

        <div v-else class="flex flex-col gap-4">
        <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
          <SearchInput v-model="machineSearch" :placeholder="t('common.search') + '...'" class="sm:max-w-xs" />
          <div class="flex items-center gap-2">
          <IconArrowsExchange class="size-4 text-muted-foreground" />
          <select
            v-model="machineSortKey"
            class="h-8 rounded-md border border-input bg-background px-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option value="name">{{ t('common.name') }}</option>
            <option value="todayRevenue">{{ t('common.today') }} ({{ t('common.revenue') }})</option>
            <option value="monthRevenue">{{ t('common.thisMonth') }} ({{ t('common.revenue') }})</option>
            <option value="stockHealth">{{ t('machines.stockHealth') }}</option>
          </select>
          </div>
        </div>
        <div v-if="sortedMachines.length === 0" class="text-sm text-muted-foreground">{{ t('common.noResults') }}</div>
        <div v-else class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
          <NuxtLink
            v-for="machine in sortedMachines"
            :key="machine.id"
            :to="`/machines/${machine.id}`"
            class="block rounded-xl transition-shadow hover:shadow-md"
          >
            <Card class="h-full">
              <CardHeader class="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle class="text-base font-semibold truncate">
                  {{ machine.name ?? t('machines.unnamedMachine') }}
                </CardTitle>
                <div class="ml-2 flex items-center gap-1.5 shrink-0">
                  <!-- Recent restart indicator -->
                  <TooltipProvider v-if="machine.embeddeds?.last_restart_at && isRecentRestart(machine.embeddeds.last_restart_at)">
                    <Tooltip>
                      <TooltipTrigger as-child>
                        <IconRefresh
                          class="h-3.5 w-3.5"
                          :class="isVeryRecentRestart(machine.embeddeds.last_restart_at) ? 'text-red-500' : 'text-amber-500'"
                        />
                      </TooltipTrigger>
                      <TooltipContent>
                        <p class="text-xs">{{ reasonLabel(machine.embeddeds.last_restart_reason ?? 'unknown') }}</p>
                      </TooltipContent>
                    </Tooltip>
                  </TooltipProvider>
                  <!-- Stock health dot -->
                  <span
                    class="inline-block h-3 w-3 rounded-full"
                    :class="{
                      'bg-red-500': (machine.stock_health ?? 'ok') === 'critical',
                      'bg-amber-500': (machine.stock_health ?? 'ok') === 'low',
                      'bg-blue-500': (machine.stock_health ?? 'ok') === 'fill',
                      'bg-green-500': (machine.stock_health ?? 'ok') === 'ok',
                    }"
                  />
                </div>
              </CardHeader>

              <CardContent class="space-y-3">
                <!-- Sales analytics -->
                <div class="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
                  <div class="flex justify-between">
                    <span class="text-muted-foreground">{{ t('common.today') }}</span>
                    <span class="font-medium tabular-nums">{{ formatCurrency(machine.today_revenue ?? 0) }} <span class="text-muted-foreground font-normal">({{ machine.today_sales_count ?? 0 }})</span></span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-muted-foreground">{{ t('common.thisMonth') }}</span>
                    <span class="font-medium tabular-nums">{{ formatCurrency(machine.this_month_revenue ?? 0) }} <span class="text-muted-foreground font-normal">({{ machine.this_month_sales_count ?? 0 }})</span></span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-muted-foreground">{{ t('common.yesterday') }}</span>
                    <span class="font-medium tabular-nums">{{ formatCurrency(machine.yesterday_revenue ?? 0) }} <span class="text-muted-foreground font-normal">({{ machine.yesterday_sales_count ?? 0 }})</span></span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-muted-foreground">{{ t('common.lastMonth') }}</span>
                    <span class="font-medium tabular-nums">{{ formatCurrency(machine.last_month_revenue ?? 0) }} <span class="text-muted-foreground font-normal">({{ machine.last_month_sales_count ?? 0 }})</span></span>
                  </div>
                </div>

                <!-- Printed sign no longer matches the current contact data.
                     A span, not a link: the whole card is already a NuxtLink,
                     and a nested anchor is invalid HTML. The reprint action
                     lives on the detail page this card leads to. -->
                <span
                  v-if="posters.isOutdated(machine.id)"
                  class="inline-flex w-fit items-center gap-1 rounded-md bg-amber-500/10 px-2 py-0.5 text-xs font-semibold text-amber-500"
                >
                  <IconPrinter class="h-3.5 w-3.5" />
                  {{ t('machines.posterOutdated') }}
                </span>

                <!-- Healthy machine with no stock issues at all -->
                <template v-if="(machine.stock_health ?? 'ok') === 'ok' && (machine.no_stock_trays ?? 0) === 0">
                  <p class="text-sm text-muted-foreground">
                    <template v-if="(machine.total_trays ?? 0) > 0">
                      {{ t('machines.allStocked', { count: machine.total_trays }) }}
                    </template>
                    <template v-else>
                      {{ t('machines.noTraysConfigured') }}
                    </template>
                  </p>
                  <p v-if="(machine.empty_slots_with_stock ?? 0) > 0" class="text-xs text-muted-foreground">
                    {{ t('machines.emptySlotsWithStock', { count: machine.empty_slots_with_stock }, machine.empty_slots_with_stock ?? 0) }}
                  </p>
                </template>

                <!-- Machine has stock issues (refillable and/or no-stock) -->
                <template v-else>
                  <!-- "All stocked" context when only no-stock issues remain -->
                  <p v-if="(machine.stock_health ?? 'ok') === 'ok'" class="text-sm text-muted-foreground">
                    {{ t('machines.allStocked', { count: machine.total_trays }) }}
                  </p>

                  <!-- Badges row -->
                  <div class="flex flex-wrap items-center gap-1.5">
                    <span
                      v-if="(machine.empty_trays ?? 0) > 0"
                      class="inline-flex items-center gap-1 rounded-md bg-red-500/10 px-2 py-0.5 text-xs font-semibold text-red-500"
                    >
                      {{ t('machines.outOfStock', { count: machine.empty_trays }) }}
                    </span>
                    <span
                      v-if="(machine.low_trays ?? 0) - (machine.empty_trays ?? 0) > 0"
                      class="inline-flex items-center gap-1 rounded-md bg-amber-500/10 px-2 py-0.5 text-xs font-semibold text-amber-500"
                    >
                      {{ t('machines.refillNeeded', { count: (machine.low_trays ?? 0) - (machine.empty_trays ?? 0) }) }}
                    </span>
                    <span
                      v-if="machine.no_stock_summary?.some(i => i.severity === 'critical')"
                      class="inline-flex items-center gap-1 rounded-md bg-orange-500/10 px-2 py-0.5 text-xs font-semibold text-orange-400"
                    >
                      {{ t('machines.swapNeeded', { count: machine.no_stock_summary!.filter(i => i.severity === 'critical').length }) }}
                    </span>
                    <span
                      v-if="machine.no_stock_summary?.some(i => i.severity !== 'critical')"
                      class="inline-flex items-center rounded-md bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                    >
                      {{ t('machines.noWarehouseStock', { count: machine.no_stock_summary!.filter(i => i.severity !== 'critical').length }) }}
                    </span>
                    <span
                      v-if="(machine.fill_trays ?? 0) > 0"
                      class="inline-flex items-center gap-1 rounded-md bg-blue-500/10 px-2 py-0.5 text-xs font-semibold text-blue-600 dark:text-blue-400"
                    >
                      {{ t('machines.topoffRecommended', { count: machine.fill_trays }) }}
                    </span>
                    <span
                      v-if="(machine.empty_slots_with_stock ?? 0) > 0"
                      class="inline-flex items-center rounded-md bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                    >
                      {{ t('machines.emptySlotsWithStock', { count: machine.empty_slots_with_stock }, machine.empty_slots_with_stock ?? 0) }}
                    </span>
                  </div>

                  <!-- Product list -->
                  <div v-if="(machine.tray_summary?.length ?? 0) > 0 || (machine.no_stock_summary?.length ?? 0) > 0" class="space-y-0.5 text-xs">
                    <!-- Refillable products -->
                    <div
                      v-for="item in machine.tray_summary"
                      :key="'refill-' + item.product_id"
                      class="flex items-center justify-between gap-2"
                    >
                      <div class="flex items-center gap-1.5 min-w-0">
                        <img v-if="item.image_path" :src="getProductImageUrl(item.image_path)" class="size-5 shrink-0 rounded object-cover" alt="" />
                        <span :class="item.severity === 'critical' ? 'text-red-500' : item.severity === 'low' ? 'text-amber-500' : 'text-blue-600 dark:text-blue-400'">
                          {{ item.product_name }} <span class="text-muted-foreground">(-{{ item.deficit }})</span>
                        </span>
                        <span v-if="item.sellprice != null" class="shrink-0 text-muted-foreground tabular-nums">
                          {{ formatCurrency(item.sellprice, locale) }}
                        </span>
                        <span v-if="item.discontinued" class="shrink-0 rounded bg-gray-200 px-1 py-px text-[9px] font-medium text-gray-500 dark:bg-gray-700 dark:text-gray-400">{{ t('warehouse.discontinuedBadge') }}</span>
                      </div>
                      <span v-if="machine.warehouse_tracked" class="shrink-0 text-green-500 text-[10px]">{{ t('machines.inStock') }}</span>
                    </div>
                    <!-- Divider before swap products -->
                    <div
                      v-if="(machine.tray_summary?.length ?? 0) > 0 && machine.no_stock_summary?.some(i => i.severity === 'critical')"
                      class="border-t border-border my-1"
                    />
                    <!-- Swap products (stock=0 + no warehouse) -->
                    <div
                      v-for="item in machine.no_stock_summary?.filter(i => i.severity === 'critical')"
                      :key="'swap-' + item.product_id"
                      class="flex items-center justify-between gap-2"
                    >
                      <div class="flex items-center gap-1.5 min-w-0">
                        <img v-if="item.image_path" :src="getProductImageUrl(item.image_path)" class="size-5 shrink-0 rounded object-cover" alt="" />
                        <span class="text-orange-400">
                          <IconArrowsExchange class="inline h-3 w-3 mr-0.5 -mt-0.5 shrink-0" />
                          {{ item.product_name }} <span class="text-muted-foreground">(-{{ item.deficit }})</span>
                        </span>
                        <span v-if="item.sellprice != null" class="shrink-0 text-muted-foreground tabular-nums">
                          {{ formatCurrency(item.sellprice, locale) }}
                        </span>
                        <span v-if="item.discontinued" class="shrink-0 rounded bg-gray-200 px-1 py-px text-[9px] font-medium text-gray-500 dark:bg-gray-700 dark:text-gray-400">{{ t('warehouse.discontinuedBadge') }}</span>
                      </div>
                      <span class="shrink-0 text-orange-400 text-[10px]">{{ t('machines.swap') }}</span>
                    </div>
                    <!-- No-stock products (low/empty but no warehouse — dimmed) -->
                    <div
                      v-for="item in machine.no_stock_summary?.filter(i => i.severity !== 'critical')"
                      :key="'nostock-' + item.product_id"
                      class="flex items-center justify-between gap-2 opacity-50"
                    >
                      <div class="flex items-center gap-1.5 min-w-0">
                        <img v-if="item.image_path" :src="getProductImageUrl(item.image_path)" class="size-5 shrink-0 rounded object-cover" alt="" />
                        <span>
                          {{ item.product_name }} <span class="text-muted-foreground">(-{{ item.deficit }})</span>
                        </span>
                        <span v-if="item.sellprice != null" class="shrink-0 text-muted-foreground tabular-nums">
                          {{ formatCurrency(item.sellprice, locale) }}
                        </span>
                        <span v-if="item.discontinued" class="shrink-0 rounded bg-gray-200 px-1 py-px text-[9px] font-medium text-gray-500 dark:bg-gray-700 dark:text-gray-400">{{ t('warehouse.discontinuedBadge') }}</span>
                      </div>
                      <span class="shrink-0 text-muted-foreground text-[10px]">{{ t('machines.noStock') }}</span>
                    </div>
                  </div>

                  <!-- Stock bar (only when there are refillable issues) -->
                  <div v-if="(machine.stock_health ?? 'ok') !== 'ok'" class="flex items-center gap-2">
                    <div class="h-2 flex-1 overflow-hidden rounded-full bg-muted">
                      <div
                        class="h-full rounded-full transition-all"
                        :class="{
                          'bg-red-500': (machine.stock_percent ?? 0) < 20,
                          'bg-amber-500': (machine.stock_percent ?? 0) >= 20 && (machine.stock_percent ?? 0) < 50,
                          'bg-green-500': (machine.stock_percent ?? 0) >= 50,
                        }"
                        :style="{ width: `${machine.stock_percent ?? 0}%` }"
                      />
                    </div>
                    <span class="text-xs font-medium text-muted-foreground w-8 text-right">{{ machine.stock_percent ?? 0 }}%</span>
                  </div>
                </template>
              </CardContent>
            </Card>
          </NuxtLink>
        </div>
        </div>
  </div>

  <!-- Add Machine Modal -->
  <AppModal
    v-model:open="showMachineModal"
    :title="t('machines.addMachine')"
    :description="t('machines.addMachineDescription')"
  >
    <div class="mb-4">
      <label for="machine-name" class="mb-1.5 block text-sm font-medium">{{ t('machines.machineName') }}</label>
      <input
        id="machine-name"
        v-model="machineForm.name"
        type="text"
        :placeholder="t('machines.machineNamePlaceholder')"
        class="flex h-9 w-full rounded-md border bg-transparent px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        @keydown.enter="submitCreateMachine"
      />
    </div>
    <div class="mt-4 border-t pt-4">
      <button
        type="button"
        class="flex w-full items-center justify-between text-sm font-medium text-muted-foreground hover:text-foreground"
        @click="includeLocation = !includeLocation"
      >
        <span>{{ t('machineSettings.setLocationOptional') }}</span>
        <span>{{ includeLocation ? '−' : '+' }}</span>
      </button>
      <div v-if="includeLocation" class="mt-3">
        <ClientOnly>
          <LocationPicker v-model="locationForm" />
          <template #fallback>
            <div class="flex h-[200px] w-full items-center justify-center rounded-md border border-dashed text-sm text-muted-foreground">
              {{ t('machineSettings.mapLoading') }}
            </div>
          </template>
        </ClientOnly>
      </div>
    </div>
    <FormError :message="machineError" />
    <template #footer>
      <button
        class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium hover:bg-muted"
        @click="closeModal"
      >
        {{ t('common.cancel') }}
      </button>
      <button
        :disabled="creatingMachine"
        class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
        @click="submitCreateMachine"
      >
        <span v-if="creatingMachine">{{ t('common.creating') }}</span>
        <span v-else>{{ t('common.create') }}</span>
      </button>
    </template>
  </AppModal>

</template>
