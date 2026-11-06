<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Separator } from '@/components/ui/separator'
import { IconArrowLeft, IconCheck, IconDotsVertical, IconNote, IconPlayerSkipForward, IconTruck } from '@tabler/icons-vue'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { getProductImageUrl } from '@/composables/useProducts'
import { useRefillWizard, hasSavedTour } from '@/composables/useRefillWizard'
import { formatCurrency } from '@/lib/utils'
import RefillChangeNote from '@/components/refill/RefillChangeNote.vue'
import RefillRebuildSection from '@/components/refill/RefillRebuildSection.vue'
import RefillPackCard from '@/components/refill/RefillPackCard.vue'
import AppModal from '@/components/AppModal.vue'
import RefillTourLeftovers from '@/components/refill/RefillTourLeftovers.vue'
import RefillTourNotes from '@/components/refill/RefillTourNotes.vue'
import RefillTourNoteDialog from '@/components/refill/RefillTourNoteDialog.vue'

const { t, locale } = useI18n()
const router = useRouter()
const { warehouses, fetchWarehouses } = useWarehouse()

const {
  currentStep, machines, currentMachineIndex, selectedWarehouseId,
  loading, tourStarting, confirmingRefill,
  currentTrays, currentTraysLoading,
  tourLog, tourSummary, currentMachine, totalMachinesInTour, currentMachineNumber,
  completedMachineIds, allMachinesCompleted,
  pickingMode, sortedMachines,
  hasAnyPackedItems, effectiveStockHealth, getWarehouseAvailable,
  initTour, loadWarehouseStock, startTour,
  adjustFillAmount, confirmMachineRefill, confirmError, skipMachine, goToMachine, isMachineCompleted, resetWizard,
  resumeTour,
  packLines, toggleLine, setLineQuantity, allLinesTicked, machinesReady, openPackLines, combinedPackCards,
  maxRebuildFilled, skippedSourceSlots, withdrawnRebuildMachines, rebuildWithdrawnNotice,
  currentRebuild, rebuildReady, returnBatchLabel,
  setRebuildRemoved, setRebuildFilled, setRebuildAction, setRebuildPriceSet, setRebuildAgeSet,
  tourLeftoverRows, hasPendingLeftovers, leftoversReturned, returningLeftovers, returnLeftoversError,
  setLeftoverDestination, setLeftoverExpiry, setLeftoverCount, loadTourExpirySuggestions, returnTourLeftovers,
  tourNotes, completeTourNote, loadTourNote, saveTourNote,
} = useRefillWizard()

// Note for the next tour, written at the current machine.
const noteDialogOpen = ref(false)
const noteDoneError = ref<string | null>(null)
async function onNoteDone(noteId: string) {
  noteDoneError.value = null
  try {
    await completeTourNote(noteId)
  } catch (err: any) {
    noteDoneError.value = err?.message ?? String(err)
  }
}

returnBatchLabel.value = t('refillRebuild.returnBatch')

/** Leave the summary; warn when the rebuild leftovers are not booked back yet. */
function finishTour(to: string) {
  if (hasPendingLeftovers.value && !window.confirm(t('refillRebuild.unbookedConfirm'))) return
  resetWizard()
  router.push(to)
}

// Best-before suggestions for the leftovers once the tour reaches the summary.
watch(currentStep, (step) => {
  if (step === 'summary' && hasPendingLeftovers.value) void loadTourExpirySuggestions()
}, { immediate: true })

// Tour start with lines not in the box: show what stays in the warehouse first.
const openLinesDialog = ref(false)
function onStartTour() {
  if (openPackLines.value.length > 0) openLinesDialog.value = true
  else void startTour()
}

const machinesWithChangeNote = computed(() => machines.value.filter(m => (m.change_request?.items.length ?? 0) > 0))

// Init — auto-resume saved tour if available, otherwise start fresh
onMounted(async () => {
  if (hasSavedTour()) {
    const resumed = await resumeTour()
    if (resumed) return
  }
  await fetchWarehouses()
  if (warehouses.value.length > 0) {
    selectedWarehouseId.value = warehouses.value[0]!.id
  }
  await initTour()
  await loadWarehouseStock()
})

watch(selectedWarehouseId, () => loadWarehouseStock())

function goBack() {
  if (currentStep.value === 'packing') {
    router.push('/machines')
  }
}

