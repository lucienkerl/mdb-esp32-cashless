<script setup lang="ts">
import { EXPENSE_CATEGORIES } from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  submitting: boolean
  error?: string | null
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { amount: number; category: string; receiptReference: string; description: string }): void
}>()

const { t } = useI18n()

const form = ref({
  amount: 0,
  category: 'rent' as string,
  receipt_reference: '',
  description: '',
})

const needsDescription = computed(() => form.value.category === 'other')
const canSubmit = computed(() =>
  form.value.amount > 0
  && form.value.receipt_reference.trim().length > 0
  && (!needsDescription.value || form.value.description.trim().length > 0),
)

function categoryLabel(code: string): string {
  return t(`cashBook.category_${code}`)
}

watch(() => props.open, (now) => {
  if (now) {
    form.value = { amount: 0, category: 'rent', receipt_reference: '', description: '' }
  }
})

function onSubmit() {
  if (!canSubmit.value) return
  emit('submit', {
    amount: form.value.amount,
    category: form.value.category,
    receiptReference: form.value.receipt_reference.trim(),
    description: form.value.description.trim(),
  })
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.recordExpense')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div>
        <label class="text-sm font-medium">{{ t('cashBook.amount') }} (EUR)</label>
        <input
          v-model.number="form.amount"
          type="number" step="0.01" min="0" required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.category') }}</label>
        <select
          v-model="form.category"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option v-for="c in EXPENSE_CATEGORIES" :key="c" :value="c">
            {{ categoryLabel(c) }}
          </option>
        </select>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.receiptReference') }}</label>
        <input
          v-model="form.receipt_reference"
          type="text" required
          :placeholder="t('cashBook.receiptReferencePlaceholder')"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div>
        <label class="text-sm font-medium">
          {{ t('cashBook.description') }}
          <span v-if="needsDescription" class="text-red-600">*</span>
        </label>
        <input
          v-model="form.description"
          type="text"
          :required="needsDescription"
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
                class="h-9 rounded-md bg-amber-600 px-4 text-sm font-medium text-white hover:bg-amber-700 disabled:opacity-50">
          {{ submitting ? t('common.loading') : t('cashBook.bookEntry') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
