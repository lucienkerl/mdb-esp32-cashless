<script setup lang="ts">
import { Badge } from '@/components/ui/badge'
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { timeAgo } from '@/lib/utils'

export interface ActivityEntry {
  id: string
  created_at: string
  entity_type: string
  action: string
  metadata: Record<string, unknown> | null
  user_display?: string
}

defineProps<{
  entries: ActivityEntry[]
}>()

function actionLabel(action: string): string {
  const labels: Record<string, string> = {
    sale_recorded: 'Sale recorded',
    credit_sent: 'Credit sent',
    stock_updated: 'Stock updated',
    stock_refill_all: 'All trays refilled',
    device_online: 'Device online',
    device_offline: 'Device offline',
    ota_triggered: 'OTA triggered',
    machine_created: 'Machine created',
    product_created: 'Product created',
    product_updated: 'Product updated',
    tray_created: 'Tray added',
    tray_updated: 'Tray updated',
    warehouse_intake: 'Stock intake',
  }
  return labels[action] ?? action.replace(/_/g, ' ')
}

function entityBadgeClass(type: string): string {
  const map: Record<string, string> = {
    sale: 'bg-green-100 text-green-700 dark:bg-green-950/40 dark:text-green-400',
    credit: 'bg-blue-100 text-blue-700 dark:bg-blue-950/40 dark:text-blue-400',
    stock: 'bg-amber-100 text-amber-700 dark:bg-amber-950/40 dark:text-amber-400',
    firmware: 'bg-purple-100 text-purple-700 dark:bg-purple-950/40 dark:text-purple-400',
    device: 'bg-slate-100 text-slate-700 dark:bg-slate-800/40 dark:text-slate-400',
    machine: 'bg-slate-100 text-slate-700 dark:bg-slate-800/40 dark:text-slate-400',
    product: 'bg-indigo-100 text-indigo-700 dark:bg-indigo-950/40 dark:text-indigo-400',
    warehouse: 'bg-amber-100 text-amber-700 dark:bg-amber-950/40 dark:text-amber-400',
  }
  return map[type] ?? 'bg-muted text-muted-foreground'
}

function metadataDetail(entry: ActivityEntry): string {
  const m = entry.metadata
  if (!m) return ''
  if (m.machine_name) return String(m.machine_name)
  if (m.product_name) return String(m.product_name)
  if (m.device_name) return String(m.device_name)
  return ''
}
</script>

<template>
  <Card>
    <CardHeader class="flex flex-row items-center justify-between pb-2">
      <CardTitle class="text-base font-medium">Recent Activity</CardTitle>
      <NuxtLink to="/history" class="text-sm text-muted-foreground hover:text-foreground transition-colors">
        View all &rarr;
      </NuxtLink>
    </CardHeader>
    <CardContent class="px-0 pb-0">
      <div v-if="entries.length === 0" class="flex items-center justify-center py-8 text-sm text-muted-foreground">
        No recent activity
      </div>
      <div v-else class="divide-y divide-border">
        <div
          v-for="entry in entries"
          :key="entry.id"
          class="flex items-center gap-3 px-6 py-3"
        >
          <!-- Entity type badge -->
          <span class="shrink-0 rounded-md px-2 py-0.5 text-xs font-medium" :class="entityBadgeClass(entry.entity_type)">
            {{ entry.entity_type }}
          </span>

          <!-- Action label + detail -->
          <span class="min-w-0 flex-1 truncate text-sm">
            {{ actionLabel(entry.action) }}
            <span v-if="metadataDetail(entry)" class="text-muted-foreground"> &middot; {{ metadataDetail(entry) }}</span>
          </span>

          <!-- User -->
          <span v-if="entry.user_display" class="hidden sm:block shrink-0 text-xs text-muted-foreground truncate max-w-24">
            {{ entry.user_display }}
          </span>

          <!-- Time -->
          <span class="shrink-0 text-xs text-muted-foreground tabular-nums">
            {{ timeAgo(entry.created_at) }}
          </span>
        </div>
      </div>
    </CardContent>
  </Card>
</template>
