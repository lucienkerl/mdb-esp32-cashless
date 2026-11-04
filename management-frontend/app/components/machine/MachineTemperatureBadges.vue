<script setup lang="ts">
import { IconTemperature } from '@tabler/icons-vue'
import {
  formatCelsius,
  isTempsStale,
  parseTempSettings,
  readingsFromDiagnostics,
  shownTemperatures,
} from '@/lib/temperatureSensors'
import { timeAgo } from '@/lib/utils'

/**
 * The temperature sensors an operator picked in the machine settings
 * (`vendingMachine.temp_sensors`, show = true), each as a small pill with
 * its name and latest reading from `embeddeds.mdb_diagnostics.temps`.
 * Renders nothing when no sensor is picked. Dimmed when the board is
 * offline or has not reported for a while.
 */
const props = defineProps<{
  /** Raw `vendingMachine.temp_sensors`. */
  settings: unknown
  /** `embeddeds.mdb_diagnostics`. */
  diagnostics?: unknown
  online?: boolean
  size?: 'sm' | 'md'
}>()

const { t } = useI18n()

const items = computed(() => shownTemperatures(
  parseTempSettings(props.settings),
  readingsFromDiagnostics(props.diagnostics),
  t('tempSensors.ntcDefault'),
))

const stale = computed(() => !props.online || isTempsStale(props.diagnostics, Date.now()))

const title = computed(() => {
  const at = (props.diagnostics as { updated_at?: unknown } | null | undefined)?.updated_at
  return typeof at === 'string' ? t('tempSensors.lastReading', { time: timeAgo(at, t) }) : t('tempSensors.noReading')
})
</script>

<template>
  <div v-if="items.length" class="flex flex-wrap items-center gap-1.5" :title="title">
    <span
      v-for="item in items"
      :key="item.id"
      class="inline-flex items-center gap-1 rounded-md border font-medium tabular-nums"
      :class="[
        size === 'md' ? 'px-2 py-0.5 text-sm' : 'px-1.5 py-px text-xs',
        stale || item.celsius === null ? 'text-muted-foreground opacity-70' : 'text-foreground',
      ]"
    >
      <IconTemperature :class="size === 'md' ? 'size-4' : 'size-3.5'" class="shrink-0 text-muted-foreground" />
      <span class="max-w-[10rem] truncate font-normal text-muted-foreground">{{ item.label }}</span>
      <span>{{ formatCelsius(item.celsius) }}</span>
    </span>
  </div>
</template>
