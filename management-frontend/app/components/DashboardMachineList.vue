<script setup lang="ts">
import { Badge } from '@/components/ui/badge'
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { formatCurrency, timeAgo } from '@/lib/utils'
import { dotClass, textClass } from '@/composables/useConnectivity'

const { t, locale } = useI18n()
const conn = useConnectivity()

export interface DashboardMachine {
  id: string
  name: string
  embedded: { id: string; status: string | null; status_at: string | null; online_since: string | null; mdb_diagnostics: unknown } | null
  today_revenue: number
  stock_health: 'ok' | 'low' | 'fill' | 'critical'
  stock_percent: number
  last_sale_at: string | null
}

defineProps<{
  machines: DashboardMachine[]
}>()

function stockBarColor(health: 'ok' | 'low' | 'fill' | 'critical'): string {
  if (health === 'critical') return 'bg-red-500'
  if (health === 'low') return 'bg-amber-500'
  if (health === 'fill') return 'bg-blue-500'
  return 'bg-green-500'
}

function stockBadgeClass(health: 'ok' | 'low' | 'fill' | 'critical'): string {
  if (health === 'critical') return 'text-red-600 dark:text-red-400 border-red-200 dark:border-red-800'
  if (health === 'low') return 'text-amber-600 dark:text-amber-400 border-amber-200 dark:border-amber-800'
  if (health === 'fill') return 'text-blue-600 dark:text-blue-400 border-blue-200 dark:border-blue-800'
  return 'text-green-600 dark:text-green-400 border-green-200 dark:border-green-800'
}
</script>

<template>
  <Card>
    <CardHeader class="flex flex-row items-center justify-between pb-2">
      <CardTitle class="text-base font-medium">{{ t('nav.machines') }}</CardTitle>
      <NuxtLink to="/machines" class="text-sm text-muted-foreground hover:text-foreground transition-colors">
        {{ t('dashboard.viewAll') }}
      </NuxtLink>
    </CardHeader>
    <CardContent class="px-0 pb-0">
      <div v-if="machines.length === 0" class="flex items-center justify-center py-8 text-sm text-muted-foreground">
        {{ t('dashboard.noMachinesRegistered') }}
      </div>
      <div v-else class="divide-y divide-border">
        <NuxtLink
          v-for="machine in machines"
          :key="machine.id"
          :to="`/machines/${machine.id}`"
          class="flex items-center gap-2 sm:gap-3 px-3 sm:px-6 py-3 hover:bg-muted/50 transition-colors"
        >
          <!-- Status dot (the word is in the title and, for problems, next to the name) -->
          <span
            class="inline-flex size-2.5 shrink-0 rounded-full"
            :class="dotClass(conn.of(machine.embedded).state)"
            :title="conn.stateLabel(conn.of(machine.embedded))"
          />

          <!-- Name + connectivity line for anything that is not plainly online -->
          <span class="min-w-0 flex-1">
            <span class="block truncate text-sm font-medium">{{ machine.name }}</span>
            <span
              v-if="conn.of(machine.embedded).state !== 'online' || conn.of(machine.embedded).reader === 'inactive'"
              class="block truncate text-xs"
              :class="conn.of(machine.embedded).reader === 'inactive' ? 'text-amber-700 dark:text-amber-400' : textClass(conn.of(machine.embedded).state)"
            >
              {{ conn.of(machine.embedded).reader === 'inactive' ? t('connectivity.reader.inactive') : conn.timeLabel(conn.of(machine.embedded)) }}
            </span>
          </span>

          <!-- Today's revenue -->
          <span class="shrink-0 text-sm tabular-nums text-muted-foreground">
            {{ formatCurrency(machine.today_revenue, locale) }}
          </span>

          <!-- Stock badge -->
          <Badge variant="outline" class="shrink-0 text-xs" :class="stockBadgeClass(machine.stock_health)">
            {{ machine.stock_percent }}%
          </Badge>

          <!-- Last sale -->
          <span class="hidden sm:block shrink-0 w-16 text-right text-xs text-muted-foreground tabular-nums">
            {{ timeAgo(machine.last_sale_at, t) }}
          </span>
        </NuxtLink>
      </div>
    </CardContent>
  </Card>
</template>
