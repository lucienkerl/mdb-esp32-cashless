<script setup lang="ts">
import { IconTrash } from '@tabler/icons-vue'
import {
  formatCelsius,
  knownSensors,
  MAX_SENSOR_NAME_LENGTH,
  NTC_SENSOR_ID,
  sensorLabel,
  upsertTempSetting,
  type TempReading,
  type TempSensorSetting,
} from '@/lib/temperatureSensors'
import { oneWireFamily } from '@/lib/ioTest'

/**
 * Machine settings section: name each temperature sensor the board reports
 * (onboard NTC, DS18B20 probes) and pick the ones shown next to the machine
 * name. Edits `vendingMachine.temp_sensors` through v-model; the modal saves.
 */
const props = defineProps<{
  modelValue: TempSensorSetting[]
  /** Latest readings (mdb-log diagnostics, I/O test snapshot). */
  readings: TempReading[]
}>()

const emit = defineEmits<{ 'update:modelValue': [value: TempSensorSetting[]] }>()

const { t } = useI18n()

const sensors = computed(() => knownSensors(props.modelValue, props.readings))

function setName(id: string, name: string) {
  emit('update:modelValue', upsertTempSetting(props.modelValue, id, { name }))
}
function setShow(id: string, show: boolean) {
  emit('update:modelValue', upsertTempSetting(props.modelValue, id, { show }))
}
function forget(id: string) {
  emit('update:modelValue', props.modelValue.filter(s => s.id !== id))
}

/** "TH1 · onboard" or "DS18B20 · bus 1 · 4200000025040628". */
function detail(s: { id: string; reading: TempReading | null }): string {
  if (s.id === NTC_SENSOR_ID) return t('tempSensors.ntcDetail')
  const parts = [oneWireFamily(s.id) ?? '1-Wire']
  if (s.reading?.bus) parts.push(t('tempSensors.bus', { n: s.reading.bus }))
  parts.push(s.id)
  return parts.join(' · ')
}
</script>

<template>
  <div class="rounded-xl border bg-card p-4">
    <span class="text-sm font-medium">{{ t('tempSensors.title') }}</span>
    <p class="mt-1 text-[10px] text-muted-foreground">{{ t('tempSensors.hint') }}</p>

    <p v-if="sensors.length === 0" class="mt-3 text-xs text-muted-foreground">{{ t('tempSensors.none') }}</p>

    <ul v-else class="mt-3 space-y-3">
      <li v-for="s in sensors" :key="s.id" class="flex items-start gap-3">
        <input
          type="checkbox"
          class="mt-2 h-4 w-4 shrink-0 rounded border-input"
          :checked="s.show"
          :title="t('tempSensors.show')"
          :aria-label="t('tempSensors.show')"
          @change="setShow(s.id, ($event.target as HTMLInputElement).checked)"
        />
        <div class="min-w-0 flex-1">
          <input
            type="text"
            :value="s.name"
            :maxlength="MAX_SENSOR_NAME_LENGTH"
            :placeholder="sensorLabel(s.id, '', t('tempSensors.ntcDefault'))"
            :aria-label="t('tempSensors.name')"
            class="flex h-8 w-full rounded-md border bg-transparent px-2 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            @input="setName(s.id, ($event.target as HTMLInputElement).value)"
          />
          <p class="mt-1 truncate font-mono text-[10px] text-muted-foreground" :title="s.id">{{ detail(s) }}</p>
        </div>
        <span class="mt-1.5 w-16 shrink-0 text-right text-sm tabular-nums" :class="s.reading ? '' : 'text-xs text-muted-foreground'">
          {{ s.reading ? formatCelsius(s.reading.celsius) : t('tempSensors.notSeen') }}
        </span>
        <button
          v-if="!s.reading && modelValue.some(m => m.id === s.id)"
          type="button"
          class="mt-1 shrink-0 rounded p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
          :title="t('tempSensors.forget')"
          :aria-label="t('tempSensors.forget')"
          @click="forget(s.id)"
        >
          <IconTrash class="size-4" />
        </button>
      </li>
    </ul>
  </div>
</template>
