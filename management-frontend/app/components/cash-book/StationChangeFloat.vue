<script setup lang="ts">
import { IconCoins } from '@tabler/icons-vue'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency } from '@/lib/utils'
import { totalChangeFloat, type MachineChangeFloat } from '@/composables/useCashBook'

const props = defineProps<{ changeFloat: MachineChangeFloat[] }>()
const { t } = useI18n()

const total = computed(() => totalChangeFloat(props.changeFloat))

/** Je Automat summiert — ein Automat kann in mehreren Barkassen Zeilen haben.
 *  Die machine_id wandert bewusst mit ins Anzeigeobjekt: Automatennamen sind
 *  nicht eindeutig, taugen also nicht als v-for-key. */
const perMachine = computed(() => {
  const byId = new Map<string, { id: string; name: string; balance: number }>()
  for (const row of props.changeFloat) {
    const existing = byId.get(row.machine_id)
    if (existing) {
      existing.balance += row.float_balance
    } else {
      byId.set(row.machine_id, {
        id: row.machine_id,
        name: row.machine_name || row.machine_id.slice(0, 8),
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
      <CardTitle class="text-2xl font-semibold tabular-nums">
        {{ formatCurrency(total) }}
      </CardTitle>
    </CardHeader>
    <div class="px-6 pb-4">
      <div v-if="perMachine.length === 0" class="text-xs text-muted-foreground">
        {{ t('cashBook.changeFloatEmpty') }}
      </div>
      <div v-else class="space-y-0.5">
        <div
          v-for="m in perMachine"
          :key="m.id"
          class="flex items-center justify-between text-xs text-muted-foreground"
        >
          <span>{{ m.name }}</span>
          <span class="tabular-nums">{{ formatCurrency(m.balance) }}</span>
        </div>
      </div>
    </div>
  </Card>
</template>
