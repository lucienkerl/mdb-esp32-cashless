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
  (e: 'submit', payload: { counted: number; expected: number; machineId: string | null; description: string }): void
}>()

const { t } = useI18n()

const form = ref({
  counted_amount: 0,
  description: t('cashBook.defaultWithdrawalDescription'),
  machine_id: null as string | null,
})
const loading = ref(false)

const difference = computed(() => {
  if (!props.theoreticalCash) return 0
  return form.value.counted_amount - props.theoreticalCash.cash_sales_since
})

watch(() => props.open, (now) => {
  if (now) {
    form.value = { counted_amount: 0, description: t('cashBook.defaultWithdrawalDescription'), machine_id: null }
  }
})

async function onSubmit() {
  loading.value = true
  try {
    emit('submit', {
      counted: form.value.counted_amount,
      expected: props.theoreticalCash?.cash_sales_since ?? 0,
      machineId: form.value.machine_id,
      description: form.value.description,
    })
  } finally {
    loading.value = false
  }
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

      <div v-if="trackPerMachine && assignedMachines.length > 0">
        <label class="text-sm font-medium">{{ t('cashBook.fromMachine') }}</label>
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
        <button type="submit" :disabled="loading || form.counted_amount <= 0"
                class="h-9 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-50">
          {{ loading ? t('common.loading') : t('cashBook.bookEntry') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
