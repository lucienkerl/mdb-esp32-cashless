<!--
  Analytics Dashboard
  -------------------
  Main /analytics page. Tabs are hash-routed (`#overview`, `#sales`, ...) and
  the active tab component is loaded async so each tab's data hooks only run
  when the user actually opens that tab.

  TODO i18n: page heading is hardcoded English so Task 3.6 isn't blocked on
  missing translation keys. Chunk 7 (polish) will replace it with $t(...).
-->
<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { computed, defineAsyncComponent } from 'vue'
import { useRoute } from 'vue-router'

const TabOverview   = defineAsyncComponent(() => import('@/components/analytics/tabs/TabOverview.vue'))
const TabSales      = defineAsyncComponent(() => import('@/components/analytics/tabs/TabSales.vue'))
const TabProducts   = defineAsyncComponent(() => import('@/components/analytics/tabs/TabProducts.vue'))
const TabMachines   = defineAsyncComponent(() => import('@/components/analytics/tabs/TabMachines.vue'))
const TabConversion = defineAsyncComponent(() => import('@/components/analytics/tabs/TabConversion.vue'))
const TabOperations = defineAsyncComponent(() => import('@/components/analytics/tabs/TabOperations.vue'))

const route = useRoute()
const active = computed(() => (route.hash || '#overview').slice(1))

const Component = computed(() => {
  switch (active.value) {
    case 'sales':      return TabSales
    case 'products':   return TabProducts
    case 'machines':   return TabMachines
    case 'conversion': return TabConversion
    case 'operations': return TabOperations
    default:           return TabOverview
  }
})
</script>

<template>
  <div class="flex flex-1 flex-col gap-4 p-4 md:p-6">
    <!-- TODO i18n -->
    <h1 class="text-2xl font-semibold">Analytics</h1>
    <AnalyticsFilterBar />
    <AnalyticsTabNav />
    <component :is="Component" />
  </div>
</template>
