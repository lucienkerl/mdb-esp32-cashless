<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { buildStatusHistory, type SegmentState, type StatusLogRow } from '@/lib/connectivity'
import { useConnectivity } from '@/composables/useConnectivity'
import DeviceStatusChip from '@/components/DeviceStatusChip.vue'

/**
 * "Connection" card on the device tab: device, network and machine (MDB)
 * side by side, plus the online history of the last 24 hours from
 * `embedded_status_log`.
 */
const props = defineProps<{
  embedded: {
    id: string
    status: string | null
    status_at: string | null
    online_since?: string | null
    firmware_version?: string | null
    mdb_diagnostics?: Record<string, any> | null
  }
}>()

const { t } = useI18n()
const supabase = useSupabaseClient()
const { now, of, ago, clock, duration, stateLabel, readerLabel, textClass } = useConnectivity()

const c = computed(() => of(props.embedded))
const cellular = computed(() => {
  const cell = props.embedded.mdb_diagnostics?.cellular
  return cell && cell.uplink === 'cellular' ? cell : null
})

const stateColor = computed(() => {
  switch (c.value.state) {
    case 'online': return 'text-green-700 dark:text-green-400'
    case 'updating': return 'text-purple-700 dark:text-purple-300'
    default: return textClass(c.value.state)
  }
})

// ── History ────────────────────────────────────────────────────────────────
const WINDOW_MS = 24 * 3600 * 1000
const rows = ref<StatusLogRow[]>([])
const loaded = ref(false)

async function loadHistory() {
  const since = new Date(Date.now() - WINDOW_MS).toISOString()
  const { data } = await supabase
    .from('embedded_status_log')
    .select('status, prev_status, created_at')
    .eq('embedded_id', props.embedded.id)
    .gte('created_at', since)
    .order('created_at', { ascending: true })
  rows.value = (data ?? []) as StatusLogRow[]
  loaded.value = true
}

onMounted(loadHistory)
// A status change (realtime update of the parent) adds a row to the log.
watch(() => [props.embedded.id, props.embedded.status], loadHistory)

const history = computed(() => {
  const end = now.value.getTime()
  return buildStatusHistory(rows.value, props.embedded.status, end - WINDOW_MS, end)
})

const segmentClass: Record<SegmentState, string> = {
  online: 'bg-green-500',
  offline: 'bg-red-500',
  updating: 'bg-purple-500',
  unknown: 'bg-muted',
}

const percentLabel = computed(() => {
  const pct = history.value.onlinePercent
  if (pct == null) return t('connectivity.history.noData')
  // Never round a real outage up to "100 %".
  const shown = pct < 100 ? Math.min(Math.floor(pct), 99) : 100
  return t('connectivity.history.percent', { pct: shown })
})

const outageLabels = computed(() =>
  history.value.outages.slice(-3).map(o => t('connectivity.history.outageRange', {
    from: clock(new Date(o.start)),
    to: o.end >= now.value.getTime() - 1000 ? t('connectivity.history.now') : clock(new Date(o.end)),
    duration: duration(o.end - o.start),
  })),
)

const previouslyOnline = computed(() => {
  const cc = c.value
  if (cc.state !== 'offline' || !cc.onlineSince || !cc.since) return null
  const ms = cc.since.getTime() - cc.onlineSince.getTime()
  return ms > 0 ? duration(ms) : null
})
</script>

