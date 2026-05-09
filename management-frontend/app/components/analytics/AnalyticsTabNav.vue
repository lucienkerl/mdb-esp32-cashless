<!--
  AnalyticsTabNav
  ---------------
  Horizontal tab bar for the Analytics dashboard. Active tab is driven by the
  URL hash (e.g. `#sales`) so deep-links and browser back/forward buttons just
  work — `router.replace` keeps history clean.

  TODO i18n: tab labels are hardcoded English. Chunk 7 (polish) will move them
  into the translation files.
-->
<script setup lang="ts">
import { useRoute, useRouter } from 'vue-router'

const route = useRoute()
const router = useRouter()

// TODO i18n
const TABS = [
  { id: 'overview',   label: 'Overview' },
  { id: 'sales',      label: 'Sales' },
  { id: 'products',   label: 'Products' },
  { id: 'machines',   label: 'Machines' },
  { id: 'conversion', label: 'Conversion' },
  { id: 'operations', label: 'Operations' },
] as const

const active = computed(() => (route.hash || '#overview').slice(1))

function setTab(id: string) {
  router.replace({ ...route, hash: '#' + id })
}
</script>

<template>
  <nav class="flex gap-1 border-b" data-testid="analytics-tab-nav">
    <button
      v-for="t in TABS"
      :key="t.id"
      type="button"
      class="px-3 py-2 text-sm font-medium transition-colors"
      :class="active === t.id
        ? 'border-b-2 border-primary text-primary'
        : 'text-muted-foreground hover:text-foreground'"
      @click="setTab(t.id)"
    >
      {{ t.label }}
    </button>
  </nav>
</template>
