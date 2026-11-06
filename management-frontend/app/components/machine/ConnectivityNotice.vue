<script setup lang="ts">
import { computed } from 'vue'
import type { Connectivity } from '@/lib/connectivity'
import { useConnectivity } from '@/composables/useConnectivity'
import DeviceStatusChip from '@/components/DeviceStatusChip.vue'

/**
 * Explanation shown under the machine header when the device is not simply
 * online: what the state means and what to check. Nothing for a healthy device.
 */
const props = defineProps<{ connectivity: Connectivity }>()

const { t } = useI18n()
const { timeLabel, clock } = useConnectivity()

const tone = computed(() => {
  const c = props.connectivity
  if (c.state === 'offline') return 'border-red-500/30 bg-red-500/5'
  if (c.state === 'stale' || c.reader === 'inactive') return 'border-amber-500/30 bg-amber-500/5'
  if (c.state === 'updating') return 'border-purple-500/30 bg-purple-500/5'
  return ''
})

const visible = computed(() => {
  const c = props.connectivity
  return c.state === 'offline' || c.state === 'stale' || c.state === 'updating' || (c.state === 'online' && c.reader === 'inactive')
})
</script>

<template>
  <div v-if="visible" class="rounded-xl border p-4" :class="tone">
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
      <DeviceStatusChip :connectivity="connectivity" />
      <span v-if="connectivity.state === 'online'" class="text-sm font-semibold text-amber-700 dark:text-amber-400">
        {{ t('connectivity.reader.inactive') }}
      </span>
      <span v-else class="text-sm font-semibold">{{ timeLabel(connectivity) }}</span>
    </div>
    <p class="mt-2 text-sm text-muted-foreground">
      <template v-if="connectivity.state === 'offline'">{{ t('connectivity.notice.offlineBody', { clock: clock(connectivity.since) }) }}</template>
      <template v-else-if="connectivity.state === 'stale'">{{ t('connectivity.notice.staleBody') }}</template>
      <template v-else-if="connectivity.state === 'updating'">{{ t('connectivity.notice.updatingBody') }}</template>
      <template v-else>{{ t('connectivity.reader.inactiveHint') }}</template>
    </p>
    <p v-if="connectivity.state === 'offline'" class="mt-1 text-sm">{{ t('connectivity.notice.offlineCheck') }}</p>
    <p v-else-if="connectivity.state === 'stale'" class="mt-1 text-sm">{{ t('connectivity.notice.staleCheck') }}</p>
  </div>
</template>