<template>
  <div class="rounded-xl border bg-card p-4 sm:p-6">
    <div class="mb-4 flex items-center justify-between gap-2">
      <h2 class="text-sm font-medium">{{ t('connectivity.card.title') }}</h2>
      <span class="text-xs text-muted-foreground">{{ t('connectivity.card.live') }}</span>
    </div>

    <div class="grid grid-cols-1 gap-6 md:grid-cols-3">
      <!-- Device -->
      <div>
        <p class="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">{{ t('connectivity.card.device') }}</p>
        <p class="mt-1 mb-2 text-xl font-semibold" :class="stateColor">{{ stateLabel(c) }}</p>
        <dl class="divide-y text-sm">
          <div v-if="c.state === 'online' && c.onlineSince" class="flex justify-between gap-3 py-1.5">
            <dt class="text-muted-foreground">{{ t('connectivity.card.onlineSince') }}</dt>
            <dd class="text-right font-medium">{{ duration(now.getTime() - c.onlineSince.getTime()) }} <span class="text-muted-foreground font-normal">({{ clock(c.onlineSince) }})</span></dd>
          </div>
          <div v-if="c.state === 'offline' && c.since" class="flex justify-between gap-3 py-1.5">
            <dt class="text-muted-foreground">{{ t('connectivity.card.offlineSince') }}</dt>
            <dd class="text-right font-medium">{{ clock(c.since) }} <span class="text-muted-foreground font-normal">({{ ago(c.since) }})</span></dd>
          </div>
          <div v-if="previouslyOnline" class="flex justify-between gap-3 py-1.5">
            <dt class="text-muted-foreground">{{ t('connectivity.card.previouslyOnline') }}</dt>
            <dd class="text-right font-medium">{{ previouslyOnline }}</dd>
          </div>
          <div v-if="c.state !== 'offline'" class="flex justify-between gap-3 py-1.5">
            <dt class="text-muted-foreground">{{ t('connectivity.card.lastContact') }}</dt>
            <dd class="text-right font-medium">{{ c.lastContactAt ? `${ago(c.lastContactAt)} (${clock(c.lastContactAt)})` : '—' }}</dd>
          </div>
          <div class="flex justify-between gap-3 py-1.5">
            <dt class="text-muted-foreground">{{ t('connectivity.card.firmware') }}</dt>
            <dd class="text-right font-medium">{{ embedded.firmware_version ? `v${embedded.firmware_version}` : '—' }}</dd>
          </div>
        </dl>
      </div>

      <!-- Network -->
      <div>
        <p class="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">{{ t('connectivity.card.network') }}</p>
        <template v-if="cellular">
          <p class="mt-1 mb-2 text-xl font-semibold">{{ t('connectivity.card.uplinkCellular') }}</p>
          <dl class="divide-y text-sm">
            <div class="flex justify-between gap-3 py-1.5">
              <dt class="text-muted-foreground">{{ t('connectivity.card.operator') }}</dt>
              <dd class="text-right font-medium">{{ cellular.op || '—' }}</dd>
            </div>
            <div class="flex justify-between gap-3 py-1.5">
              <dt class="text-muted-foreground">{{ t('connectivity.card.signal') }}</dt>
              <dd class="text-right font-medium">{{ typeof cellular.rssi === 'number' ? `${cellular.rssi} dBm` : '—' }}</dd>
            </div>
            <div class="flex justify-between gap-3 py-1.5">
              <dt class="text-muted-foreground">{{ t('connectivity.card.mode') }}</dt>
              <dd class="text-right font-medium">{{ cellular.mode || '—' }}</dd>
            </div>
          </dl>
        </template>
        <p v-else class="mt-1 text-xl font-semibold text-muted-foreground">{{ t('connectivity.card.uplinkUnknown') }}</p>
      </div>

      <!-- Machine (MDB) -->
      <div>
        <p class="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">{{ t('connectivity.card.machine') }}</p>
        <template v-if="c.reader">
          <p
            class="mt-1 mb-2 text-xl font-semibold"
            :class="c.reader === 'ready' ? 'text-green-700 dark:text-green-400' : c.reader === 'inactive' ? 'text-amber-700 dark:text-amber-400' : 'text-blue-700 dark:text-blue-400'"
          >{{ readerLabel(c) }}</p>
          <p class="text-sm text-muted-foreground">{{ t(`connectivity.reader.${c.reader}Hint`) }}</p>
        </template>
        <template v-else>
          <p class="mt-1 mb-2 text-xl font-semibold text-muted-foreground">{{ t('connectivity.reader.unknown') }}</p>
          <p class="text-sm text-muted-foreground">{{ t('connectivity.reader.unknownHint') }}</p>
        </template>
      </div>
    </div>

    <!-- 24 h history -->
    <div class="mt-6">
      <div class="mb-1.5 flex flex-wrap items-center justify-between gap-2 text-xs text-muted-foreground">
        <span>{{ t('connectivity.history.title') }} · {{ loaded ? percentLabel : '…' }}</span>
        <DeviceStatusChip :connectivity="c" size="sm" />
      </div>
      <div class="flex h-3.5 gap-px overflow-hidden rounded" role="img" :aria-label="`${t('connectivity.history.title')}: ${percentLabel}`">
        <div
          v-for="(seg, i) in history.segments"
          :key="i"
          :class="segmentClass[seg.state]"
          :style="{ flexGrow: seg.end - seg.start, flexBasis: 0, minWidth: '2px' }"
          :title="`${t(`connectivity.history.${seg.state}`)} ${clock(new Date(seg.start))}–${clock(new Date(seg.end))}`"
        />
      </div>
      <div class="mt-1 flex justify-between text-[11px] text-muted-foreground">
        <span>{{ t('connectivity.history.ago') }}</span>
        <span>{{ t('connectivity.history.now') }}</span>
      </div>
      <div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
        <span class="inline-flex items-center gap-1.5"><span class="size-2 rounded-full bg-green-500" />{{ t('connectivity.history.online') }}</span>
        <span class="inline-flex items-center gap-1.5"><span class="size-2 rounded-full bg-red-500" />{{ t('connectivity.history.offline') }}</span>
        <span class="inline-flex items-center gap-1.5"><span class="size-2 rounded-full bg-purple-500" />{{ t('connectivity.history.updating') }}</span>
        <span v-if="history.outages.length === 0" class="ml-auto">{{ t('connectivity.history.noOutages') }}</span>
      </div>
      <ul v-if="outageLabels.length" class="mt-2 space-y-0.5 text-xs text-red-600 dark:text-red-400">
        <li v-for="label in outageLabels" :key="label">{{ label }}</li>
      </ul>
    </div>
  </div>
</template>
