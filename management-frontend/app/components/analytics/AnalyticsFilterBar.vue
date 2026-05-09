<!--
  AnalyticsFilterBar
  -------------------
  Global filter bar for the Analytics dashboard. Reads useAnalyticsFilters()
  and mutates filter.value directly — no events, downstream consumers watch
  the shared composable state.

  Channel mapping (sales.channel db column):
    db value      -> label
    'cashless'    -> "Cashless"
    'mqtt'        -> "Cashless"   (legacy alias, treated as cashless)
    'cash'        -> "Cash"
    'card'        -> "Card"

  TODO i18n: all visible strings in this component are hardcoded English so
  Task 3.4 isn't blocked on missing translation keys. Chunk 7 (polish) will
  i18n-ify them — search for "TODO i18n" to find every literal.
-->
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useSupabaseClient } from '#imports'
import {
  Calendar as CalendarIcon,
  RotateCcw,
  Save,
  Trash2,
} from 'lucide-vue-next'
import { Button } from '@/components/ui/button'
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover'
import Badge from '@/components/ui/badge/Badge.vue'
import { Switch } from '@/components/ui/switch'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import MultiSelectPill from '@/components/analytics/MultiSelectPill.vue'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'
import { useOrganization } from '@/composables/useOrganization'

type Preset = 'today' | '7d' | '30d' | '90d' | 'ytd' | '12m' | 'custom'

const { filter, reset, savePreset, loadPreset, listPresets, deletePreset } =
  useAnalyticsFilters()
const supabase = useSupabaseClient()
const { organization } = useOrganization()

// --- options loaded on mount ---------------------------------------------
const machines = ref<{ id: string; name: string }[]>([])
const categories = ref<{ id: string; name: string }[]>([])
const vatRates = ref<number[]>([])
const vatLoaded = ref(false)

// Channel options. db value -> label. Legacy 'mqtt' rows are folded into
// the 'cashless' UI bucket but stored as the actual db value when toggled.
// TODO i18n
const CHANNEL_OPTIONS: { value: string; label: string }[] = [
  { value: 'cashless', label: 'Cashless' },
  { value: 'cash', label: 'Cash' },
  { value: 'card', label: 'Card' },
]

onMounted(async () => {
  const companyId = organization.value?.id
  if (!companyId) return

  try {
    // vendingMachine.company / product_category.company (no _id suffix).
    // See Docker/supabase/migrations/.
    const [m, c] = await Promise.all([
      supabase
        .from('vendingMachine')
        .select('id, name')
        .eq('company', companyId),
      supabase
        .from('product_category')
        .select('id, name')
        .eq('company', companyId),
    ])

    machines.value = ((m.data ?? []) as { id: string; name: string | null }[])
      .map((row) => ({ id: row.id, name: row.name ?? '(unnamed)' }))
      .sort((a, b) => a.name.localeCompare(b.name))

    categories.value = ((c.data ?? []) as { id: string; name: string | null }[])
      .map((row) => ({ id: row.id, name: row.name ?? '(unnamed)' }))
      .sort((a, b) => a.name.localeCompare(b.name))
  } catch (err) {
    // Filter bar is non-fatal — log and render with empty option lists
    console.error('[AnalyticsFilterBar] failed to load options:', err)
  }
})

// Lazy: scanning sales.tax_rate_snapshot is unbounded — only load when the
// VAT pill actually opens. Cache after the first load via vatLoaded.
async function loadVatRates() {
  if (vatLoaded.value) return
  const companyId = organization.value?.id
  if (!companyId) return
  vatLoaded.value = true
  try {
    const { data } = await supabase
      .from('sales')
      .select('tax_rate_snapshot')
      .eq('company_id', companyId)
      .not('tax_rate_snapshot', 'is', null)
      .limit(5000)
    vatRates.value = Array.from(
      new Set(
        ((data ?? []) as { tax_rate_snapshot: number | string | null }[])
          .map((r) => Number(r.tax_rate_snapshot))
          .filter((n) => Number.isFinite(n)),
      ),
    ).sort((a, b) => a - b)
  } catch (err) {
    console.error('[AnalyticsFilterBar] failed to load VAT rates:', err)
    // allow a retry on next open
    vatLoaded.value = false
  }
}

