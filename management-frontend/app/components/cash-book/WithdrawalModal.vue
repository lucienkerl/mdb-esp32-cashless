<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'
import type { TheoreticalCash, VendingMachineBasic } from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  theoreticalCash: TheoreticalCash | null
  assignedMachines: VendingMachineBasic[]
  trackPerMachine: boolean
  submitting: boolean
  error?: string | null
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: {
    counted: number
    expected: number
    machineId: string | null
    floatBack: number
    floats: { machineId: string; amount: number }[]
    description: string
  }): void
}>()

const { t } = useI18n()

const form = ref({
  counted_amount: 0,
  float_back: 0,
  description: 'Geldentnahme aus Automat',
  machine_id: null as string | null,
})

/** Rücklage-Rohwerte je Automat im Mehrfach-Modus, keyed by machine id. */
const multiFloatAmounts = ref<Record<string, number>>({})

const difference = computed(() => {
  if (!props.theoreticalCash) return 0
  return form.value.counted_amount - props.theoreticalCash.cash_sales_since
})

/** Mehr als ein Automat in der Theoretical-Cash-Aufschlüsselung → die
 *  Rücklage muss je Automat erfasst werden, sonst würde der gesamte Betrag
 *  fälschlich auf einen einzigen gebucht — genau die Fehlzuordnung, die die
 *  Mehrfach-RPC beheben soll (mirror von iOS' `isMultiMachine`). */
const isMultiMachine = computed(() => (props.theoreticalCash?.machines?.length ?? 0) > 1)

/** `v-model.number` lässt ein geleertes Zahlenfeld als '' stehen, nicht als 0.
 *  Einmal hier normalisieren — sonst ginge '' an die RPC und Postgres lehnte
 *  den ganzen Vorgang ab, inklusive der eigentlich gültigen Entnahme. */
const floatBack = computed(() => Number(form.value.float_back) || 0)

/** Rücklage-Beträge je Automat im Mehrfach-Modus, ein Eintrag pro Zeile aus
 *  der Theoretical-Cash-Aufschlüsselung. */
const multiFloats = computed(() =>
  (props.theoreticalCash?.machines ?? []).map(m => ({
    machineId: m.machine_id,
    amount: Number(multiFloatAmounts.value[m.machine_id]) || 0,
  })),
)

const totalFloatBack = computed(() =>
  isMultiMachine.value
    ? multiFloats.value.reduce((sum, f) => sum + f.amount, 0)
    : floatBack.value,
)

/** Was nach der Tubenrücklage tatsächlich in der Kasse landet. */
const netToBox = computed(() => form.value.counted_amount - totalFloatBack.value)

/** Sobald eine Rücklage erfasst wird, ist der Automatenbezug zwingend —
 *  unabhängig von `trackPerMachine`, das nur den Erwartungswert verankert.
 *  Im Mehrfach-Modus entfällt diese Pflicht: jede Zeile trägt ihren eigenen
 *  Automaten bereits in `multiFloats`, ein zusätzlicher Top-Level-Automat
 *  wäre überflüssig. */
const machineRequired = computed(() => !isMultiMachine.value && floatBack.value > 0)

const canSubmit = computed(() =>
  form.value.counted_amount > 0
  && (isMultiMachine.value
    ? multiFloats.value.every(f => f.amount >= 0)
    : floatBack.value >= 0)
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
    multiFloatAmounts.value = {}
  }
})

function onSubmit() {
  if (!canSubmit.value) return
  emit('submit', {
    counted: form.value.counted_amount,
    expected: props.theoreticalCash?.cash_sales_since ?? 0,
    // Im Mehrfach-Modus geht die Rücklage ausschließlich über `floats` —
    // machineId/floatBack bleiben leer/0, damit die RPC-seitige
    // "p_float_back und p_floats schließen sich aus"-Prüfung nie anschlägt.
    machineId: isMultiMachine.value ? null : form.value.machine_id,
    floatBack: isMultiMachine.value ? 0 : floatBack.value,
    floats: isMultiMachine.value ? multiFloats.value.filter(f => f.amount > 0) : [],
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

      <!-- Einzelfall: ein Feld, wie bisher. -->
      <div v-if="!isMultiMachine">
        <label class="text-sm font-medium">{{ t('cashBook.floatBack') }} (EUR)</label>
        <input
          v-model.number="form.float_back"
          type="number" step="0.01" min="0"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.floatBackHint') }}</p>
      </div>

      <!-- Mehrfach-Modus: eine Zeile je Automat der Theoretical-Cash-Aufschlüsselung,
           damit sich die Rücklage nicht mehr auf einen einzigen Automaten
           zwingen lässt, wenn tatsächlich mehrere geleert wurden. -->
      <div v-else>
        <label class="text-sm font-medium">{{ t('cashBook.floatBack') }} (EUR)</label>
        <div class="mt-1 space-y-2">
          <div
            v-for="m in theoreticalCash?.machines ?? []"
            :key="m.machine_id"
            class="flex items-center gap-2"
          >
            <span class="flex-1 truncate text-sm">{{ m.machine_name || 'Automat' }}</span>
            <input
              v-model.number="multiFloatAmounts[m.machine_id]"
              type="number" step="0.01" min="0"
              class="h-9 w-28 rounded-md border border-input bg-background px-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>
        </div>
        <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.floatBackHint') }}</p>
      </div>

      <div v-if="totalFloatBack > 0" class="text-sm text-muted-foreground">
        {{ t('cashBook.netToBox') }}: {{ formatCurrency(netToBox) }}
      </div>

      <div v-if="!isMultiMachine && (trackPerMachine || machineRequired) && assignedMachines.length > 0">
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
      <p v-else-if="!isMultiMachine && machineRequired && assignedMachines.length === 0" class="text-xs text-muted-foreground">
        {{ t('cashBook.noAssignedMachineHint') }}
      </p>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.description') }}</label>
        <input
          v-model="form.description"
          type="text"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div v-if="error" class="rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700 dark:border-red-800 dark:bg-red-900/20 dark:text-red-400">
        {{ error }}
      </div>

      <div class="flex justify-end gap-2">
        <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
          {{ t('common.cancel') }}
        </button>
        <button type="submit" :disabled="submitting || !canSubmit"
                class="h-9 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-50">
          {{ submitting ? t('common.loading') : t('cashBook.bookEntry') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
