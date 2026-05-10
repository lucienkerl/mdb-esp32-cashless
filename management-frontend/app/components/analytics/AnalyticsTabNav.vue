<!--
  AnalyticsTabNav
  ---------------
  Horizontal tab bar for the Analytics dashboard. Active tab is driven by the
  URL hash (e.g. `#sales`) so deep-links and browser back/forward buttons just
  work — `router.replace` keeps history clean.
-->
<script setup lang="ts">
import { useRoute, useRouter } from 'vue-router'

const { t } = useI18n()
const route = useRoute()
const router = useRouter()

const TAB_IDS = ['overview', 'sales', 'products', 'machines', 'conversion', 'operations'] as const

const active = computed(() => (route.hash || '#overview').slice(1))

function setTab(id: string) {
  router.replace({ ...route, hash: '#' + id })
}
</script>

<template>
  <nav class="flex gap-1 border-b" data-testid="analytics-tab-nav">
    <button
      v-for="id in TAB_IDS"
      :key="id"
      type="button"
      class="px-3 py-2 text-sm font-medium transition-colors"
      :class="active === id
        ? 'border-b-2 border-primary text-primary'
        : 'text-muted-foreground hover:text-foreground'"
      @click="setTab(id)"
    >
      {{ t('analytics.tab.' + id) }}
    </button>
  </nav>
</template>
