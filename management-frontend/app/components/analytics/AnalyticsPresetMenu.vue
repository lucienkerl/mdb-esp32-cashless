<!--
  AnalyticsPresetMenu
  -------------------
  Standalone "Presets" dropdown that wraps useAnalyticsFilters'
  savePreset / loadPreset / listPresets / deletePreset. Refreshes the
  visible list on every menu open so saves from another tab show up.

  TODO: replace AnalyticsFilterBar's inline preset dropdown with this
  component — Task 3.4 shipped the same UI inline for speed; once this
  component is wired into the page header the duplication goes away.
-->
<script setup lang="ts">
import { Save, Trash2 } from 'lucide-vue-next'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'

const { t } = useI18n()
const { savePreset, loadPreset, listPresets, deletePreset } =
  useAnalyticsFilters()

const newPresetName = ref('')
const presetsList = ref<string[]>([])
const open = ref(false)

function refreshPresets() {
  presetsList.value = listPresets()
}

// Refresh on mount so the first open shows current state without a flicker.
onMounted(refreshPresets)

// Whenever the menu opens we reload from localStorage — covers the case
// where another tab saved a preset since this component mounted.
watch(open, (isOpen) => {
  if (isOpen) refreshPresets()
})

function onSave() {
  const name = newPresetName.value.trim()
  if (!name) return
  savePreset(name)
  newPresetName.value = ''
  refreshPresets()
}

function onLoad(name: string) {
  loadPreset(name)
}

function onDelete(name: string, e: Event) {
  // Stop the DropdownMenuItem from firing its own select handler when the
  // user clicks the trash icon.
  e.stopPropagation()
  e.preventDefault()
  deletePreset(name)
  refreshPresets()
}
</script>

<template>
  <DropdownMenu v-model:open="open">
    <DropdownMenuTrigger as-child>
      <Button
        type="button"
        variant="ghost"
        size="sm"
        class="gap-1"
        data-testid="analytics-preset-menu-trigger"
      >
        <Save class="size-4" />
        <span>{{ t('analytics.presets') }}</span>
      </Button>
    </DropdownMenuTrigger>
    <DropdownMenuContent
      align="end"
      class="w-56"
      data-testid="analytics-preset-menu-content"
    >
      <div class="px-2 py-1.5 text-xs font-medium text-muted-foreground">
        {{ t('analytics.saveCurrentAs') }}
      </div>
      <div class="flex items-center gap-1 px-2 pb-2">
        <input
          v-model="newPresetName"
          type="text"
          :placeholder="t('analytics.presetName')"
          class="flex h-8 w-full rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          @keydown.enter.prevent="onSave"
        />
        <Button size="icon-sm" variant="outline" @click="onSave">
          <Save class="size-3.5" />
        </Button>
      </div>
      <DropdownMenuSeparator v-if="presetsList.length > 0" />
      <div
        v-if="presetsList.length === 0"
        class="px-2 py-2 text-xs text-muted-foreground"
      >
        {{ t('analytics.noPresets') }}
      </div>
      <DropdownMenuItem
        v-for="name in presetsList"
        :key="name"
        class="flex items-center justify-between gap-2"
        @select="onLoad(name)"
      >
        <span class="truncate">{{ name }}</span>
        <button
          type="button"
          class="rounded-sm p-1 opacity-60 hover:opacity-100"
          @click="(e) => onDelete(name, e)"
        >
          <Trash2 class="size-3.5" />
        </button>
      </DropdownMenuItem>
    </DropdownMenuContent>
  </DropdownMenu>
</template>
