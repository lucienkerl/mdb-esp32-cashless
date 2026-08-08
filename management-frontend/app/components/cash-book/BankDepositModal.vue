<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'

const props = defineProps<{
  open: boolean
  currentBalance: number
  submitting: boolean
  error?: string | null
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { amount: number; description: string }): void
}>()

const { t } = useI18n()

const form = ref({ amount: 0, description: 'Bankeinzahlung' })

watch(() => props.open, (now) => {
  if (now) form.value = { amount: 0, description: 'Bankeinzahlung' }
})

function fillFullAmount() {
  form.value.amount = props.currentBalance
}

function onSubmit() {
  if (form.value.amount <= 0) return
  emit('submit', { amount: form.value.amount, description: form.value.description })
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.recordPayout')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div class="rounded-lg border bg-muted/50 p-3 text-sm">
        {{ t('cashBook.currentBalance') }}: <span class="font-semibold">{{ formatCurrency(currentBalance) }}</span>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.amount') }} (EUR)</label>
        <div class="mt-1 flex gap-2">
          <input
            v-model.number="form.amount"
            type="number" step="0.01" min="0.01" required
            class="h-9 flex-1 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <button
            type="button"
            class="h-9 rounded-md border border-input px-3 text-sm font-medium hover:bg-accent whitespace-nowrap"
            @click="fillFullAmount"
          >
            {{ t('cashBook.fullAmount') }}
          </button>
        </div>
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
        <button type="submit" :disabled="submitting || form.amount <= 0"
                class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50">
          {{ submitting ? t('common.loading') : t('cashBook.bookDeposit') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
