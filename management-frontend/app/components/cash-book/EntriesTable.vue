<script setup lang="ts">
import { IconShieldCheck } from '@tabler/icons-vue'
import { Badge } from '@/components/ui/badge'
import { formatCurrency, formatDateTime } from '@/lib/utils'
import type { CashBookEntry } from '@/composables/useCashBook'

defineProps<{
  entries: CashBookEntry[]
  loading: boolean
  dateFilter: '30' | '90' | 'year' | 'all'
  integrityResult: { verified: number; total: number; valid: boolean } | null
  totalWithdrawals: { amount: number; count: number }
  totalCorrections: { amount: number; count: number }
  totalExpenses: { amount: number; count: number }
  getMemberName: (userId: string) => string
}>()

const emit = defineEmits<{
  (e: 'update:dateFilter', value: '30' | '90' | 'year' | 'all'): void
  (e: 'reverse', entry: CashBookEntry): void
}>()

const { t } = useI18n()

function typeBadgeClass(type: string): string {
  switch (type) {
    case 'initial': return 'bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300 border-gray-200 dark:border-gray-700'
    case 'withdrawal': return 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400 border-red-200 dark:border-red-800'
    case 'correction': return 'bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400 border-yellow-200 dark:border-yellow-800'
    case 'payout': return 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400 border-blue-200 dark:border-blue-800'
    case 'reversal': return 'bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400 border-orange-200 dark:border-orange-800'
    case 'expense': return 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400 border-amber-200 dark:border-amber-800'
    case 'change_float': return 'bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-400 border-purple-200 dark:border-purple-800'
    default: return ''
  }
}

function typeLabel(type: string, amount?: number): string {
  if (type === 'change_float' && amount !== undefined) {
    return amount < 0 ? t('cashBook.changeFloatIn') : t('cashBook.changeFloatOut')
  }
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

function amountClass(amount: number): string {
  return amount >= 0
    ? 'text-green-600 dark:text-green-400 font-semibold'
    : 'text-red-600 dark:text-red-400 font-semibold'
}

function formatAmount(amount: number): string {
  const prefix = amount >= 0 ? '+' : ''
  return `${prefix}${formatCurrency(amount)}`
}
</script>

<template>
  <div class="rounded-xl border bg-card">
    <div class="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
      <div class="flex items-center gap-3">
        <h2 class="text-lg font-semibold">{{ t('cashBook.entries') }}</h2>
        <Badge variant="outline" class="text-green-600 dark:text-green-400">
          <IconShieldCheck class="size-3" />
          {{ t('cashBook.gobdCompliant') }}
        </Badge>
      </div>

      <select
        :value="dateFilter"
        class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring sm:w-48"
        @change="emit('update:dateFilter', ($event.target as HTMLSelectElement).value as '30' | '90' | 'year' | 'all')"
      >
        <option value="30">{{ t('cashBook.last30Days') }}</option>
        <option value="90">{{ t('cashBook.last90Days') }}</option>
        <option value="year">{{ t('cashBook.thisYear') }}</option>
        <option value="all">{{ t('cashBook.allTime') }}</option>
      </select>
    </div>

    <!-- Inline stats strip -->
    <div class="flex flex-wrap gap-x-4 gap-y-1 border-t px-4 py-2 text-xs text-muted-foreground">
      <span>{{ t('cashBook.totalWithdrawals') }}: {{ formatCurrency(totalWithdrawals.amount) }} ({{ totalWithdrawals.count }})</span>
      <span>·</span>
      <span>{{ t('cashBook.totalCorrections') }}: {{ totalCorrections.count }}</span>
      <span>·</span>
      <span>{{ t('cashBook.totalExpenses') }}: {{ formatCurrency(totalExpenses.amount) }} ({{ totalExpenses.count }})</span>
      <span>·</span>
      <span v-if="integrityResult">{{ integrityResult.verified }}/{{ integrityResult.total }} {{ t('cashBook.entriesVerified') }}</span>
    </div>

    <!-- Table -->
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-t text-left text-muted-foreground">
            <th class="px-4 py-2 font-medium">{{ t('cashBook.date') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('cashBook.type') }}</th>
            <th class="px-4 py-2 font-medium text-right">{{ t('cashBook.amount') }}</th>
            <th class="px-4 py-2 font-medium text-right">{{ t('cashBook.balanceAfter') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('cashBook.description') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('cashBook.performedBy') }}</th>
            <th class="px-4 py-2 font-medium w-20"></th>
          </tr>
        </thead>
        <tbody>
          <template v-if="loading">
            <tr>
              <td colspan="7" class="px-4 py-8 text-center text-muted-foreground">
                {{ t('common.loading') }}
              </td>
            </tr>
          </template>
          <template v-else-if="entries.length === 0">
            <tr>
              <td colspan="7" class="px-4 py-8 text-center text-muted-foreground">
                {{ t('cashBook.entries') }}: 0
              </td>
            </tr>
          </template>
          <template v-else>
            <template v-for="entry in entries" :key="entry.id">
              <tr
                class="border-t"
                :class="entry.is_reversed ? 'opacity-50 line-through' : ''"
              >
                <td class="px-4 py-2.5 whitespace-nowrap">
                  {{ formatDateTime(entry.created_at) }}
                </td>
                <td class="px-4 py-2.5">
                  <span
                    class="inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-medium"
                    :class="typeBadgeClass(entry.type)"
                  >
                    {{ typeLabel(entry.type, entry.amount) }}
                  </span>
                  <span v-if="entry.is_reversed" class="ml-1 text-xs text-muted-foreground">
                    ({{ t('cashBook.reversed') }})
                  </span>
                </td>
                <td class="px-4 py-2.5 text-right whitespace-nowrap" :class="amountClass(entry.amount)">
                  {{ formatAmount(entry.amount) }}
                </td>
                <td class="px-4 py-2.5 text-right whitespace-nowrap tabular-nums">
                  {{ formatCurrency(entry.balance_after) }}
                </td>
                <td class="px-4 py-2.5 max-w-xs truncate">
                  {{ entry.description || '—' }}
                </td>
                <td class="px-4 py-2.5 whitespace-nowrap">
                  {{ entry.user_display || getMemberName(entry.created_by) }}
                </td>
                <td class="px-4 py-2.5 text-right">
                  <button
                    v-if="!entry.is_reversed && entry.type !== 'reversal' && entry.type !== 'initial'"
                    class="text-xs text-muted-foreground hover:text-foreground"
                    @click="emit('reverse', entry)"
                  >
                    {{ t('cashBook.reverseEntry') }}
                  </button>
                </td>
              </tr>

              <tr
                v-if="entry.counted_amount != null && entry.expected_amount != null && Math.abs(entry.counted_amount - entry.expected_amount) > 0.001"
              >
                <td colspan="7" class="px-4 py-1.5 text-xs text-muted-foreground">
                  {{ t('cashBook.difference', {
                    diff: formatCurrency(Math.abs(entry.counted_amount - entry.expected_amount)),
                    counted: formatCurrency(entry.counted_amount)
                  }) }}
                </td>
              </tr>

              <tr v-if="entry.type === 'expense' && (entry.category || entry.receipt_reference)">
                <td colspan="7" class="px-4 py-1.5 text-xs text-muted-foreground">
                  <span v-if="entry.category">{{ t(`cashBook.category_${entry.category}`) }}</span>
                  <span v-if="entry.receipt_reference"> · {{ t('cashBook.receiptReference') }}: {{ entry.receipt_reference }}</span>
                </td>
              </tr>
            </template>
          </template>
        </tbody>
      </table>
    </div>
  </div>
</template>