// --- date-range pill ------------------------------------------------------
const datePopoverOpen = ref(false)

function applyPreset(preset: Preset) {
  const now = new Date()
  if (preset === 'today') {
    const start = new Date()
    start.setHours(0, 0, 0, 0)
    filter.value.from = start.toISOString()
    filter.value.to = new Date().toISOString()
  } else if (preset === '7d') {
    filter.value.from = new Date(Date.now() - 7 * 86400_000).toISOString()
    filter.value.to = new Date().toISOString()
  } else if (preset === '30d') {
    filter.value.from = new Date(Date.now() - 30 * 86400_000).toISOString()
    filter.value.to = new Date().toISOString()
  } else if (preset === '90d') {
    filter.value.from = new Date(Date.now() - 90 * 86400_000).toISOString()
    filter.value.to = new Date().toISOString()
  } else if (preset === 'ytd') {
    filter.value.from = new Date(now.getFullYear(), 0, 1).toISOString()
    filter.value.to = new Date().toISOString()
  } else if (preset === '12m') {
    const d = new Date()
    d.setFullYear(d.getFullYear() - 1)
    filter.value.from = d.toISOString()
    filter.value.to = new Date().toISOString()
  }
  // 'custom' is a no-op; user picks dates manually below
  if (preset !== 'custom') datePopoverOpen.value = false
}

// ISO -> yyyy-MM-dd for <input type="date"> v-model
const customFrom = computed<string>({
  get: () => isoToDateInput(filter.value.from),
  set: (v) => {
    if (v) filter.value.from = new Date(v + 'T00:00:00').toISOString()
  },
})
const customTo = computed<string>({
  get: () => isoToDateInput(filter.value.to),
  set: (v) => {
    if (v) filter.value.to = new Date(v + 'T23:59:59.999').toISOString()
  },
})

function isoToDateInput(iso: string): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  // local YYYY-MM-DD
  const yyyy = d.getFullYear()
  const mm = String(d.getMonth() + 1).padStart(2, '0')
  const dd = String(d.getDate()).padStart(2, '0')
  return `${yyyy}-${mm}-${dd}`
}

// Short label for the date pill (TODO i18n: locale-aware formatting)
const dateLabel = computed(() => {
  const f = filter.value.from ? new Date(filter.value.from) : null
  const t = filter.value.to ? new Date(filter.value.to) : null
  if (!f || !t) return 'Date range'
  const fmt = (d: Date) =>
    `${String(d.getDate()).padStart(2, '0')}.${String(d.getMonth() + 1).padStart(2, '0')}.${d.getFullYear()}`
  return `${fmt(f)} – ${fmt(t)}`
})

// --- channel pill toggles -------------------------------------------------
function isChannelActive(value: string): boolean {
  if (filter.value.channels.length === 0) return false
  if (filter.value.channels.includes(value)) return true
  // legacy 'mqtt' rows belong in the cashless bucket
  if (value === 'cashless' && filter.value.channels.includes('mqtt')) return true
  return false
}
function toggleChannel(value: string) {
  // 'cashless' must be symmetric with the read alias — legacy rows on the
  // wire use 'mqtt' for the same logical channel. If we only stored
  // 'cashless', `s.channel = ANY (p_channels)` would silently exclude every
  // legacy row. So toggle both aliases together.
  const set = new Set(filter.value.channels)
  const aliases = value === 'cashless' ? ['cashless', 'mqtt'] : [value]
  const isActive = aliases.some((a) => set.has(a))
  if (isActive) for (const a of aliases) set.delete(a)
  else for (const a of aliases) set.add(a)
  filter.value.channels = Array.from(set)
}

