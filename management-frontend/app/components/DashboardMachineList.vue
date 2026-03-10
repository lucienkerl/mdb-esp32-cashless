<script setup lang="ts">
import { Badge } from '@/components/ui/badge'
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { formatCurrency, timeAgo } from '@/lib/utils'

export interface DashboardMachine {
  id: string
  name: string
  status: string | null
  today_revenue: number
  stock_health: 'ok' | 'low' | 'critical'
  stock_percent: number
  last_sale_at: string | null
}

defineProps<{
  machines: DashboardMachine[]
}>()

function statusColor(status: string | null): string {
  if (!status || status === 'offline') return 'bg-red-500'
  return 'bg-green-500'
}

function stockBarColor(health: 'ok' | 'low' | 'critical'): string {
  if (health === 'critical') return 'bg-red-500'
  if (health === 'low') return 'bg-amber-500'
  return 'bg-green-500'
}

function stockBadgeClass(health: 'ok' | 'low' | 'critical'): string {
  if (health === 'critical') return 'text-red-600 dark:text-red-400 border-red-200 dark:border-red-800'
  if (health === 'low') return 'text-amber-600 dark:text-amber-400 border-amber-200 dark:border-amber-800'
  return 'text-green-600 dark:text-green-400 border-green-200 dark:border-green-800'
}
</script>

<template>
  <Card>
    <CardHeader class="flex flex-row items-center justify-between pb-2">
      <CardTitle class="text-base font-medium">Machines</CardTitle>
      <NuxtLink to="/machines" class="text-sm text-muted-foreground hover:text-foreground transition-colors">
        View all &rarr;
      </NuxtLink>
    </CardHeader>
    <CardContent class="px-0 pb-0">
      <div v-if="machines.length === 0" class="flex items-center justify-center py-8 text-sm text-muted-foreground">
        No machines registered
      </div>
      <div v-else class="divide-y divide-border">
        <NuxtLink
          v-for="machine in machines"
          :key="machine.id"
          :to="`/machines/${machine.id}`"
          class="flex items-center gap-3 px-6 py-3 hover:bg-muted/50 transition-colors"
        >
          <!-- Status dot -->
          <span class="relative flex size-2.5 shrink-0">
            <span
              v-if="machine.status && machine.status !== 'offline'"
              class="absolute inline-flex h-full w-full animate-ping rounded-full bg-green-400 opacity-75"
            />
            <span class="relative inline-flex size-2.5 rounded-full" :class="statusColor(machine.status)" />
          </span>

          <!-- Name -->
          <span class="min-w-0 flex-1 truncate text-sm font-medium">{{ machine.name }}</span>

          <!-- Today's revenue -->
          <span class="shrink-0 text-sm tabular-nums text-muted-foreground">
            {{ formatCurrency(machine.today_revenue) }}
          </span>

          <!-- Stock badge -->
          <Badge variant="outline" class="shrink-0 text-xs" :class="stockBadgeClass(machine.stock_health)">
            {{ machine.stock_percent }}%
          </Badge>

          <!-- Last sale -->
          <span class="shrink-0 w-16 text-right text-xs text-muted-foreground tabular-nums">
            {{ timeAgo(machine.last_sale_at) }}
          </span>
        </NuxtLink>
      </div>
    </CardContent>
  </Card>
</template>
