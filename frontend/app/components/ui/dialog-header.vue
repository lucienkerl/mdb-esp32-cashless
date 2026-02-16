<script setup lang="ts">
import { cn } from '@/lib/utils'

interface Props {
  class?: string
}

const props = defineProps<Props>()
</script>

<template>
  <div :class="cn('flex flex-col space-y-1.5 text-center sm:text-left p-6 pb-4', props.class)">
    <slot />
  </div>
</template>
