<script setup lang="ts">
import { computed } from 'vue'
import type { NetworkKind, SignalTone } from '@/lib/network'

/**
 * Signal strength glyph: WiFi fan (dot + 3 arcs) or cellular bars (4), both
 * with 0–4 filled steps. Colour only speaks up for a weak or missing signal.
 */
const props = withDefaults(defineProps<{
  kind: NetworkKind
  level: number | null
  tone: SignalTone | null
  /** Greyed out: last known value of a device that is offline. */
  muted?: boolean
  size?: number
}>(), { muted: false, size: 16 })

const fill = computed(() => {
  if (props.muted) return 'text-muted-foreground'
  switch (props.tone) {
    case 'weak': return 'text-amber-600 dark:text-amber-400'
    case 'bad': return 'text-red-600 dark:text-red-400'
    case 'ok': return 'text-green-600 dark:text-green-400'
    default: return 'text-muted-foreground'
  }
})

const level = computed(() => props.level ?? 0)
/** WiFi: step 1 = dot, 2–4 = arcs from the inside out. A level of 0 still draws the dot (in red). */
const wifiOn = (step: number) => props.level != null && (step === 1 ? true : level.value >= step)
const barOn = (step: number) => props.level != null && level.value >= step
</script>

<template>
  <svg
    v-if="kind === 'wifi'"
    :width="size" :height="size" viewBox="0 0 16 16" fill="none" stroke-linecap="round" stroke-width="1.8"
    aria-hidden="true" :class="fill"
  >
    <path d="M0.8 5.6A10.2 10.2 0 0 1 15.2 5.6" stroke="currentColor" :class="wifiOn(4) ? '' : 'opacity-25'" />
    <path d="M2.9 7.9A7.2 7.2 0 0 1 13.1 7.9" stroke="currentColor" :class="wifiOn(3) ? '' : 'opacity-25'" />
    <path d="M5.2 10.2A4 4 0 0 1 10.8 10.2" stroke="currentColor" :class="wifiOn(2) ? '' : 'opacity-25'" />
    <circle cx="8" cy="13" r="1.6" fill="currentColor" :class="wifiOn(1) ? '' : 'opacity-25'" />
  </svg>
  <span
    v-else
    class="inline-flex items-end gap-px" :class="fill" :style="{ height: `${size * 0.85}px` }" aria-hidden="true"
  >
    <span
      v-for="i in 4" :key="i"
      class="rounded-[1px] bg-current" :class="barOn(i) ? '' : 'opacity-25'"
      :style="{ width: `${Math.max(2, Math.round(size / 5.5))}px`, height: `${i * 25}%` }"
    />
  </span>
</template>
