<script setup lang="ts">
import {
  IconCopy,
  IconDownload,
  IconEraser,
  IconLoader2,
  IconPlayerPause,
  IconPlayerPlay,
  IconPlayerStop,
} from '@tabler/icons-vue'
import {
  annotate,
  filterAnnotated,
  formatClock,
  formatWords,
  parseMdbAddress,
  toLogText,
  type TraceEntry,
} from '@/lib/mdbTrace'
import { useMdbTrace } from '@/composables/useMdbTrace'

/**
 * Live console for the raw MDB bus traffic of one device: what the VMC sends,
 * what this device answers, decoded and checksum-verified. The device only
 * publishes while a trace is running (see useMdbTrace), so it costs nothing
 * the rest of the time.
 */
const props = defineProps<{
  embeddedId: string
  /** The device's MDB address from its diagnostics ("0x10"), used to tell its traffic from the rest of the bus. */
  mdbAddress?: string | null
}>()

const { t } = useI18n()
const trace = useMdbTrace()
const { entries, error, starting, running, remainingSec, receiving, silent } = trace

const DURATIONS = [60, 300, 900, 1800]
const durationSec = ref(300)

const hidePolls = ref(true)
const onlyOurs = ref(false)

// Pause freezes what is on screen; the feed keeps filling behind it.
const paused = ref(false)
const frozen = ref<TraceEntry[]>([])
function togglePause() {
  if (!paused.value) frozen.value = entries.value.slice()
  paused.value = !paused.value
}

const ourAddress = computed(() => parseMdbAddress(props.mdbAddress))

const annotated = computed(() => annotate(paused.value ? frozen.value : entries.value, ourAddress.value))
const filtered = computed(() => filterAnnotated(annotated.value, { hidePolls: hidePolls.value, onlyOurs: onlyOurs.value }))
// Keep the DOM small however long the trace runs.
const visible = computed(() => filtered.value.slice(-1500))

// ── Auto-scroll: follow the tail unless the user scrolled up to read ─────────
const scroller = ref<HTMLElement | null>(null)
const stickToBottom = ref(true)

function onScroll() {
  const el = scroller.value
  if (!el) return
  stickToBottom.value = el.scrollHeight - el.scrollTop - el.clientHeight < 40
}

watch(() => visible.value.length, async () => {
  if (!stickToBottom.value || paused.value) return
  await nextTick()
  if (scroller.value) scroller.value.scrollTop = scroller.value.scrollHeight
})

// ── Status ───────────────────────────────────────────────────────────────────
const statusKey = computed(() => {
  if (receiving.value) return 'live'
  if (running.value) return 'waiting'
  return 'idle'
})
const statusClass = computed(() => ({
  live: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400',
  waiting: 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400',
  idle: 'bg-gray-100 text-gray-800 dark:bg-gray-800 dark:text-gray-300',
}[statusKey.value]))

const remainingLabel = computed(() => {
  const s = remainingSec.value
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
})

// ── Actions ──────────────────────────────────────────────────────────────────
const copied = ref(false)

async function copyLog() {
  try {
    await navigator.clipboard.writeText(toLogText(filtered.value))
    copied.value = true
    setTimeout(() => { copied.value = false }, 2000)
  } catch { /* clipboard unavailable (insecure origin): the download still works */ }
}

