<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'
import type { CashBookEntry } from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  entry: CashBookEntry | null
  entries: CashBookEntry[]
  loading?: boolean
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'confirm'): void
}>()

const { t } = useI18n()

// Eine Entnahme kann eine Wechselgeld-Rücklage-Zeile mit sich führen
// (paired_entry_id auf der change_float-Zeile zeigt auf die Entnahme).
// Stornieren storniert dann beide — der Nutzer soll das vorher wissen.
const pairedEntry = computed(() => {
  if (!props.entry) return null
  return props.entries.find(
    e => e.paired_entry_id === props.entry!.id && !e.is_reversed,
  ) ?? null
})

function typeLabel(type: string): string {
  const map: Record<string, string> = {
    initial: t('cashBook.typeInitial'),
    withdrawal: t('cashBook.typeWithdrawal'),
    correction: t('cashBook.typeCorrection'),
    payout: t('cashBook.typePayout'),
    expense: t('cashBook.typeExpense'),
    reversal: t('cashBook.typeReversal'),
  }
  return map[type] ?? type
}

function formatAmount(amount: number): string {
  const prefix = amount >= 0 ? '+' : ''
  return `${prefix}${formatCurrency(amount)}`
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.reversalConfirmTitle')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <div class="space-y-4">
      <p class="text-sm">
        {{ t('cashBook.reversalConfirmMessage', { number: entry?.entry_number }) }}
      </p>
      <div v-if="entry" class="rounded-lg border bg-muted/50 p-3 text-sm space-y-1">
        <div>{{ t('cashBook.type') }}: {{ typeLabel(entry.type) }}</div>
        <div>{{ t('cashBook.amount') }}: {{ formatAmount(entry.amount) }}</div>
        <div>{{ t('cashBook.description') }}: {{ entry.description || '—' }}</div>
      </div>
      <p v-if="pairedEntry" class="text-sm text-muted-foreground">
        {{ t('cashBook.reversalIncludesPaired') }}
      </p>
      <div class="flex justify-end gap-2">
        <button class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
          {{ t('common.cancel') }}
        </button>
        <button
          :disabled="loading"
          class="h-9 rounded-md bg-destructive px-4 text-sm font-medium text-white hover:bg-destructive/90 disabled:opacity-50"
          @click="emit('confirm')"
        >
          {{ loading ? t('common.loading') : t('cashBook.reverseEntry') }}
        </button>
      </div>
    </div>
  </AppModal>
</template>
