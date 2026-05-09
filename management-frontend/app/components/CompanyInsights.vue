<script setup lang="ts">
import { IconSparkles, IconRefresh, IconLoader2 } from '@tabler/icons-vue'
import { useInsights, sortedRecommendations, priorityVariant, recommendationTypeLabel } from '@/composables/useInsights'
import { timeAgo } from '@/lib/utils'

const { t } = useI18n()

const { companyData: companyInsights, companyLoading, companyError, fetchCompanyInsights, history: companyHistory, historyLoading: companyHistoryLoading, fetchHistory: fetchCompanyHistory } = useInsights()
const companyInsightsExpanded = ref(false)

// On mount: load latest from history (DB read, no Anthropic call) + full history list
onMounted(async () => {
  await fetchCompanyHistory()
  // Show the most recent history entry as the current result
  if (companyHistory.value.length > 0) {
    const latest = companyHistory.value[0]
    companyInsights.value = {
      generated_at: latest.generated_at,
      period_days: latest.period_days,
      type: 'company',
      recommendations: latest.recommendations ?? [],
      summary: latest.summary ?? '',
      trends: latest.trends ?? null,
      cached: true,
    }
  }
})

function generateCompanyInsights() {
  fetchCompanyInsights()
}

function refreshCompanyInsights() {
  fetchCompanyInsights(30, true)
}

const companyHistoryExpanded = ref<string | null>(null)
function toggleCompanyHistoryEntry(id: string) {
  companyHistoryExpanded.value = companyHistoryExpanded.value === id ? null : id
}
</script>

