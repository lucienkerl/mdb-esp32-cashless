<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'
import type { TheoreticalCash, VendingMachineBasic } from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  theoreticalCash: TheoreticalCash | null
  assignedMachines: VendingMachineBasic[]
  trackPerMachine: boolean
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { counted: number; expected: number; machineId: string | null; floatBack: number; description: string }): void
}>()

const { t } = useI18n()

const form = ref({
  counted_amount: 0,
  float_back: 0,
  description: 'Geldentnahme aus Automat',
  machine_id: null as string | null,
})
const loading = ref(false)

const difference = computed(() => {
  if (!props.theoreticalCash) return 0
  return form.value.counted_amount - props.theoreticalCash.cash_sales_since
})

/** `v-model.number` lässt ein geleertes Zahlenfeld als '' stehen, nicht als 0.
 *  Einmal hier normalisieren — sonst ginge '' an die RPC und Postgres lehnte
 *  den ganzen Vorgang ab, inklusive der eigentlich gültigen Entnahme. */
const floatBack = computed(() => Number(form.value.float_back) || 0)

/** Was nach der Tubenrücklage tatsächlich in der Kasse landet. */
const netToBox = computed(() => form.value.counted_amount - floatBack.value)

/** Sobald eine Rücklage erfasst wird, ist der Automatenbezug zwingend —
 *  unabhängig von `trackPerMachine`, das nur den Erwartungswert verankert. */
const machineRequired = computed(() => floatBack.value > 0)

const canSubmit = computed(() =>
  form.value.counted_amount > 0
  && floatBack.value >= 0
  && (!machineRequired.value || form.value.machine_id !== null),
)

watch(() => props.open, (now) => {
  if (now) {
    form.value = {
      counted_amount: 0,
      float_back: 0,
      description: 'Geldentnahme aus Automat',
      machine_id: props.assignedMachines.length === 1 ? props.assignedMachines[0]!.id : null,
    }
    // Ein wiedergeöffneter Dialog startet mit einem sauberen (nicht mehr
    // gesperrten) Button — siehe Kommentar bei onSubmit für den Grund, warum
    // loading hier statt in einem finally zurückgesetzt wird.
    loading.value = false
  }
})

/** `loading` wird bewusst NICHT in einem finally zurückgesetzt: der Parent
 *  wartet nach dem emit noch auf Insert + zwei Refetches, bevor er den Dialog
 *  schließt. Bliebe der Button in der Zwischenzeit aktiv, könnte ein zweiter
 *  Klick eine zweite Entnahme ins unveränderliche Kassenbuch schreiben. Der
 *  Button bleibt also gesperrt, bis der Dialog schließt und der watch oben
 *  ihn für die nächste Öffnung zurücksetzt. */
function onSubmit() {
  if (!canSubmit.value) return
  loading.value = true
  emit('submit', {
    counted: form.value.counted_amount,
    expected: props.theoreticalCash?.cash_sales_since ?? 0,
    machineId: form.value.machine_id,
    floatBack: floatBack.value,
    description: form.value.description,
  })
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.recordWithdrawal')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div class="rounded-lg border bg-muted/50 p-3">
        <div class="text-sm text-muted-foreground">{{ t('cashBook.expectedFromMachines') }}</div>
        <div class="text-lg font-bold tabular-nums">
          {{ theoreticalCash ? formatCurrency(theoreticalCash.cash_sales_since) : '—' }}
        </div>
        <div v-if="theoreticalCash?.machines?.length" class="mt-2 space-y-0.5">
          <div v-for="m in theoreticalCash.machines" :key="m.machine_id" class="text-xs text-muted-foreground">
            {{ m.machine_name || 'Automat' }}: +{{ formatCurrency(m.cash_sales) }}
          </div>
        </div>
        <p class="mt-2 text-xs text-muted-foreground italic">
          {{ t('cashBook.expectedFromMachinesHint') }}
        </p>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.countedAmount') }} (EUR)</label>
        <input
          v-model.number="form.counted_amount"
          type="number" step="0.01" min="0" required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div
        v-if="form.counted_amount > 0 && theoreticalCash && Math.abs(difference) > 0.001"
        class="text-sm text-muted-foreground"
      >
        {{ t('cashBook.differenceLabel') }}: {{ formatCurrency(difference) }}
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.floatBack') }} (EUR)</label>
        <input
          v-model.number="form.float_back"
          type="number" step="0.01" min="0"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.floatBackHint') }}</p>
      </div>

      <div v-if="floatBack > 0" class="text-sm text-muted-foreground">
        {{ t('cashBook.netToBox') }}: {{ formatCurrency(netToBox) }}
      </div>

      <div v-if="(trackPerMachine || machineRequired) && assignedMachines.length > 0">
        <label class="text-sm font-medium">
          {{ t('cashBook.fromMachine') }}
          <span v-if="machineRequired" class="text-red-600">*</span>
        </label>
        <select
          v-model="form.machine_id"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option :value="null">—</option>
          <option v-for="m in assignedMachines" :key="m.id" :value="m.id">
            {{ m.name || m.id.slice(0, 8) }}
          </option>
        </select>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.description') }}</label>
        <input
          v-model="form.description"
          type="text"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div class="flex justify-end gap-2">
        <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
          {{ t('common.cancel') }}
        </button>
        <button type="submit" :disabled="loading || !canSubmit"
                class="h-9 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-50">
          {{ loading ? t('common.loading') : t('cashBook.bookEntry') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