function downloadLog() {
  const blob = new Blob([toLogText(filtered.value)], { type: 'text/plain' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `mdb-trace-${new Date().toISOString().replace(/[:.]/g, '-')}.log`
  a.click()
  URL.revokeObjectURL(url)
}

function clearLog() {
  trace.clear()
  frozen.value = []
}

// ── Lifecycle ────────────────────────────────────────────────────────────────
let unsubscribe: (() => void) | null = null

onMounted(() => {
  trace.fetchRecent(props.embeddedId)
  unsubscribe = trace.subscribe(props.embeddedId)
})

onBeforeUnmount(() => {
  unsubscribe?.()
  // The device would stop on its own at the end of the time; no reason to
  // keep it streaming over the uplink once nobody is watching.
  if (running.value) trace.stop(props.embeddedId)
})
</script>

<template>
  <div class="rounded-xl border bg-card p-4 sm:p-6">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <h2 class="text-sm font-medium text-muted-foreground uppercase tracking-wide">{{ t('mdbTrace.title') }}</h2>
          <span class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium" :class="statusClass">
            {{ t(`mdbTrace.${statusKey}`) }}<template v-if="running"> · {{ t('mdbTrace.remaining', { time: remainingLabel }) }}</template>
          </span>
        </div>
        <p class="mt-1 max-w-2xl text-xs text-muted-foreground">{{ t('mdbTrace.hint') }}</p>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <label v-if="!running" class="flex items-center gap-1.5 text-xs text-muted-foreground">
          {{ t('mdbTrace.duration') }}
          <select
            v-model.number="durationSec"
            class="h-8 rounded-md border border-input bg-background px-2 text-xs focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option v-for="d in DURATIONS" :key="d" :value="d">{{ t('mdbTrace.durationOption', { n: d / 60 }) }}</option>
          </select>
        </label>

        <button
          v-if="!running"
          class="inline-flex h-8 items-center gap-1.5 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
          :disabled="starting"
          @click="trace.start(embeddedId, durationSec)"
        >
          <IconLoader2 v-if="starting" class="size-4 animate-spin" />
          <IconPlayerPlay v-else class="size-4" />
          {{ starting ? t('mdbTrace.starting') : t('mdbTrace.start') }}
        </button>
        <button
          v-else
          class="inline-flex h-8 items-center gap-1.5 rounded-md border border-input px-3 text-xs font-medium hover:bg-accent"
          @click="trace.stop(embeddedId)"
        >
          <IconPlayerStop class="size-4" />
          {{ t('mdbTrace.stop') }}
        </button>
      </div>
    </div>

    <p v-if="error" class="mt-3 text-xs text-red-600 dark:text-red-400">{{ error }}</p>
    <p v-else-if="silent" class="mt-3 text-xs text-amber-600 dark:text-amber-500">{{ t('mdbTrace.silent') }}</p>

    <!-- Toolbar -->
    <div class="mt-4 flex flex-wrap items-center justify-between gap-2">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
        <label class="flex cursor-pointer items-center gap-1.5">
          <input v-model="hidePolls" type="checkbox" class="size-3.5 accent-primary">
          {{ t('mdbTrace.hidePolls') }}
        </label>
        <label v-if="ourAddress !== null" class="flex cursor-pointer items-center gap-1.5">
          <input v-model="onlyOurs" type="checkbox" class="size-3.5 accent-primary">
          {{ t('mdbTrace.onlyOurs') }}
        </label>
        <span class="text-muted-foreground tabular-nums">{{ t('mdbTrace.lines', { n: filtered.length }) }}</span>
      </div>

      <div class="flex items-center gap-1.5">
        <button
          class="inline-flex h-8 items-center gap-1.5 rounded-md border border-input px-2.5 text-xs hover:bg-accent"
          @click="togglePause"
        >
          <IconPlayerPlay v-if="paused" class="size-4" />
          <IconPlayerPause v-else class="size-4" />
          {{ paused ? t('mdbTrace.resume') : t('mdbTrace.pause') }}
        </button>
        <button
          class="inline-flex h-8 items-center gap-1.5 rounded-md border border-input px-2.5 text-xs hover:bg-accent disabled:opacity-50"
          :disabled="filtered.length === 0"
          @click="copyLog"
        >
          <IconCopy class="size-4" />
          {{ copied ? t('mdbTrace.copied') : t('mdbTrace.copy') }}
        </button>
        <button
          class="inline-flex h-8 items-center gap-1.5 rounded-md border border-input px-2.5 text-xs hover:bg-accent disabled:opacity-50"
          :disabled="filtered.length === 0"
          @click="downloadLog"
        >
          <IconDownload class="size-4" />
          <span class="hidden sm:inline">{{ t('mdbTrace.download') }}</span>
        </button>
        <button
          class="inline-flex h-8 items-center gap-1.5 rounded-md border border-input px-2.5 text-xs hover:bg-accent disabled:opacity-50"
          :disabled="entries.length === 0"
          @click="clearLog"
        >
          <IconEraser class="size-4" />
          <span class="hidden sm:inline">{{ t('mdbTrace.clear') }}</span>
        </button>
      </div>
    </div>

    <!-- Console: dark in both themes, like a terminal -->
    <div
      ref="scroller"
      class="mt-3 h-96 overflow-auto rounded-lg border bg-zinc-950 p-2 font-mono text-xs leading-5 text-zinc-200"
      @scroll="onScroll"
    >
      <p v-if="visible.length === 0" class="p-4 text-center font-sans text-zinc-500">
        {{ entries.length === 0 ? t('mdbTrace.empty') : t('mdbTrace.emptyFiltered') }}
      </p>

      <template v-for="a in visible" :key="a.entry.id">
        <div v-if="a.entry.kind === 'gap'" class="whitespace-nowrap py-0.5 text-amber-400">
          <span class="tabular-nums text-zinc-500">{{ formatClock(a.entry.time) }}</span>
          &nbsp; !! {{ t('mdbTrace.lost', { n: a.entry.dropped }) }}
        </div>

        <div v-else class="flex items-baseline gap-2 whitespace-nowrap py-px">
          <span class="shrink-0 tabular-nums text-zinc-500">{{ formatClock(a.entry.time) }}</span>
          <span
            class="w-5 shrink-0 font-semibold"
            :class="a.entry.dir === 'tx' ? 'text-emerald-400' : 'text-sky-400'"
            :title="a.entry.dir === 'tx' ? t('mdbTrace.device') : t('mdbTrace.bus')"
          >{{ a.entry.dir === 'tx' ? 'TX' : 'RX' }}</span>

          <span
            class="w-4 shrink-0 text-center"
            :class="a.checksum === 'ok' ? 'text-emerald-500' : 'text-red-500'"
            :title="a.checksum === 'ok' ? t('mdbTrace.checksumOk') : a.checksum === 'bad' ? t('mdbTrace.checksumBad') : ''"
          >{{ a.checksum === 'ok' ? '✓' : a.checksum === 'bad' ? '✗' : '' }}</span>

          <span class="w-56 shrink-0 truncate" :class="a.entry.dir === 'tx' ? 'text-emerald-300' : 'text-zinc-100'" :title="[a.device, a.title].filter(Boolean).join(' · ')">
            <span v-if="a.device" class="text-zinc-500">{{ a.device }} · </span>{{ a.title }}
          </span>

          <span class="w-44 shrink-0 truncate text-zinc-400" :title="a.detail ?? ''">{{ a.detail }}</span>
          <span class="text-zinc-500">{{ formatWords(a.entry.words) }}</span>
        </div>
      </template>
    </div>
  </div>
</template>
