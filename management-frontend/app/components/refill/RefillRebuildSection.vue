<script setup lang="ts">
import { ref } from 'vue'
import { IconArrowsExchange, IconCheck, IconMinus, IconPlus } from '@tabler/icons-vue'
import { getProductImageUrl } from '@/composables/useProducts'
import { changesPrice, needsConfirmation, type RebuildSlot } from '@/composables/useRefillWizard'
import { formatCurrency } from '@/lib/utils'
import { ageChanged } from '@/lib/slotChange'

// At the machine: the slots of the change note as a short list, one row per
// slot, ticked off like the products when packing (iOS `RefillRebuildSection`).
// A row shows the slot, the new product instead of the old one, what to watch
// for (spiral, price, age) and the units going in. One tap on the circle marks
// the slot done; a new price or age limit is confirmed once on that tap.
// Tapping the row opens the amounts and "Not possible today". Nothing is
// booked until the machine is confirmed; leftovers ride along in the van and
// are booked back at the end of the tour (RefillTourLeftovers).

const props = defineProps<{
  slots: RebuildSlot[]
  /** Most units a slot can get (goods meant for the rebuild only). */
  maxFilled: (itemId: string) => number
  /** Skipped slots whose old product was to move into this slot. */
  skippedSources: (itemId: string) => number[]
  /** The change note was withdrawn in the office: nothing is rebuilt here. */
  withdrawn?: boolean
}>()
const emit = defineEmits<{
  (e: 'removed', itemId: string, value: number): void
  (e: 'filled', itemId: string, value: number): void
  (e: 'action', itemId: string, value: 'done' | 'skip' | null): void
  (e: 'price', itemId: string, value: boolean): void
  (e: 'age', itemId: string, value: boolean): void
}>()
const { t, locale } = useI18n()

/** The slot whose amounts are open. */
const expanded = ref<string | null>(null)
/** The slot whose price / age setting is being confirmed before "done". */
const confirming = ref<string | null>(null)

function tick(s: RebuildSlot) {
  if (s.action) {
    emit('action', s.item.id, null)
  } else if (needsConfirmation(s)) {
    confirming.value = confirming.value === s.item.id ? null : s.item.id
  } else {
    emit('action', s.item.id, 'done')
  }
}
function confirmDone(s: RebuildSlot) {
  if (changesPrice(s.item) && !s.price_set) emit('price', s.item.id, true)
  if (ageChanged(s.item) && !s.age_set) emit('age', s.item.id, true)
  emit('action', s.item.id, 'done')
  confirming.value = null
}
function toggleOpen(id: string) {
  expanded.value = expanded.value === id ? null : id
}
function skip(id: string) {
  emit('action', id, 'skip')
  expanded.value = null
  confirming.value = null
}
function skippedText(list: number[]) {
  return list.length === 1
    ? t('refillRebuild.skippedSourceOne', { n: list[0] })
    : t('refillRebuild.skippedSourceMany', { list: list.join(', ') })
}
function age(n: number | null) { return n == null ? t('refillRebuild.noAgeLimit') : t('refillRebuild.ageFrom', { n }) }
function last(id: string) { return props.slots[props.slots.length - 1]?.item.id === id }
</script>

