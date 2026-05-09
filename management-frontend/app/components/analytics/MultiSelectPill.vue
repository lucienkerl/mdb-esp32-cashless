<!--
  MultiSelectPill
  ---------------
  Generic multi-select Popover/Command pill used by AnalyticsFilterBar.
  Three call sites (machines / categories / VAT rates) share this shape;
  the differences (search input visibility, max badges, badge label) are
  expressed via props.

  Usage:
    <MultiSelectPill
      v-model="filter.machines"
      :options="machines.map(m => ({ value: m.id, label: m.name }))"
      placeholder="Machines"
      search-placeholder="Search machines…"
      :max-visible-badges="2"
      testid="filter-machines"
    />

  Notes:
    - `v-model` binds an array of T values. Selection toggles emit a NEW
      array via `update:modelValue` — useState-backed refs accept this.
    - Omit `searchPlaceholder` (or pass empty string) to hide CommandInput.
    - Omit `maxVisibleBadges` to render every selected badge.
    - `@open` fires when the popover transitions to open (lazy-load hook).
-->
<script setup lang="ts" generic="T extends string | number">
import { ref, computed, watch } from 'vue'
import { Check, ChevronsUpDown, X } from 'lucide-vue-next'
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover'
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandList,
} from '@/components/ui/command'
import Badge from '@/components/ui/badge/Badge.vue'
import MultiProductCommandItem from '@/components/MultiProductCommandItem.vue'
import { cn } from '@/lib/utils'

const props = defineProps<{
  modelValue: T[]
  options: { value: T; label: string }[]
  placeholder: string
  searchPlaceholder?: string
  emptyLabel?: string
  maxVisibleBadges?: number
  testid?: string
}>()

const emit = defineEmits<{
  'update:modelValue': [value: T[]]
  open: []
}>()

const popoverOpen = ref(false)

watch(popoverOpen, (open) => {
  if (open) emit('open')
})

const selectedSet = computed(() => new Set(props.modelValue))
const selectedOptions = computed(() =>
  props.options.filter((o) => selectedSet.value.has(o.value)),
)
const visibleBadges = computed(() => {
  const max = props.maxVisibleBadges
  if (max === undefined || max < 0) return selectedOptions.value
  return selectedOptions.value.slice(0, max)
})
const overflowCount = computed(() => {
  const max = props.maxVisibleBadges
  if (max === undefined || max < 0) return 0
  return Math.max(0, selectedOptions.value.length - max)
})

function toggle(value: T) {
  const next = new Set(props.modelValue)
  if (next.has(value)) next.delete(value)
  else next.add(value)
  emit('update:modelValue', Array.from(next) as T[])
}

function removeOne(value: T, event: Event) {
  event.stopPropagation()
  emit('update:modelValue', props.modelValue.filter((v) => v !== value))
}
</script>

<template>
  <Popover v-model:open="popoverOpen">
    <PopoverTrigger as-child>
      <button
        type="button"
        role="combobox"
        :aria-expanded="popoverOpen"
        :data-testid="testid"
        :class="cn(
          'flex h-8 min-w-[8rem] max-w-[20rem] items-center justify-between gap-2 rounded-md border border-input bg-background px-2 text-sm shadow-sm hover:bg-accent/50 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring',
        )"
      >
        <div class="flex flex-1 flex-wrap items-center gap-1 overflow-hidden">
          <template v-if="selectedOptions.length === 0">
            <span class="text-muted-foreground">{{ placeholder }}</span>
          </template>
          <template v-else>
            <Badge
              v-for="o in visibleBadges"
              :key="String(o.value)"
              variant="secondary"
              class="gap-1"
            >
              <span class="max-w-[8rem] truncate">{{ o.label }}</span>
              <span
                role="button"
                tabindex="-1"
                class="ml-1 rounded-sm opacity-70 hover:opacity-100"
                @click="(e) => removeOne(o.value, e)"
              >
                <X class="size-3" />
              </span>
            </Badge>
            <span
              v-if="overflowCount > 0"
              class="text-xs text-muted-foreground"
            >+{{ overflowCount }}</span>
          </template>
        </div>
        <ChevronsUpDown class="size-4 shrink-0 opacity-50" />
      </button>
    </PopoverTrigger>
    <PopoverContent class="w-[--reka-popover-trigger-width] min-w-[12rem] p-0" align="start">
      <Command>
        <CommandInput
          v-if="searchPlaceholder"
          :placeholder="searchPlaceholder"
        />
        <CommandList>
          <CommandEmpty>
            <span class="text-sm text-muted-foreground">{{ emptyLabel ?? 'No results' }}</span>
          </CommandEmpty>
          <CommandGroup>
            <MultiProductCommandItem
              v-for="o in options"
              :key="String(o.value)"
              :value="o.label"
              @select="toggle(o.value)"
            >
              <Check
                :class="cn('mr-2 size-4', selectedSet.has(o.value) ? 'opacity-100' : 'opacity-0')"
              />
              {{ o.label }}
            </MultiProductCommandItem>
          </CommandGroup>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