// --- option-list adapters for MultiSelectPill ----------------------------
const machineOptions = computed(() =>
  machines.value.map((m) => ({ value: m.id, label: m.name })),
)
const categoryOptions = computed(() =>
  categories.value.map((c) => ({ value: c.id, label: c.name })),
)
const vatOptions = computed(() =>
  vatRates.value.map((r) => ({ value: r, label: formatVat(r) })),
)

function formatVat(rate: number): string {
  // numeric(6,4) is stored as 0.19 etc.  Render as 19% / 7% / 0%.
  // Round first to dodge IEEE-754 surprises (0.07 * 100 = 7.000000000000001).
  const pct = Math.round(rate * 10000) / 100
  return `${pct % 1 === 0 ? pct.toFixed(0) : pct.toFixed(1)}%`
}

function onVatRatesChange(next: number[]) {
  filter.value.vatRates = [...next].sort((a, b) => a - b)
}

// --- presets dropdown -----------------------------------------------------
const presetsList = ref<string[]>([])
function refreshPresets() {
  presetsList.value = listPresets()
}
onMounted(refreshPresets)

const presetNameInput = ref('')
const savePopoverOpen = ref(false)
function onSavePreset() {
  const name = presetNameInput.value.trim()
  if (!name) return
  savePreset(name)
  presetNameInput.value = ''
  savePopoverOpen.value = false
  refreshPresets()
}
function onLoadPreset(name: string) {
  loadPreset(name)
}
function onDeletePreset(name: string, e: Event) {
  e.stopPropagation()
  e.preventDefault()
  deletePreset(name)
  refreshPresets()
}
</script>

