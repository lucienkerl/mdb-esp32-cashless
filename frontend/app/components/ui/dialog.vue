<script setup lang="ts">
import { ref, watch } from 'vue'
import { cn } from '@/lib/utils'

interface Props {
  open?: boolean
  class?: string
}

const props = defineProps<Props>()
const emit = defineEmits<{
  'update:open': [value: boolean]
}>()

const isOpen = ref(props.open || false)

watch(() => props.open, (newVal) => {
  isOpen.value = newVal || false
})

function close() {
  isOpen.value = false
  emit('update:open', false)
}

// Prevent body scroll when dialog is open
watch(isOpen, (open) => {
  if (typeof document !== 'undefined') {
    if (open) {
      document.body.style.overflow = 'hidden'
    } else {
      document.body.style.overflow = ''
    }
  }
})
</script>

<template>
  <Teleport to="body">
    <Transition
      enter-active-class="transition-opacity duration-200"
      enter-from-class="opacity-0"
      enter-to-class="opacity-100"
      leave-active-class="transition-opacity duration-200"
      leave-from-class="opacity-100"
      leave-to-class="opacity-0"
    >
      <div
        v-if="isOpen"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="close"
      >
        <!-- Backdrop -->
        <div class="absolute inset-0 bg-background/80 backdrop-blur-sm" />
        
        <!-- Dialog Content -->
        <div
          :class="cn(
            'relative z-50 bg-background rounded-lg border shadow-lg max-h-[90vh] overflow-auto',
            'w-full max-w-lg mx-4',
            props.class
          )"
          role="dialog"
          aria-modal="true"
        >
          <slot :close="close" />
        </div>
      </div>
    </Transition>
  </Teleport>
</template>