<template>
  <div class="rounded-xl border bg-card">
    <!-- Header (always visible, clickable to expand/collapse) -->
    <button
      class="flex w-full items-center justify-between px-4 py-3 text-left"
      @click="companyInsightsExpanded = !companyInsightsExpanded"
    >
      <div class="flex items-center gap-2">
        <IconSparkles class="size-4 text-primary" />
        <h3 class="text-sm font-medium">{{ t('dashboard.companyInsights') }}</h3>
        <span v-if="companyInsights?.cached" class="inline-flex items-center rounded-full bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
          {{ t('machineDetail.aiCached') }}
        </span>
      </div>
      <div class="flex items-center gap-2">
        <button
          v-if="companyInsights && !companyLoading"
          class="inline-flex h-7 items-center gap-1.5 rounded-md border px-2 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          @click.stop="refreshCompanyInsights"
        >
          <IconRefresh class="size-3" />
          {{ t('machineDetail.aiRefresh') }}
        </button>
        <svg
          xmlns="http://www.w3.org/2000/svg" class="size-4 text-muted-foreground transition-transform"
          :class="{ 'rotate-180': companyInsightsExpanded }"
          viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
        ><polyline points="6 9 12 15 18 9"/></svg>
      </div>
    </button>

    <template v-if="companyInsightsExpanded">
      <!-- Loading -->
      <div v-if="companyLoading" class="flex items-center gap-2 border-t px-4 py-4 text-sm text-muted-foreground">
        <IconLoader2 class="size-4 animate-spin" />
        {{ t('dashboard.companyInsightsLoading') }}
      </div>

      <!-- Error -->
      <div v-else-if="companyError" class="border-t px-4 py-3">
        <p class="text-sm text-destructive">{{ companyError }}</p>
      </div>

      <!-- No insights yet — show generate button -->
      <div v-else-if="!companyInsights && !companyLoading" class="border-t px-4 py-4 text-center">
        <p class="mb-3 text-sm text-muted-foreground">{{ t('dashboard.companyInsightsEmpty') }}</p>
        <button
          class="inline-flex h-8 items-center gap-1.5 rounded-md bg-primary px-4 text-xs font-medium text-primary-foreground shadow-sm transition-colors hover:bg-primary/90"
          @click="generateCompanyInsights"
        >
          <IconSparkles class="size-3" />
          {{ t('dashboard.companyInsightsGenerate') }}
        </button>
      </div>

      <!-- Results -->
      <div v-else-if="companyInsights" class="border-t">
        <!-- Trends -->
        <div v-if="companyInsights.trends && (companyInsights.trends.revenue_change_pct !== null || companyInsights.trends.units_change_pct !== null)" class="flex flex-wrap gap-2 px-4 py-3">
          <span
            v-if="companyInsights.trends.revenue_change_pct !== null"
            class="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium"
            :class="companyInsights.trends.revenue_change_pct >= 0 ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300' : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'"
          >
            {{ companyInsights.trends.revenue_change_pct >= 0 ? '+' : '' }}{{ companyInsights.trends.revenue_change_pct }}%
            {{ t('machineDetail.aiTrendRevenue', { days: companyInsights.period_days }) }}
          </span>
          <span
            v-if="companyInsights.trends.units_change_pct !== null"
            class="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium"
            :class="companyInsights.trends.units_change_pct >= 0 ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300' : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'"
          >
            {{ companyInsights.trends.units_change_pct >= 0 ? '+' : '' }}{{ companyInsights.trends.units_change_pct }}%
            {{ t('machineDetail.aiTrendUnits', { days: companyInsights.period_days }) }}
          </span>
        </div>

        <!-- Recommendations -->
        <div v-if="sortedRecommendations(companyInsights.recommendations).length > 0" class="space-y-2 px-4 pb-3">
          <div
            v-for="(rec, idx) in sortedRecommendations(companyInsights.recommendations)"
            :key="idx"
            class="rounded-lg border p-3 space-y-1.5"
          >
            <div class="flex items-center gap-2 flex-wrap">
              <Badge :variant="priorityVariant(rec.priority)" class="text-[10px]">{{ rec.priority }}</Badge>
              <span class="text-[10px] text-muted-foreground">{{ t(recommendationTypeLabel(rec.type)) }}</span>
            </div>
            <p class="text-sm font-medium">{{ rec.title }}</p>
            <p class="text-xs text-muted-foreground">{{ rec.detail }}</p>
          </div>
        </div>

        <!-- Summary -->
        <div class="border-t px-4 py-3">
          <p class="text-sm text-muted-foreground leading-relaxed">{{ companyInsights.summary }}</p>
        </div>

        <!-- Footer -->
        <div class="flex items-center gap-2 border-t px-4 py-2">
          <p class="flex-1 text-xs text-muted-foreground">
            {{ t('machineDetail.aiGenerated', { time: timeAgo(companyInsights.generated_at, t) }) }}
          </p>
        </div>
      </div>

      <!-- History -->
      <div v-if="!companyLoading && !companyError" class="border-t px-4 py-3">
        <h4 class="mb-2 text-xs font-medium text-muted-foreground">{{ t('machineDetail.aiHistory') }}</h4>
        <div v-if="companyHistoryLoading" class="space-y-2">
          <div v-for="i in 2" :key="i" class="h-10 animate-pulse rounded bg-muted" />
        </div>
        <div v-else-if="companyHistory.length === 0" class="text-xs text-muted-foreground">
          {{ t('machineDetail.aiHistoryEmpty') }}
        </div>
        <div v-else class="space-y-1.5">
          <div
            v-for="entry in companyHistory"
            :key="entry.id"
            class="rounded-lg border"
          >
            <button
              class="flex w-full items-center justify-between px-3 py-2 text-left text-xs transition-colors hover:bg-muted/50"
              @click="toggleCompanyHistoryEntry(entry.id)"
            >
              <span class="text-muted-foreground">{{ new Date(entry.generated_at).toLocaleDateString() }}</span>
              <div class="flex items-center gap-2">
                <span class="text-[10px] text-muted-foreground">{{ (entry.recommendations ?? []).length }} {{ t('machineDetail.aiHistoryRecs') }}</span>
                <svg
                  xmlns="http://www.w3.org/2000/svg" class="size-3 text-muted-foreground transition-transform"
                  :class="{ 'rotate-180': companyHistoryExpanded === entry.id }"
                  viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
                ><polyline points="6 9 12 15 18 9"/></svg>
              </div>
            </button>
            <div v-if="companyHistoryExpanded === entry.id" class="border-t px-3 py-2 space-y-1.5">
              <p class="text-xs text-muted-foreground leading-relaxed">{{ entry.summary }}</p>
              <div
                v-for="(rec, idx) in sortedRecommendations(entry.recommendations ?? [])"
                :key="idx"
                class="flex items-start gap-1.5 text-[11px]"
              >
                <Badge :variant="priorityVariant(rec.priority)" class="mt-0.5 shrink-0 text-[9px]">{{ rec.priority }}</Badge>
                <span class="text-muted-foreground">{{ rec.title }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>
