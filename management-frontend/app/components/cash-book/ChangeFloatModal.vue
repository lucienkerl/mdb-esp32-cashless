<script setup lang="ts">
import {
  changeFloatAmount,
  type ChangeFloatDirection,
  type VendingMachineBasic,
} from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  assignedMachines: VendingMachineBasic[]
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