// Check if confirming this machine would complete all remaining machines
const wouldFinishTour = computed(() => {
  const remaining = machines.value.filter(m => !isMachineCompleted(m.id))
  return remaining.length <= 1
})

// Current machine already done?
const currentMachineDone = computed(() =>
  currentMachine.value ? isMachineCompleted(currentMachine.value.id) : false
)
</script>

<template>
  <div class="flex flex-1 flex-col gap-3 p-3 pb-0 sm:gap-4 sm:p-4 md:p-6">
    <!-- Header -->
    <div class="flex items-center gap-3">
      <button
        v-if="currentStep === 'packing'"
        class="inline-flex h-10 w-10 items-center justify-center rounded-md border hover:bg-muted"
        @click="goBack"
      >
        <IconArrowLeft class="h-4 w-4" />
      </button>
      <h1 class="text-xl font-semibold sm:text-2xl">{{ t('refill.title') }}</h1>
    </div>

    <!-- Step indicator — compact on mobile -->
    <div class="flex items-center gap-1.5 sm:gap-2 text-sm">
      <span
        class="inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-medium"
        :class="currentStep === 'packing' ? 'bg-primary text-primary-foreground' : currentStep === 'refill' || currentStep === 'summary' ? 'bg-green-600 text-white' : 'bg-muted text-muted-foreground'"
      >
        <IconCheck v-if="currentStep !== 'packing'" class="h-3.5 w-3.5" />
        <template v-else>1</template>
      </span>
      <span class="hidden sm:inline" :class="currentStep === 'packing' ? 'font-medium' : 'text-muted-foreground'">{{ t('refill.packingStep') }}</span>
      <span class="text-muted-foreground mx-0.5">&rarr;</span>
      <span
        class="inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-medium"
        :class="currentStep === 'refill' ? 'bg-primary text-primary-foreground' : currentStep === 'summary' ? 'bg-green-600 text-white' : 'bg-muted text-muted-foreground'"
      >
        <IconCheck v-if="currentStep === 'summary'" class="h-3.5 w-3.5" />
        <template v-else>2</template>
      </span>
      <span class="hidden sm:inline" :class="currentStep === 'refill' ? 'font-medium' : 'text-muted-foreground'">{{ t('refill.refillStep') }}</span>
      <span class="text-muted-foreground mx-0.5">&rarr;</span>
      <span
        class="inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-medium"
        :class="currentStep === 'summary' ? 'bg-primary text-primary-foreground' : 'bg-muted text-muted-foreground'"
      >3</span>
      <span class="hidden sm:inline" :class="currentStep === 'summary' ? 'font-medium' : 'text-muted-foreground'">{{ t('refill.summaryStep') }}</span>
    </div>

    <!-- Loading -->
    <div v-if="loading" class="text-muted-foreground">{{ t('common.loading') }}</div>

    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <!-- STEP 1: PACKING -->
    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <template v-else-if="currentStep === 'packing'">
      <!-- No machines need refill -->
      <div v-if="machines.length === 0" class="text-muted-foreground py-8 text-center">
        {{ t('refill.noMachinesNeedRefill') }}
      </div>

      <template v-else>
        <RefillTourNotes v-if="tourNotes.length > 0" :notes="tourNotes" :error="noteDoneError" @done="onNoteDone" />

        <!-- Warehouse selector -->
        <div v-if="warehouses.length > 0" class="flex items-center gap-2 rounded-lg border bg-muted/30 px-3 py-2.5">
          <label class="shrink-0 text-sm text-muted-foreground">{{ t('refill.selectWarehouse') }}</label>
          <select
            v-model="selectedWarehouseId"
            class="h-9 min-w-0 flex-1 rounded-md border border-input bg-background px-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option v-for="wh in warehouses" :key="wh.id" :value="wh.id">{{ wh.name }}</option>
          </select>
        </div>

        <!-- Picking mode toggle -->
        <div class="flex items-center gap-1 rounded-lg border p-1">
          <button
            class="flex-1 rounded-md px-3 py-1.5 text-sm font-medium transition-colors"
            :class="pickingMode === 'per-machine' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'"
            @click="pickingMode = 'per-machine'"
          >
            {{ t('refill.perMachine') }}
          </button>
          <button
            class="flex-1 rounded-md px-3 py-1.5 text-sm font-medium transition-colors"
            :class="pickingMode === 'combined' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'"
            @click="pickingMode = 'combined'"
          >
            {{ t('refill.combined') }}
          </button>
        </div>

        <!-- ── COMBINED PICKING MODE ──────────────────────────────────── -->
        <!-- One card per product, one line per machine: refill and rebuild
             units of a machine share one tick ("in the box") and one amount. -->
        <div v-if="pickingMode === 'combined'" class="flex flex-col gap-3 pb-28 sm:pb-32">
          <RefillChangeNote
            v-for="machine in machinesWithChangeNote"
            :key="`note-${machine.id}`"
            :items="machine.change_request!.items"
            :machine-name="machine.name"
          />
          <RefillPackCard
            v-for="card in combinedPackCards"
            :key="card.product_id"
            :product-name="card.product_name"
            :image-path="card.image_path"
            :sellprice="card.sellprice"
            :lines="card.lines"
            :stock="getWarehouseAvailable({ product_id: card.product_id })"
            show-machines
            @toggle="toggleLine($event.machine_id, $event.product_id)"
            @set="(line, v) => setLineQuantity(line.machine_id, line.product_id, v)"
          />
        </div>

        <!-- ── PER-MACHINE PICKING MODE ───────────────────────────────── -->
        <div v-else class="flex flex-col gap-3 pb-28 sm:pb-32 md:grid md:grid-cols-2 xl:grid-cols-3 md:gap-4">
          <Card
            v-for="machine in sortedMachines"
            :key="machine.id"
            class="h-full"
            :class="effectiveStockHealth(machine) === 'ok' && !machine.change_request ? 'opacity-40' : ''"
          >
            <CardHeader class="flex flex-row items-center justify-between space-y-0 pb-2 px-4 sm:px-6">
              <CardTitle class="text-base font-semibold truncate">
                {{ machine.name }}
              </CardTitle>
              <span class="ml-2 flex shrink-0 items-center gap-2">
                <span v-if="allLinesTicked(machine)" class="text-xs font-medium text-green-600">{{ t('refill.allPacked') }}</span>
                <span
                  class="inline-block h-3 w-3 rounded-full"
                  :class="{
                    'bg-red-500': effectiveStockHealth(machine) === 'critical',
                    'bg-amber-500': effectiveStockHealth(machine) === 'low',
                    'bg-blue-500': effectiveStockHealth(machine) === 'fill',
                    'bg-green-500': effectiveStockHealth(machine) === 'ok',
                  }"
                />
              </span>
            </CardHeader>

            <CardContent v-if="effectiveStockHealth(machine) !== 'ok' || machine.change_request" class="space-y-3 px-4 sm:px-6">
              <RefillChangeNote v-if="machine.change_request" :items="machine.change_request.items" />
              <RefillPackCard
                v-for="line in packLines(machine)"
                :key="line.product_id"
                :product-name="line.product_name"
                :image-path="line.image_path"
                :sellprice="line.sellprice"
                :lines="[line]"
                :stock="getWarehouseAvailable({ product_id: line.product_id })"
                @toggle="toggleLine(machine.id, line.product_id)"
                @set="(l, v) => setLineQuantity(machine.id, l.product_id, v)"
              />
            </CardContent>
          </Card>
        </div>

        <!-- Start Tour — fixed bottom bar on mobile -->
        <div class="fixed bottom-[calc(3.5rem+env(safe-area-inset-bottom))] md:bottom-0 inset-x-0 z-20 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80 p-3 sm:p-4 md:pb-[max(1rem,env(safe-area-inset-bottom))]">
          <div class="mx-auto flex max-w-3xl items-center gap-3">
            <div class="min-w-0 flex-1">
              <p class="text-sm font-medium">{{ t('refillRebuild.machinesReady', { n: machinesReady }, machinesReady) }}</p>
            </div>
            <button
              :disabled="!hasAnyPackedItems() || tourStarting"
              class="inline-flex h-12 shrink-0 items-center justify-center gap-2 rounded-xl bg-primary px-5 text-base font-medium text-primary-foreground shadow-lg transition-colors hover:bg-primary/90 disabled:opacity-50"
              @click="onStartTour"
            >
              <IconTruck v-if="!tourStarting" class="h-5 w-5" />
              <span v-if="tourStarting">{{ t('refill.startingTour') }}</span>
              <span v-else>{{ t('refill.startTour') }}</span>
            </button>
          </div>
        </div>

        <!-- Tour start while lines are not ticked: what stays in the warehouse -->
        <AppModal
          v-model:open="openLinesDialog"
          :title="t('refillRebuild.openLinesTitle', { n: openPackLines.length }, openPackLines.length)"
          :description="t('refillRebuild.openLinesHint')"
        >
          <ul class="divide-y rounded-lg border">
            <li v-for="line in openPackLines" :key="`${line.machine_id}-${line.product_id}`" class="flex items-center gap-3 px-3 py-2.5">
              <img v-if="line.image_path" :src="getProductImageUrl(line.image_path)" alt="" class="size-9 shrink-0 rounded object-cover" />
              <span v-else class="flex size-9 shrink-0 items-center justify-center rounded bg-muted text-xs text-muted-foreground">{{ line.product_name.charAt(0) }}</span>
              <span class="min-w-0 flex-1">
                <span class="block text-sm font-semibold">{{ line.product_name }}</span>
                <span class="block text-xs text-muted-foreground">{{ line.machine_name }}</span>
                <span v-if="line.rebuild > 0" class="block text-xs font-semibold text-violet-700 dark:text-violet-300">
                  ⇄ {{ line.slots.length === 1 ? t('refillRebuild.slotOne', { n: line.slots[0] }) : t('refillRebuild.slotMany', { list: line.slots.join(', ') }) }}
                </span>
              </span>
              <span class="text-lg font-bold tabular-nums">{{ line.total }}</span>
            </li>
          </ul>
          <p v-if="openPackLines.some(l => l.rebuild > 0)" class="mt-3 text-sm text-violet-700 dark:text-violet-300">{{ t('refillRebuild.openLinesRebuildHint') }}</p>
          <div class="mt-4 flex flex-col gap-2">
            <button class="inline-flex h-12 items-center justify-center rounded-xl bg-primary px-4 font-medium text-primary-foreground" @click="openLinesDialog = false">
              {{ t('refillRebuild.keepPacking') }}
            </button>
            <button class="inline-flex h-11 items-center justify-center rounded-xl border px-4 text-sm font-medium hover:bg-muted" @click="openLinesDialog = false; startTour()">
              {{ t('refillRebuild.startWithout') }}
            </button>
          </div>
        </AppModal>
      </template>
    </template>

    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <!-- STEP 2: REFILL PER MACHINE -->
    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <template v-else-if="currentStep === 'refill' && currentMachine">
      <!-- Machine tab bar — horizontal scroll on mobile -->
      <div class="-mx-3 sm:-mx-4 md:-mx-6 px-3 sm:px-4 md:px-6 overflow-x-auto scrollbar-none">
        <div class="flex gap-1.5 min-w-max pb-1">
          <button
            v-for="(machine, idx) in machines"
            :key="machine.id"
            class="relative inline-flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium whitespace-nowrap transition-colors shrink-0"
            :class="idx === currentMachineIndex
              ? 'bg-primary text-primary-foreground shadow-sm'
              : isMachineCompleted(machine.id)
                ? 'bg-green-100 text-green-700 dark:bg-green-950/40 dark:text-green-400 hover:bg-green-200 dark:hover:bg-green-950/60'
                : 'bg-muted/60 text-muted-foreground hover:bg-muted'"
            @click="goToMachine(idx)"
          >
            <IconCheck v-if="isMachineCompleted(machine.id)" class="h-3.5 w-3.5 shrink-0" />
            <span
              v-else
              class="inline-flex h-5 w-5 items-center justify-center rounded-full text-[11px] font-bold shrink-0"
              :class="idx === currentMachineIndex ? 'bg-primary-foreground/20' : 'bg-background/50'"
            >{{ idx + 1 }}</span>
            <span class="truncate max-w-[8rem]">{{ machine.name }}</span>
          </button>
        </div>
      </div>

      <!-- Progress summary -->
      <div class="flex items-center justify-between text-sm text-muted-foreground px-1">
        <span>{{ completedMachineIds.size }} / {{ machines.length }} {{ t('refill.completed') }}</span>
        <div class="flex items-center gap-2">
          <div class="h-1.5 w-16 sm:w-24 overflow-hidden rounded-full bg-muted">
            <div
              class="h-full rounded-full bg-green-500 transition-all"
              :style="{ width: `${Math.round((completedMachineIds.size / machines.length) * 100)}%` }"
            />
          </div>
        </div>
      </div>

      <div v-if="rebuildWithdrawnNotice" class="flex items-start gap-3 rounded-lg border border-orange-500/50 bg-orange-500/10 p-3 text-sm">
        <p class="min-w-0 flex-1">
          <b class="block">{{ t('refillRebuild.withdrawnTitle') }}</b>
          {{ t('refillRebuild.withdrawnNotice', { machine: rebuildWithdrawnNotice }) }}
        </p>
        <button class="shrink-0 rounded-md border px-3 py-1.5 text-xs font-medium hover:bg-muted" @click="rebuildWithdrawnNotice = null">{{ t('common.close') }}</button>
      </div>

      <div v-if="currentTraysLoading" class="text-muted-foreground px-1">{{ t('common.loading') }}</div>

      <div v-else-if="currentTrays.length === 0 && currentRebuild.length === 0" class="text-muted-foreground text-sm px-1">
        {{ t('refill.noMachinesNeedRefill') }}
      </div>

      <!-- Tray cards — mobile-friendly card layout instead of table -->
      <div v-else class="flex flex-col gap-2 pb-28 sm:pb-32">
        <RefillRebuildSection
          v-if="currentRebuild.length > 0 && !currentMachineDone"
          :slots="currentRebuild"
          :max-filled="maxRebuildFilled"
          :skipped-sources="skippedSourceSlots"
          :withdrawn="withdrawnRebuildMachines.has(currentMachine.id)"
          @removed="setRebuildRemoved"
          @filled="setRebuildFilled"
          @action="setRebuildAction"
          @price="setRebuildPriceSet"
          @age="setRebuildAgeSet"
        />
        <div
          v-for="tray in currentTrays"
          :key="tray.id"
          class="rounded-xl border bg-card p-3 sm:p-4"
        >
          <div class="flex items-center justify-between gap-3">
            <!-- Left: image + product -->
            <div class="flex items-center gap-3 min-w-0 flex-1">
              <img
                v-if="tray.image_path"
                :src="getProductImageUrl(tray.image_path)"
                :alt="tray.product_name ?? ''"
                class="h-10 w-10 shrink-0 rounded-lg object-cover"
              />
              <span
                v-else
                class="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-muted font-mono text-xs font-medium"
              >
                {{ tray.item_number }}
              </span>
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium truncate">
                  <span class="text-muted-foreground font-mono text-xs mr-1">#{{ tray.item_number }}</span>
                  {{ tray.product_name ?? `Slot ${tray.item_number}` }}
                </p>
                <p class="text-xs text-muted-foreground tabular-nums flex items-center gap-1.5 flex-wrap">
                  <span
                    class="inline-flex items-center rounded px-1 py-0.5 text-[11px] font-medium"
                    :class="tray.current_stock === 0
                      ? 'bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-400'
                      : 'bg-amber-100 text-amber-700 dark:bg-amber-950/40 dark:text-amber-400'"
                  >{{ tray.current_stock }}</span>
                  <span>/</span>
                  <span>{{ tray.capacity }}</span>
                  <span v-if="tray.sellprice != null" class="ml-1 font-medium text-foreground/80">
                    {{ formatCurrency(tray.sellprice, locale) }}
                  </span>
                </p>
              </div>
            </div>

            <!-- Right: fill amount controls — large touch targets -->
            <div class="flex items-center gap-1.5 shrink-0">
              <button
                class="inline-flex h-11 w-11 items-center justify-center rounded-xl border-2 text-lg font-semibold active:bg-muted disabled:opacity-30 transition-colors"
                :disabled="tray.fill_amount <= 0"
                @click="adjustFillAmount(tray.id, -1)"
              >&minus;</button>
              <span class="inline-flex h-11 min-w-14 items-center justify-center rounded-xl bg-primary/10 px-2 text-base font-bold tabular-nums text-primary">
                +{{ tray.fill_amount }}
              </span>
              <button
                class="inline-flex h-11 w-11 items-center justify-center rounded-xl border-2 text-lg font-semibold active:bg-muted disabled:opacity-30 transition-colors"
                :disabled="tray.fill_amount >= (tray.capacity - tray.current_stock)"
                @click="adjustFillAmount(tray.id, 1)"
              >+</button>
            </div>
          </div>
        </div>
      </div>

      <!-- Action buttons — fixed bottom bar -->
      <div class="fixed bottom-[calc(3.5rem+env(safe-area-inset-bottom))] md:bottom-0 inset-x-0 z-20 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80 p-3 sm:p-4 md:pb-[max(1rem,env(safe-area-inset-bottom))]">
        <div class="flex flex-col gap-2 max-w-3xl mx-auto">
          <!-- Already completed: show done state + finish tour option -->
          <template v-if="currentMachineDone">
            <div class="flex items-center justify-center gap-2 h-12 rounded-xl bg-green-100 dark:bg-green-950/40 text-green-700 dark:text-green-400 text-base font-medium">
              <IconCheck class="h-5 w-5" />
              {{ t('refill.alreadyCompleted') }}
            </div>
            <button
              v-if="allMachinesCompleted"
              class="inline-flex h-10 w-full items-center justify-center gap-2 rounded-xl bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
              @click="currentStep = 'summary'"
            >
              {{ t('refill.finishTour') }}
            </button>
          </template>

          <!-- Normal: confirm + skip -->
          <template v-else>
            <div
              v-if="confirmError"
              role="alert"
              class="rounded-xl border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive"
            >
              <p class="font-medium">{{ t('refill.confirmFailedTitle') }}</p>
              <p class="mt-1 text-xs opacity-90">{{ confirmError }}</p>
            </div>
            <p v-if="!rebuildReady" class="text-center text-xs text-amber-600">{{ t('refillRebuild.decideAll') }}</p>
            <div class="flex gap-2">
              <button
                :disabled="confirmingRefill || !rebuildReady"
                class="inline-flex h-12 min-w-0 flex-1 items-center justify-center gap-2 rounded-xl bg-primary px-6 text-base font-medium text-primary-foreground shadow-lg transition-colors hover:bg-primary/90 disabled:opacity-50"
                @click="confirmMachineRefill"
              >
                <IconCheck v-if="!confirmingRefill" class="h-5 w-5" />
                <span v-if="confirmingRefill">{{ t('refill.confirming') }}</span>
                <span v-else-if="confirmError">{{ t('refill.retry') }}</span>
                <span v-else-if="wouldFinishTour">{{ t('refill.confirmAndFinish') }}</span>
                <span v-else>{{ t('refill.confirmAndNext') }}</span>
              </button>
              <!-- Skip and the note for the next tour -->
              <DropdownMenu>
                <DropdownMenuTrigger as-child>
                  <button
                    class="inline-flex h-12 w-12 shrink-0 items-center justify-center rounded-xl border text-muted-foreground transition-colors hover:bg-muted"
                    :aria-label="t('refillNotes.moreActions')"
                    :title="t('refillNotes.moreActions')"
                  >
                    <IconDotsVertical class="h-5 w-5" />
                  </button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" side="top">
                  <DropdownMenuItem :disabled="confirmingRefill" @click="skipMachine">
                    <IconPlayerSkipForward class="h-4 w-4" />
                    {{ t('refill.skipMachine') }}
                  </DropdownMenuItem>
                  <DropdownMenuItem @click="noteDialogOpen = true">
                    <IconNote class="h-4 w-4" />
                    {{ t('refillNotes.title') }}
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
          </template>
        </div>
      </div>
    </template>

    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <!-- STEP 3: SUMMARY -->
    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <template v-else-if="currentStep === 'summary'">
      <!-- Totals -->
      <div class="grid grid-cols-2 gap-2 sm:gap-4 sm:grid-cols-4">
        <div class="rounded-xl border p-3 text-center">
          <p class="text-2xl font-bold tabular-nums">{{ tourSummary.machinesRefilled }}</p>
          <p class="text-[11px] sm:text-xs text-muted-foreground">{{ t('refill.machinesRefilled', tourSummary.machinesRefilled) }}</p>
        </div>
        <div v-if="tourSummary.machinesSkipped > 0" class="rounded-xl border p-3 text-center">
          <p class="text-2xl font-bold tabular-nums text-amber-500">{{ tourSummary.machinesSkipped }}</p>
          <p class="text-[11px] sm:text-xs text-muted-foreground">{{ t('refill.machinesSkipped', { count: tourSummary.machinesSkipped }) }}</p>
        </div>
        <div class="rounded-xl border p-3 text-center">
          <p class="text-2xl font-bold tabular-nums">{{ tourSummary.totalTraysRefilled }}</p>
          <p class="text-[11px] sm:text-xs text-muted-foreground">{{ t('refill.traysRefilled', tourSummary.totalTraysRefilled) }}</p>
        </div>
        <div v-if="tourSummary.totalSlotsRebuilt > 0" class="rounded-xl border p-3 text-center">
          <p class="text-2xl font-bold tabular-nums">{{ tourSummary.totalSlotsRebuilt }}</p>
          <p class="text-[11px] sm:text-xs text-muted-foreground">{{ t('refillRebuild.slotsRebuilt', { n: tourSummary.totalSlotsRebuilt }) }}</p>
        </div>
        <div class="rounded-xl border p-3 text-center">
          <p class="text-2xl font-bold tabular-nums">{{ tourSummary.totalItemsAdded }}</p>
          <p class="text-[11px] sm:text-xs text-muted-foreground">{{ t('refill.itemsAdded', tourSummary.totalItemsAdded) }}</p>
        </div>
      </div>

      <!-- Back at the warehouse: leftovers of the slot rebuilds -->
      <RefillTourLeftovers
        v-if="tourLeftoverRows.length > 0"
        :rows="tourLeftoverRows"
        :has-warehouse="!!selectedWarehouseId"
        :returned="leftoversReturned"
        :busy="returningLeftovers"
        :error="returnLeftoversError"
        @count="setLeftoverCount"
        @destination="setLeftoverDestination"
        @expiry="setLeftoverExpiry"
        @book="returnTourLeftovers"
      />

      <Separator />

      <!-- Per-machine log -->
      <div class="flex flex-col gap-2 pb-20 sm:pb-24">
        <div
          v-for="entry in tourLog"
          :key="entry.machine_id"
          class="flex items-center justify-between rounded-xl border px-4 py-3"
        >
          <div class="min-w-0 flex-1">
            <p class="text-sm font-medium truncate">{{ entry.machine_name }}</p>
            <p v-if="!entry.skipped" class="text-xs text-muted-foreground">
              {{ entry.trays_refilled }} {{ entry.trays_refilled === 1 ? 'tray' : 'trays' }} &middot;
              +{{ entry.total_added }} {{ entry.total_added === 1 ? 'item' : 'items' }}
              <template v-if="entry.slots_rebuilt"> &middot; {{ t('refillRebuild.slotsRebuilt', { n: entry.slots_rebuilt }) }}</template>
            </p>
          </div>
          <span
            v-if="entry.skipped"
            class="ml-2 shrink-0 inline-flex items-center rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-950/40 dark:text-amber-400"
          >
            {{ t('refill.skipped') }}
          </span>
          <IconCheck v-else class="ml-2 h-5 w-5 shrink-0 text-green-600" />
        </div>
      </div>

      <!-- Bottom bar — Back to Machines + Tour History link -->
      <div class="fixed bottom-[calc(3.5rem+env(safe-area-inset-bottom))] md:bottom-0 inset-x-0 z-20 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80 p-3 sm:p-4 md:pb-[max(1rem,env(safe-area-inset-bottom))]">
        <div class="flex flex-col gap-2 max-w-3xl mx-auto">
          <button
            class="inline-flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-primary px-6 text-base font-medium text-primary-foreground shadow-lg transition-colors hover:bg-primary/90"
            @click="finishTour('/machines')"
          >
            {{ t('refill.backToMachines') }}
          </button>
          <button
            class="inline-flex h-10 w-full items-center justify-center gap-2 rounded-xl border px-4 text-sm font-medium text-muted-foreground transition-colors hover:bg-muted"
            @click="finishTour('/tour-history')"
          >
            {{ t('tourHistory.viewTourHistory') }}
          </button>
        </div>
      </div>
    </template>
    <RefillTourNoteDialog
      v-if="currentMachine"
      v-model:open="noteDialogOpen"
      :machine-name="currentMachine.name"
      :load="() => loadTourNote(currentMachine!.id)"
      :save="(note: string) => saveTourNote(currentMachine!.id, note)"
    />
  </div>
</template>