<template>
  <div class="space-y-2">
    <p v-if="withdrawn" class="rounded-lg border border-orange-500/50 bg-orange-500/10 p-3 text-sm">{{ t('refillRebuild.withdrawnHere') }}</p>

    <template v-else>
      <p class="flex items-center gap-1.5 px-1 text-xs font-semibold uppercase tracking-wide text-violet-700 dark:text-violet-300">
        <IconArrowsExchange class="size-4" />
        {{ t('refillRebuild.rebuildRow') }}
      </p>

      <div class="overflow-hidden rounded-xl border bg-card">
        <div v-for="s in slots" :key="s.item.id" :class="[last(s.item.id) ? '' : 'border-b', s.action === 'skip' ? 'opacity-70' : '']">
          <div class="flex items-center gap-2 px-2 py-2">
            <!-- The circle: open → done (price / age confirmed first), done or skipped → open again -->
            <button
              type="button"
              class="flex size-11 shrink-0 items-center justify-center"
              :aria-pressed="s.action === 'done'"
              :aria-label="t('refillRebuild.slotDone', { n: s.item.item_number })"
              @click="tick(s)"
            >
              <span
                class="flex size-7 items-center justify-center rounded-full border-2 transition-colors"
                :class="s.action === 'done' ? 'border-green-600 bg-green-600 text-white' : 'border-muted-foreground/40'"
              >
                <IconCheck v-if="s.action === 'done'" class="size-4" stroke-width="3" />
                <IconMinus v-else-if="s.action === 'skip'" class="size-4 text-muted-foreground" stroke-width="3" />
              </span>
            </button>

            <button type="button" class="flex min-w-0 flex-1 items-center gap-2.5 rounded-lg py-0.5 text-left hover:bg-muted/40" @click="toggleOpen(s.item.id)">
              <span class="inline-flex size-9 shrink-0 items-center justify-center rounded-lg text-sm font-bold tabular-nums" :class="s.action === 'skip' ? 'bg-muted text-muted-foreground' : 'bg-foreground/90 text-background'">{{ s.item.item_number }}</span>
              <template v-if="s.action === 'skip'">
                <img v-if="s.item.from_image_path" :src="getProductImageUrl(s.item.from_image_path)" alt="" class="size-10 shrink-0 rounded object-cover" />
              </template>
              <img v-else-if="s.item.to_image_path" :src="getProductImageUrl(s.item.to_image_path)" alt="" class="size-10 shrink-0 rounded object-cover" />
              <span class="min-w-0 flex-1">
                <template v-if="s.action === 'skip'">
                  <span class="block text-sm font-semibold">{{ t('refillRebuild.stays', { name: s.item.from_name ?? t('slotPlan.empty') }) }}</span>
                  <span class="block text-xs text-muted-foreground">{{ t('refillRebuild.comesAgain') }}</span>
                </template>
                <template v-else>
                  <span class="block text-sm font-semibold" :class="s.action === 'done' ? 'text-muted-foreground' : ''">{{ s.item.to_name ?? t('refillRebuild.emptySlot') }}</span>
                  <span v-if="s.item.from_product_id" class="block text-xs text-muted-foreground">{{ t('refillRebuild.instead', { name: s.item.from_name ?? '' }) }}</span>
                  <span v-if="s.item.to_capacity !== s.item.from_capacity || changesPrice(s.item) || ageChanged(s.item)" class="mt-0.5 flex flex-wrap gap-1 text-[11px] font-semibold tabular-nums">
                    <span v-if="s.item.to_capacity !== s.item.from_capacity" class="rounded bg-orange-500/15 px-1.5 py-px text-orange-700 dark:text-orange-400">{{ t('refillRebuild.spiralTag', { n: s.item.to_capacity }) }}</span>
                    <span v-if="changesPrice(s.item)" class="rounded bg-blue-500/15 px-1.5 py-px text-blue-700 dark:text-blue-400">{{ formatCurrency(s.item.to_price, locale) }}</span>
                    <span v-if="ageChanged(s.item)" class="rounded bg-red-500/15 px-1.5 py-px text-red-700 dark:text-red-400">{{ age(s.item.to_min_age) }}</span>
                  </span>
                </template>
              </span>
              <span
                v-if="s.action !== 'skip' && s.item.to_product_id"
                class="inline-flex h-10 min-w-12 shrink-0 items-center justify-center rounded-lg px-1.5 text-lg font-bold tabular-nums text-violet-700 dark:text-violet-300"
                :class="expanded === s.item.id ? 'bg-violet-500/25' : 'bg-violet-500/10'"
              >+{{ s.filled }}</span>
            </button>
          </div>

          <!-- Price / age set on the machine? Asked once when ticking. -->
          <div v-if="confirming === s.item.id && !s.action" class="mx-2 mb-2 space-y-2 rounded-lg bg-blue-500/10 p-3 text-sm">
            <p v-if="changesPrice(s.item) && !s.price_set">{{ t('refillRebuild.priceSet', { n: s.item.item_number }) }} <b class="tabular-nums">{{ formatCurrency(s.item.to_price, locale) }}</b></p>
            <p v-if="ageChanged(s.item) && !s.age_set">{{ t('refillRebuild.ageSet', { n: s.item.item_number }) }}: <b>{{ age(s.item.to_min_age) }}</b></p>
            <div class="flex gap-2">
              <button type="button" class="inline-flex h-10 flex-1 items-center justify-center gap-1.5 rounded-lg bg-green-600 font-medium text-white" @click="confirmDone(s)">
                <IconCheck class="size-4" />{{ t('refillRebuild.yesSetOnMachine') }}
              </button>
              <button type="button" class="h-10 rounded-lg border px-3" @click="confirming = null">{{ t('common.cancel') }}</button>
            </div>
          </div>

          <!-- Amounts and "not possible today" -->
          <div v-if="expanded === s.item.id" class="space-y-2 pb-3 pl-14 pr-3">
            <template v-if="s.action !== 'skip'">
              <div v-if="s.item.from_product_id" class="flex items-center gap-2">
                <span class="min-w-0 flex-1 text-sm">{{ t('refillRebuild.takeOut', { name: s.item.from_name ?? '' }) }}</span>
                <button type="button" class="inline-flex size-10 items-center justify-center rounded-lg border disabled:opacity-30" :disabled="s.removed <= 0" @click="emit('removed', s.item.id, s.removed - 1)"><IconMinus class="size-4" /></button>
                <span class="min-w-8 text-center text-lg font-bold tabular-nums">{{ s.removed }}</span>
                <button type="button" class="inline-flex size-10 items-center justify-center rounded-lg border" @click="emit('removed', s.item.id, s.removed + 1)"><IconPlus class="size-4" /></button>
              </div>
              <div v-if="s.item.to_product_id" class="flex items-center gap-2">
                <span class="min-w-0 flex-1 text-sm">{{ t('refillRebuild.putIn', { name: s.item.to_name ?? '' }) }}</span>
                <button type="button" class="inline-flex size-10 items-center justify-center rounded-lg border disabled:opacity-30" :disabled="s.filled <= 0" @click="emit('filled', s.item.id, s.filled - 1)"><IconMinus class="size-4" /></button>
                <span class="min-w-8 text-center text-lg font-bold tabular-nums">{{ s.filled }}</span>
                <button type="button" class="inline-flex size-10 items-center justify-center rounded-lg border disabled:opacity-30" :disabled="s.filled >= maxFilled(s.item.id)" @click="emit('filled', s.item.id, s.filled + 1)"><IconPlus class="size-4" /></button>
              </div>
              <p v-if="s.item.to_product_id" class="text-xs text-muted-foreground tabular-nums">{{ t('refillRebuild.fillSource', { moved: s.moved, van: s.from_van }) }}</p>
              <p v-if="skippedSources(s.item.id).length > 0 && s.filled < s.item.to_capacity" class="text-xs text-orange-600 dark:text-orange-400">{{ skippedText(skippedSources(s.item.id)) }}</p>
              <button type="button" class="h-10 w-full rounded-lg border text-sm text-muted-foreground hover:bg-muted" @click="skip(s.item.id)">{{ t('refillRebuild.notPossibleToday') }}</button>
            </template>
            <button v-else type="button" class="h-10 w-full rounded-lg border text-sm hover:bg-muted" @click="emit('action', s.item.id, null)">{{ t('refillRebuild.rebuildAfterAll') }}</button>
          </div>
        </div>
      </div>

      <p v-if="slots.every(s => s.action)" class="px-1 text-xs text-muted-foreground">{{ t('refillRebuild.takeAlongHint') }}</p>
    </template>
  </div>
</template>