<template>
  <div
    class="flex flex-wrap items-center gap-2 rounded-md border bg-card p-2 shadow-sm"
    data-testid="analytics-filter-bar"
  >
    <!-- Date-range pill ----------------------------------------------- -->
    <Popover v-model:open="datePopoverOpen">
      <PopoverTrigger as-child>
        <Button
          type="button"
          variant="outline"
          size="sm"
          class="gap-2"
          data-testid="filter-date"
        >
          <CalendarIcon class="size-4" />
          <span>{{ dateLabel }}</span>
        </Button>
      </PopoverTrigger>
      <PopoverContent class="w-72 p-3" align="start">
        <div class="flex flex-col gap-2">
          <!-- TODO i18n -->
          <div class="text-xs font-medium text-muted-foreground">Quick presets</div>
          <div class="grid grid-cols-3 gap-1">
            <Button variant="ghost" size="sm" @click="applyPreset('today')">Today</Button>
            <Button variant="ghost" size="sm" @click="applyPreset('7d')">7d</Button>
            <Button variant="ghost" size="sm" @click="applyPreset('30d')">30d</Button>
            <Button variant="ghost" size="sm" @click="applyPreset('90d')">90d</Button>
            <Button variant="ghost" size="sm" @click="applyPreset('ytd')">YTD</Button>
            <Button variant="ghost" size="sm" @click="applyPreset('12m')">12M</Button>
          </div>
          <div class="my-1 h-px bg-border" />
          <!-- TODO i18n -->
          <div class="text-xs font-medium text-muted-foreground">Custom range</div>
          <label class="space-y-1 text-xs">
            <span class="text-muted-foreground">From</span>
            <input
              v-model="customFrom"
              type="date"
              class="flex h-8 w-full rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </label>
          <label class="space-y-1 text-xs">
            <span class="text-muted-foreground">To</span>
            <input
              v-model="customTo"
              type="date"
              class="flex h-8 w-full rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </label>
        </div>
      </PopoverContent>
    </Popover>

    <!-- Compare-period toggle ------------------------------------------ -->
    <label
      class="inline-flex h-8 items-center gap-2 rounded-md border bg-background px-2 text-xs"
      data-testid="filter-compare"
    >
      <Switch v-model="filter.compare" />
      <!-- TODO i18n -->
      <span class="text-muted-foreground">Compare period</span>
    </label>

    <!-- Machines multi-select ------------------------------------------ -->
    <!-- TODO i18n: placeholder + searchPlaceholder strings -->
    <MultiSelectPill
      v-model="filter.machines"
      :options="machineOptions"
      placeholder="Machines"
      search-placeholder="Search machines..."
      :max-visible-badges="2"
      testid="filter-machines"
    />

    <!-- Channel pill toggles ------------------------------------------- -->
    <div class="flex items-center gap-1" data-testid="filter-channels">
      <button
        v-for="ch in CHANNEL_OPTIONS"
        :key="ch.value"
        type="button"
        @click="toggleChannel(ch.value)"
      >
        <Badge :variant="isChannelActive(ch.value) ? 'default' : 'outline'" class="cursor-pointer">
          {{ ch.label }}
        </Badge>
      </button>
    </div>

    <!-- Categories multi-select ---------------------------------------- -->
    <!-- TODO i18n: placeholder + searchPlaceholder strings -->
    <MultiSelectPill
      v-model="filter.categories"
      :options="categoryOptions"
      placeholder="Categories"
      search-placeholder="Search categories..."
      :max-visible-badges="2"
      testid="filter-categories"
    />

    <!-- VAT rates multi-select ----------------------------------------- -->
    <!-- No search input (small option set), all badges visible.
         vatRates load lazily on first popover open via @open. -->
    <!-- TODO i18n: placeholder + emptyLabel strings -->
    <MultiSelectPill
      :model-value="filter.vatRates"
      :options="vatOptions"
      placeholder="VAT rates"
      empty-label="No VAT rates yet"
      testid="filter-vat"
      @open="loadVatRates"
      @update:model-value="onVatRatesChange"
    />

    <!-- Spacer pushes reset/preset to the right ------------------------ -->
    <div class="ml-auto flex items-center gap-1">
      <!-- Reset -->
      <Button
        type="button"
        variant="ghost"
        size="sm"
        class="gap-1"
        data-testid="filter-reset"
        @click="reset"
      >
        <RotateCcw class="size-4" />
        <!-- TODO i18n -->
        <span>Reset</span>
      </Button>

      <!-- Save-as-preset menu -->
      <DropdownMenu>
        <DropdownMenuTrigger as-child>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            class="gap-1"
            data-testid="filter-presets"
          >
            <Save class="size-4" />
            <!-- TODO i18n -->
            <span>Presets</span>
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" class="w-56">
          <div class="px-2 py-1.5 text-xs font-medium text-muted-foreground">
            <!-- TODO i18n -->
            Save current filter
          </div>
          <div class="flex items-center gap-1 px-2 pb-2">
            <input
              v-model="presetNameInput"
              type="text"
              placeholder="Preset name"
              class="flex h-8 w-full rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              @keydown.enter.prevent="onSavePreset"
            />
            <Button size="icon-sm" variant="outline" @click="onSavePreset">
              <Save class="size-3.5" />
            </Button>
          </div>
          <DropdownMenuSeparator v-if="presetsList.length > 0" />
          <div v-if="presetsList.length === 0" class="px-2 py-2 text-xs text-muted-foreground">
            <!-- TODO i18n -->
            No saved presets
          </div>
          <DropdownMenuItem
            v-for="name in presetsList"
            :key="name"
            class="flex items-center justify-between gap-2"
            @select="onLoadPreset(name)"
          >
            <span class="truncate">{{ name }}</span>
            <button
              type="button"
              class="rounded-sm p-1 opacity-60 hover:opacity-100"
              @click="(e) => onDeletePreset(name, e)"
            >
              <Trash2 class="size-3.5" />
            </button>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  </div>
</template>
