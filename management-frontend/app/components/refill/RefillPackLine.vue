<script setup lang="ts">
import { computed } from 'vue'
import { IconArrowsExchange, IconMinus, IconPlus } from '@tabler/icons-vue'
import type { PackLine } from '@/composables/useRefillWizard'

// Packing step: one machine's line of a product. A big tick (everything of
// the line lies in the box), what it is for ("3 refill + ⇄ 5 rebuild ·
// slot 57") and one stepper for the whole amount. Packing less takes it off
// the refill first; the rebuilt slots keep their goods as long as possible.

const props = defineProps<{
  line: PackLine
  /** Name the machine on the line (combined list). */
  showMachine?: boolean
}>()
const emit = defineEmits<{
  toggle: []
  set: [value: number]
}>()
const { t } = useI18n()

const slotText = computed(() => props.line.slots.length === 1
  ? t('refillRebuild.slotOne', { n: props.line.slots[0] })
  : t('refillRebuild.slotMany', { list: props.line.slots.join(', ') }))
</script>

<template>
  <div class="flex items-center gap-1.5" :class="line.unavailable ? 'opacity-60' : ''">
    <button
      type="button"
      class="flex min-h-11 min-w-0 flex-1 items-center gap-2 rounded-lg text-left transition-colors hover:bg-muted/50 disabled:cursor-not-allowed disabled:hover:bg-transparent"
      :disabled="line.unavailable"
      :aria-pressed="line.ticked"
      :aria-label="t('refillRebuild.inBoxLabel')"
      @click="emit('toggle')"
    >
      <span class="flex size-11 shrink-0 items-center justify-center">
        <span
          class="flex size-7 items-center justify-center rounded-md border-2 transition-colors"
          :class="line.unavailable
            ? 'border-red-400/40 bg-muted'
            : line.ticked ? 'border-green-600 bg-green-600 text-white' : 'border-muted-foreground/40'"
        >
          <svg v-if="line.ticked" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" class="size-4"><polyline points="20 6 9 17 4 12" /></svg>
        </span>
      </span>
      <span class="min-w-0 flex-1 py-1">
        <span v-if="showMachine" class="block text-sm">{{ line.machine_name }}</span>
        <span class="block text-xs leading-snug">
          <template v-if="line.refill_need > 0">
            <span v-if="line.has_refill" class="text-muted-foreground">{{ t('refillRebuild.lineRefill', { n: line.refill }) }}</span>
            <span v-else class="text-red-600 dark:text-red-400">{{ t('refillRebuild.lineNoStock') }}</span>
          </template>
          <span v-if="line.refill_need > 0 && line.rebuild_need > 0" class="text-muted-foreground"> + </span>
          <span v-if="line.rebuild_need > 0" class="font-semibold text-violet-700 dark:text-violet-300">
            <IconArrowsExchange class="inline size-3.5 -translate-y-px" />
            {{ t('refillRebuild.lineRebuild', { n: line.rebuild }) }} · {{ slotText }}
          </span>
          <template v-if="line.shortfall > 0 && !line.unavailable">
            <span class="text-muted-foreground"> · </span>
            <span class="font-semibold text-orange-600 dark:text-orange-400">{{ t('refillRebuild.stillMissing', { n: line.shortfall }, line.shortfall) }}</span>
          </template>
        </span>
      </span>
    </button>

    <div class="flex shrink-0 items-center gap-1.5">
      <button
        type="button"
        class="inline-flex size-11 items-center justify-center rounded-xl border-[1.5px] transition-colors active:bg-muted disabled:opacity-30"
        :aria-label="t('refillRebuild.packLess')"
        :disabled="line.unavailable || line.total <= 0"
        @click="emit('set', line.total - 1)"
      ><IconMinus class="size-4" /></button>
      <span
        class="inline-flex h-11 min-w-11 items-center justify-center rounded-xl px-1.5 text-lg font-bold tabular-nums"
        :class="line.unavailable ? 'bg-muted text-muted-foreground' : 'bg-blue-500/10 text-blue-600 dark:text-blue-400'"
      >{{ line.total }}</span>
      <button
        type="button"
        class="inline-flex size-11 items-center justify-center rounded-xl border-[1.5px] transition-colors active:bg-muted disabled:opacity-30"
        :aria-label="t('refillRebuild.packMore')"
        :disabled="line.unavailable || line.total >= line.max_quantity"
        @click="emit('set', line.total + 1)"
      ><IconPlus class="size-4" /></button>
    </div>
  </div>
</template>
