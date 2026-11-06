<script setup lang="ts">
import type { Connectivity } from '@/lib/connectivity'
import { chipClass, dotClass } from '@/composables/useConnectivity'

/** Dot + word for a device's connectivity — never colour alone. */
const props = withDefaults(defineProps<{
  connectivity: Connectivity
  size?: 'sm' | 'md'
}>(), { size: 'md' })

const { t } = useI18n()
</script>

<template>
  <span
    class="inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full font-medium"
    :class="[chipClass(props.connectivity.state), props.size === 'sm' ? 'px-2 py-0.5 text-[11px]' : 'px-2.5 py-0.5 text-xs']"
  >
    <span class="inline-block size-1.5 rounded-full" :class="dotClass(props.connectivity.state)" />
    {{ t(`connectivity.state.${props.connectivity.state}`) }}
  </span>
</template>
