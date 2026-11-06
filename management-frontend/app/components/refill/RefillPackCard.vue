<script setup lang="ts">
import { computed } from 'vue'
import { getProductImageUrl } from '@/composables/useProducts'
import type { PackLine } from '@/composables/useRefillWizard'
import { formatCurrency } from '@/lib/utils'
import RefillPackLine from '@/components/refill/RefillPackLine.vue'

// Packing step: one product with one line per machine (or the one line of
// the machine card). No tick of its own: a card is done when every line is.

const props = defineProps<{
  productName: string
  imagePath: string | null
  sellprice: number | null
  lines: PackLine[]
  /** Warehouse stock of the product, null without a warehouse. */
  stock: number | null
  showMachines?: boolean
}>()
const emit = defineEmits<{
  toggle: [line: PackLine]
  set: [line: PackLine, value: number]
}>()
const { t, locale } = useI18n()

const open = computed(() => props.lines.filter(l => !l.unavailable))
const allTicked = computed(() => open.value.length > 0 && open.value.every(l => l.ticked))
const short = computed(() => open.value.some(l => l.ticked && l.shortfall > 0))
const total = computed(() => props.lines.reduce((s, l) => s + l.total, 0))
</script>

<template>
  <div
    class="rounded-xl border-2 bg-card transition-colors"
    :class="[
      short ? 'border-orange-500/55' : allTicked ? 'border-green-600/45' : 'border-transparent ring-1 ring-border',
      open.length === 0 ? 'opacity-50' : '',
    ]"
  >
    <div class="flex items-center gap-3 px-3 py-2.5">
      <img
        v-if="imagePath"
        :src="getProductImageUrl(imagePath)"
        :alt="productName"
        class="size-11 shrink-0 rounded-lg object-cover"
      />
      <span v-else class="flex size-11 shrink-0 items-center justify-center rounded-lg bg-muted text-sm text-muted-foreground">
        {{ productName.charAt(0) }}
      </span>
      <div class="min-w-0 flex-1">
        <p class="text-sm font-semibold leading-snug" :class="open.length === 0 ? 'text-muted-foreground' : ''">{{ productName }}</p>
        <p class="flex flex-wrap items-center gap-x-2 text-xs text-muted-foreground tabular-nums">
          <span v-if="stock === 0" class="text-red-600 dark:text-red-400">{{ t('machines.notInStock') }}</span>
          <span v-else-if="stock != null">{{ t('refillRebuild.inStock', { n: stock }) }}</span>
          <span v-if="sellprice != null">{{ formatCurrency(sellprice, locale) }}</span>
        </p>
      </div>
      <span
        v-if="lines.length > 1"
        class="shrink-0 rounded-full bg-blue-500/10 px-2.5 py-1 text-base font-bold tabular-nums text-blue-600 dark:text-blue-400"
      >{{ total }}&times;</span>
    </div>
    <div v-for="line in lines" :key="line.machine_id" class="border-t py-1 pl-1 pr-3">
      <RefillPackLine
        :line="line"
        :show-machine="showMachines"
        @toggle="emit('toggle', line)"
        @set="emit('set', line, $event)"
      />
    </div>
  </div>
</template>
