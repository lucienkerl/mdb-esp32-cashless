<script setup lang="ts">
import { IconAlertTriangle } from '@tabler/icons-vue'
import { formatCurrency } from '@/lib/utils'
import {
  changeFloatAmount,
  floatBalanceForMachine,
  type ChangeFloatDirection,
  type MachineChangeFloat,
  type VendingMachineBasic,
} from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  assignedMachines: VendingMachineBasic[]
  changeFloat: MachineChangeFloat[]
  /** Scopes `floatBalanceForMachine` below to the Barkasse this dialog is
   *  open for — a machine can have moved between Barkassen and carry a
   *  float balance in more than one. Without this, `currentFloat` would
   *  sum across every Barkasse the machine has ever been in, and the
   *  over-return warning would fail to fire for the correct one. */
  cashBookId: string
  /** True when the balance couldn't be loaded (RPC error/null) — mirrors
   *  the balance card's `unavailable` flag. Without this, "we don't know"
   *  silently renders as "0,00 €", the stronger claim "nothing advanced",
   *  which then triggers a spurious over-return warning below. */
  changeFloatUnavailable: boolean
  submitting: boolean
  error?: string | null
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { amount: number; machineId: string; description: string }): void
}>()

const { t } = useI18n()

const form = ref({
  direction: 'into_machine' as ChangeFloatDirection,
  amount: 0,
  machine_id: '' as string,
  description: '',
})

/** Vorgestrecktes Wechselgeld des gewählten Automaten. */
const currentFloat = computed(() =>
  form.value.machine_id
    ? floatBalanceForMachine(props.changeFloat, form.value.machine_id, props.cashBookId)
    : 0,
)

/** Warnung, wenn mehr zurückgenommen wird als vorgestreckt wurde. Blockiert
 *  nicht — eine Buchung, die die Realität abbildet, wird nie verweigert.
 *  Unterdrückt, wenn der Bestand nicht geladen werden konnte — sonst würde
 *  eine unbekannte (nicht: null) Rücklage einen falschen Alarm auslösen. */
const showNegativeWarning = computed(() =>
  !props.changeFloatUnavailable
  && form.value.direction === 'back_to_box'
  && form.value.amount > 0
  && form.value.amount > currentFloat.value + 0.001,
)

const canSubmit = computed(() =>
  form.value.amount > 0 && form.value.machine_id !== '',
)

watch(() => props.open, (now) => {
  if (now) {
    form.value = {
      direction: 'into_machine',
      amount: 0,
      // Bei genau einem zugeordneten Automaten vorauswählen.
      machine_id: props.assignedMachines.length === 1 ? props.assignedMachines[0]!.id : '',
      description: '',
    }
  }
})

function onSubmit() {
  if (!canSubmit.value) return
  emit('submit', {
    amount: changeFloatAmount(form.value.direction, form.value.amount),
    machineId: form.value.machine_id,
    description: form.value.description.trim(),
  })
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.recordChangeFloat')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <p class="text-xs text-muted-foreground">{{ t('cashBook.changeFloatHint') }}</p>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.changeFloatDirection') }}</label>
        <select
          v-model="form.direction"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option value="into_machine">{{ t('cashBook.changeFloatIntoMachine') }}</option>
          <option value="back_to_box">{{ t('cashBook.changeFloatBackToBox') }}</option>
        </select>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.forMachine') }}</label>
        <p v-if="assignedMachines.length === 0" class="mt-1 text-xs text-muted-foreground">
          {{ t('cashBook.noAssignedMachineHint') }}
        </p>
        <template v-else>
          <select
            v-model="form.machine_id"
            required
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option value="">—</option>
            <option v-for="m in assignedMachines" :key="m.id" :value="m.id">
              {{ m.name || m.id.slice(0, 8) }}
            </option>
          </select>
          <p v-if="form.machine_id && changeFloatUnavailable" class="mt-1 flex items-center gap-1.5 text-xs text-amber-600 dark:text-amber-400">
            <IconAlertTriangle class="size-3.5 shrink-0" />
            {{ t('cashBook.changeFloatUnavailable') }}
          </p>
          <p v-else-if="form.machine_id" class="mt-1 text-xs text-muted-foreground">
            {{ t('cashBook.totalChangeFloat') }}: {{ formatCurrency(currentFloat) }}
          </p>
        </template>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.amount') }} (EUR)</label>
        <input
          v-model.number="form.amount"
          type="number" step="0.01" min="0" required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <p v-if="showNegativeWarning" class="text-sm text-amber-600 dark:text-amber-400">
        {{ t('cashBook.changeFloatNegativeWarning') }}
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
                class="h-9 rounded-md bg-purple-600 px-4 text-sm font-medium text-white hover:bg-purple-700 disabled:opacity-50">
          {{ submitting ? t('common.loading') : t('cashBook.bookEntry') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
