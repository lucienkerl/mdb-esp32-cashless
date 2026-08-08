<script setup lang="ts">
import { IconAlertTriangle, IconCoins } from '@tabler/icons-vue'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency } from '@/lib/utils'
import { totalChangeFloat, type MachineChangeFloat } from '@/composables/useCashBook'

const props = defineProps<{
  changeFloat: MachineChangeFloat[]
  /** `get_machine_change_float` returns rows for every cash book of the
   *  company — the card must only reflect the Barkasse it is displayed on,
   *  otherwise its total silently disagrees with the PDF export (which is
   *  scoped to the selected cash book). */
  cashBookId: string
  /** True when the balance couldn't be loaded (RPC error/null). Suppresses
   *  the total instead of showing 0, which would read as "nothing
   *  advanced" — a different, stronger claim than "we don't know". */
  unavailable: boolean
}>()
const { t } = useI18n()

const scoped = computed(() => props.changeFloat.filter(row => row.cash_book_id === props.cashBookId))

const total = computed(() => totalChangeFloat(scoped.value))

/** Sentinel-Key für Zeilen mit machine_id = null (Automat gelöscht) — echte
 *  Automaten-IDs sind UUIDs und können damit nicht kollidieren. */
const ORPHANED_KEY = '__orphaned__'

/** Je Automat summiert — ein Automat kann in mehreren Barkassen Zeilen haben,
 *  aber nach der cashBookId-Filterung oben bleibt hier nur die ausgewählte.
 *  Zeilen ohne machine_id (Automat inzwischen gelöscht) fallen alle unter
 *  denselben Sammel-Key und werden zu einem nicht zuordenbaren Posten
 *  summiert, statt beim ersten Zugriff auf `machine_id.slice()` zu crashen. */
const perMachine = computed(() => {
  const byId = new Map<string, { id: string | null; name: string; balance: number }>()
  for (const row of scoped.value) {
    const key = row.machine_id ?? ORPHANED_KEY
    const existing = byId.get(key)
    if (existing) {
      existing.balance += row.float_balance
    } else {
      byId.set(key, {
        id: row.machine_id,
        name: row.machine_id
          ? (row.machine_name || row.machine_id.slice(0, 8))
          : t('cashBook.changeFloatOrphaned'),
        balance: row.float_balance,
      })
    }
  }
  return [...byId.values()].sort((a, b) => b.balance - a.balance)
})
</script>

<template>
  <Card>
    <CardHeader>
      <CardDescription class="flex items-center gap-1.5">
        <IconCoins class="size-4" />
        {{ t('cashBook.changeFloatStation') }}
      </CardDescription>
      <CardTitle v-if="!unavailable" class="text-2xl font-semibold tabular-nums">
        {{ formatCurrency(total) }}
      </CardTitle>
    </CardHeader>
    <div class="px-6 pb-4">
      <div v-if="unavailable" class="flex items-center gap-1.5 text-xs text-amber-600 dark:text-amber-400">
        <IconAlertTriangle class="size-3.5 shrink-0" />
        {{ t('cashBook.changeFloatUnavailable') }}
      </div>
      <div v-else-if="perMachine.length === 0" class="text-xs text-muted-foreground">
        {{ t('cashBook.changeFloatEmpty') }}
      </div>
      <div v-else class="space-y-0.5">
        <div
          v-for="m in perMachine"
          :key="m.id ?? 'orphaned'"
          class="flex items-center justify-between text-xs text-muted-foreground"
        >
          <span>{{ m.name }}</span>
          <span class="tabular-nums">{{ formatCurrency(m.balance) }}</span>
        </div>
      </div>
    </div>
  </Card>
</template>
