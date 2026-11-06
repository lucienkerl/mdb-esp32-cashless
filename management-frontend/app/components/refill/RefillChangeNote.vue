<script setup lang="ts">
import { computed, ref } from 'vue'
import { IconArrowsExchange, IconBox, IconChevronDown, IconChevronUp } from '@tabler/icons-vue'
import type { SlotChangeItem } from '@/composables/useSlotChangeRequests'
import { getProductImageUrl } from '@/composables/useProducts'
import { formatCurrency } from '@/lib/utils'
import { ageChanged } from '@/lib/slotChange'

// Packing step: a machine's change note as one violet banner ("Rebuild 3
// slots · 12, 14, 23") plus the spirals to take along, the only thing not on
// the packing list. It opens in place and is information only: every planned
// slot is packed (its goods are ticked into the box in the packing list like
// any other goods), and a slot that can't be done is skipped at the machine.

const props = defineProps<{
  items: SlotChangeItem[]
  /** Machine name, shown in the combined list. */
  machineName?: string
}>()
const { t, locale } = useI18n()
const expanded = ref(false)

const sorted = computed(() => [...props.items].sort((a, b) => a.item_number - b.item_number))
const summary = computed(() =>
  `${t('refillRebuild.rebuildCount', { n: sorted.value.length }, sorted.value.length)} · ${sorted.value.map(i => i.item_number).join(', ')}`)
const spirals = computed(() => {
  const byCap = new Map<number, number>()
  for (const i of sorted.value) {
    if (i.to_capacity !== i.from_capacity) byCap.set(i.to_capacity, (byCap.get(i.to_capacity) ?? 0) + 1)
  }
  if (byCap.size === 0) return null
  const list = [...byCap.entries()].sort((a, b) => a[0] - b[0])
    .map(([cap, count]) => t('refillRebuild.spiralFor', { count, cap }))
  return `${t('refillRebuild.takeAlong')} ${list.join(', ')}`
})
function age(n: number | null) { return n == null ? t('refillRebuild.noAgeLimit') : t('refillRebuild.ageFrom', { n }) }
</script>

<template>
  <div class="overflow-hidden rounded-xl border-[1.5px] border-violet-500/50 bg-card">
    <button type="button" class="flex w-full items-center gap-3 p-3 text-left" :aria-expanded="expanded" @click="expanded = !expanded">
      <span class="flex size-10 shrink-0 items-center justify-center rounded-full bg-violet-500/15 text-violet-700 dark:text-violet-300">
        <IconArrowsExchange class="size-5" />
      </span>
      <span class="min-w-0 flex-1">
        <span v-if="machineName" class="block font-semibold">{{ machineName }}</span>
        <span class="block text-sm text-violet-700 dark:text-violet-300">{{ summary }}</span>
        <span v-if="spirals" class="mt-0.5 flex items-center gap-1.5 text-sm font-semibold">
          <IconBox class="size-4 shrink-0" />{{ spirals }}
        </span>
      </span>
      <IconChevronUp v-if="expanded" class="size-4 shrink-0 text-muted-foreground" />
      <IconChevronDown v-else class="size-4 shrink-0 text-muted-foreground" />
    </button>

    <ul v-if="expanded">
      <li v-for="item in sorted" :key="item.id" class="flex items-start gap-3 border-t p-3">
        <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-lg bg-foreground/90 text-base font-bold tabular-nums text-background">{{ item.item_number }}</span>
        <div class="min-w-0 flex-1 space-y-1">
          <p class="flex items-center gap-2 text-sm text-muted-foreground">
            <img v-if="item.from_image_path" :src="getProductImageUrl(item.from_image_path)" alt="" class="size-6 rounded object-cover opacity-50" />
            {{ item.from_name ?? t('slotPlan.empty') }}
          </p>
          <p class="flex items-center gap-2 font-semibold">
            <img v-if="item.to_image_path" :src="getProductImageUrl(item.to_image_path)" alt="" class="size-6 rounded object-cover" />
            <span v-else-if="!item.to_product_id" class="size-6 rounded border-[1.5px] border-dashed border-muted-foreground" />
            {{ item.to_name ?? t('refillRebuild.emptySlot') }}
          </p>
          <p class="flex flex-wrap gap-1.5 text-xs font-semibold tabular-nums">
            <span v-if="item.to_capacity !== item.from_capacity" class="rounded-md bg-orange-500/15 px-1.5 py-0.5 text-orange-700 dark:text-orange-400">{{ t('refillRebuild.spiralTag', { n: item.to_capacity }) }}</span>
            <span v-if="item.to_product_id && item.to_price != null && item.to_price !== item.from_price" class="rounded-md bg-blue-500/15 px-1.5 py-0.5 text-blue-700 dark:text-blue-400">{{ formatCurrency(item.to_price, locale) }}</span>
            <span v-if="ageChanged(item)" class="rounded-md bg-red-500/15 px-1.5 py-0.5 text-red-700 dark:text-red-400">{{ age(item.to_min_age) }}</span>
          </p>
        </div>
      </li>
    </ul>
  </div>
</template>
