<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'
import type { CashBookEntry } from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  entry: CashBookEntry | null
  entries: CashBookEntry[]
  loading?: boolean
  error?: string | null
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'confirm'): void
}>()

const { t } = useI18n()

// Eine Entnahme kann mehrere Wechselgeld-Rücklage-Zeilen mit sich führen
// (paired_entry_id auf jeder change_float-Zeile zeigt auf die Entnahme) —
// eine je Automat bei einer Mehrfach-Rücklage auf einer Tour mit mehreren
// besuchten Automaten. Stornieren storniert dann alle — der Nutzer soll
// das vorher wissen. `.filter` statt `.find`, sonst würden alle bis auf
// die erste Gegenzeile stillschweigend unter den Tisch fallen.
const pairedEntries = computed(() => {
  if (!props.entry) return []
  return props.entries.filter(
    e => e.paired_entry_id === props.entry!.id && !e.is_reversed,
  )
})

function typeLabel(type: string): string {
  const map: Record<string, string> = {
    initial: t('cashBook.typeInitial'),
    withdrawal: t('cashBook.typeWithdrawal'),
    correction: t('cashBook.typeCorrection'),
    payout: t('cashBook.typePayout'),
    expense: t('cashBook.typeExpense'),
    change_float: t('cashBook.typeChangeFloat'),
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
      <p v-if="pairedEntries.length > 0" class="text-sm text-muted-foreground">
        {{ t('cashBook.reversalIncludesPaired', pairedEntries.length) }}
      </p>
      <div v-if="error" class="rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700 dark:border-red-800 dark:bg-red-900/20 dark:text-red-400">
        {{ error }}
      </div>
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
