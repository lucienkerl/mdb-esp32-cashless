<script setup lang="ts">
import { IconArrowsExchange, IconCoins, IconDevices, IconDownload, IconDots, IconReceipt, IconSettings, IconTrash } from '@tabler/icons-vue'
import { onClickOutside } from '@vueuse/core'

const emit = defineEmits<{
  (e: 'expense'): void
  (e: 'correction'): void
  (e: 'changeFloat'): void
  (e: 'manageMachines'): void
  (e: 'exportPdf'): void
  (e: 'openSettings'): void
  (e: 'delete'): void
}>()

const { t } = useI18n()
const moreOpen = ref(false)
const moreRef = ref<HTMLElement | null>(null)

onClickOutside(moreRef, () => { moreOpen.value = false })
</script>

<template>
  <div class="flex flex-wrap items-center gap-2">
    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('expense')"
    >
      <IconReceipt class="size-4" />
      {{ t('cashBook.recordExpense') }}
    </button>

    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('changeFloat')"
    >
      <IconCoins class="size-4" />
      {{ t('cashBook.recordChangeFloat') }}
    </button>

    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('correction')"
    >
      <IconArrowsExchange class="size-4" />
      {{ t('cashBook.recordCorrection') }}
    </button>

    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('manageMachines')"
    >
      <IconDevices class="size-4" />
      {{ t('cashBook.assignMachines') }}
    </button>

    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('exportPdf')"
    >
      <IconDownload class="size-4" />
      {{ t('cashBook.exportPdf') }}
    </button>

    <div ref="moreRef" class="relative">
      <button
        class="inline-flex h-9 items-center gap-1 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
        @click="moreOpen = !moreOpen"
      >
        <IconDots class="size-4" />
        {{ t('cashBook.more') }}
      </button>
      <div
        v-if="moreOpen"
        class="absolute right-0 top-full mt-1 z-10 w-56 rounded-md border bg-popover shadow-md"
      >
        <button
          class="flex w-full items-center gap-2 px-3 py-2 text-sm hover:bg-accent"
          @click="moreOpen = false; emit('openSettings')"
        >
          <IconSettings class="size-4" />
          {{ t('cashBook.settings') }}
        </button>
        <button
          class="flex w-full items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-900/20"
          @click="moreOpen = false; emit('delete')"
        >
          <IconTrash class="size-4" />
          {{ t('cashBook.deleteCashBook') }}
        </button>
      </div>
    </div>
  </div>
</template>
