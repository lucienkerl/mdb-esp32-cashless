<script setup lang="ts">
import {
  IconBell,
  IconLoader2,
  IconPlayerPlay,
  IconPlayerStop,
  IconSettings,
} from '@tabler/icons-vue'
import { Switch } from '@/components/ui/switch'
import {
  countInputChanges,
  formatClockSeconds,
  ioTestStatus,
  isLive,
  newestIoState,
  oneWireFamily,
  remainingSeconds,
  type IoState,
} from '@/lib/ioTest'
import { timeAgo } from '@/lib/utils'
import { NTC_SENSOR_ID, parseTempSettings } from '@/lib/temperatureSensors'

/**
 * I/O test of a WROOM-1U board: live custom inputs, relay outputs you can
 * switch, the onboard NTC and whatever sits on the two 1-Wire buses.
 *
 * Starting a test asks the device (send-device-config, admin only) to publish
 * an `/io` snapshot for N seconds; the latest one lands in
 * `embeddeds.io_state`, which the page keeps up to date through realtime and
 * passes in here. The device ends the test by itself and puts the relays back
 * the way it found them.
 */
const props = defineProps<{
  embeddedId: string
  ioState?: IoState | null
  online: boolean
  /** Raw `vendingMachine.temp_sensors`: operator names for the NTC and probes. */
  tempSensors?: unknown
}>()

/** The page opens its Machine settings modal (temperature sensors section). */
const emit = defineEmits<{ openSettings: [] }>()

const { t } = useI18n()

const sensorNames = computed(() => new Map(
  parseTempSettings(props.tempSensors).filter(s => s.name).map(s => [s.id, s.name])))

const DURATIONS = [60, 120, 300, 600]
const durationSec = ref(120)

// Connector labels as printed on the WROOM-1U board (kicad README, rev 1.4).
const INPUTS = [
  { label: 'P1', gpio: 6 },
  { label: 'P2', gpio: 17 },
  { label: 'P3', gpio: 18 },
]
const RELAYS = [
  { label: 'P8', gpio: 1 },
  { label: 'P9', gpio: 2 },
]
const BUSES = [
  { label: 'P6 / P4', gpio: 15 },
  { label: 'P5', gpio: 16 },
]

// ── Clock ────────────────────────────────────────────────────────────────────
const now = ref(Date.now())
let ticker: ReturnType<typeof setInterval> | null = null
onMounted(() => { ticker = setInterval(() => { now.value = Date.now() }, 1000) })
onBeforeUnmount(() => { if (ticker) clearInterval(ticker) })

// ── Snapshot source ──────────────────────────────────────────────────────────
// The page forwards embeddeds.io_state from realtime (`ioState` prop). While a
// test is requested or running, the panel also reads the row itself every 2 s
// and shows whichever snapshot is newer, so the test keeps working when the
// realtime feed is late or never delivers.
const supabase = useSupabaseClient()
const polled = ref<IoState | null>(null)
const cur = computed<IoState | null>(() => newestIoState(props.ioState ?? null, polled.value))

const POLL_MS = 2000
let poller: ReturnType<typeof setInterval> | null = null
let polling = false

async function pollOnce() {
  if (polling) return
  polling = true
  try {
    const { data } = await (supabase as any)
      .from('embeddeds')
      .select('io_state')
      .eq('id', props.embeddedId)
      .maybeSingle()
    if (data?.io_state) polled.value = data.io_state as IoState
  } catch { /* next tick retries */ } finally {
    polling = false
  }
}

function startPolling() {
  if (poller) return
  pollOnce()
  poller = setInterval(pollOnce, POLL_MS)
}
function stopPolling() {
  if (poller) { clearInterval(poller); poller = null }
}
onBeforeUnmount(stopPolling)

// ── Status ───────────────────────────────────────────────────────────────────
const requestedAt = ref<number | null>(null)
const status = computed(() => ioTestStatus(cur.value, now.value, requestedAt.value))
const running = computed(() => status.value === 'live')
const live = computed(() => isLive(cur.value, now.value))
const remaining = computed(() => remainingSeconds(cur.value, now.value))

const statusClass = computed(() => ({
  live: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400',
  waiting: 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400',
  idle: 'bg-gray-100 text-gray-800 dark:bg-gray-800 dark:text-gray-300',
}[status.value]))

/** A request went out and the device has not answered within the stale window. */
const silent = computed(() =>
  requestedAt.value !== null && status.value === 'idle' &&
  (!cur.value?.updated_at || Date.parse(cur.value.updated_at) < requestedAt.value))

// Poll only while something is expected: a request is pending or a test runs.
watch(status, (s) => {
  if (s === 'idle') stopPolling()
  else startPolling()
}, { immediate: true })

// ── Input change counters (since the test was started) ──────────────────────
const changes = ref([0, 0, 0])
const flash = ref([false, false, false])
watch(() => cur.value?.in, (next, prev) => {
  const counted = countInputChanges(prev, next, changes.value)
  counted.forEach((c, i) => {
    if (c !== changes.value[i]) {
      flash.value[i] = true
      setTimeout(() => { flash.value[i] = false }, 600)
    }
  })
  changes.value = counted
})

// ── Commands ─────────────────────────────────────────────────────────────────
const error = ref<string | null>(null)
const starting = ref(false)
const beeping = ref(false)
/** Relay index → state we asked for, until a snapshot shows it. */
const relayPending = ref<Record<number, { want: number; at: number }>>({})

async function sendConfig(config: Record<string, unknown>) {
  const session = useSupabaseSession()
  const token = session.value?.access_token
  if (!token) throw new Error('Not authenticated')

  await $fetch('/functions/v1/send-device-config', {
    baseURL: useRuntimeConfig().public.supabase.url,
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: { device_id: props.embeddedId, config },
  })
}

function messageOf(err: unknown): string {
  const e = err as { data?: { error?: string }; message?: string }
  return e?.data?.error ?? e?.message ?? String(err)
}

async function start() {
  starting.value = true
  error.value = null
  try {
    await sendConfig({ io_test: durationSec.value })
    requestedAt.value = Date.now()
    now.value = requestedAt.value
    changes.value = [0, 0, 0]
  } catch (err) {
    error.value = messageOf(err)
  } finally {
    starting.value = false
  }
}

async function stop() {
  error.value = null
  try {
    await sendConfig({ io_test: 0 })
    requestedAt.value = null
  } catch (err) {
    error.value = messageOf(err)
  }
}

async function setRelay(index: number, on: boolean) {
  error.value = null
  relayPending.value = { ...relayPending.value, [index]: { want: on ? 1 : 0, at: Date.now() } }
  try {
    await sendConfig({ [`relay${index + 1}`]: on ? 1 : 0 })
  } catch (err) {
    error.value = messageOf(err)
    const next = { ...relayPending.value }
    delete next[index]
    relayPending.value = next
  }
}

// Clear a pending relay once the device reports it, or give up after 8 s.
watch([() => cur.value?.relay, now], () => {
  const next = { ...relayPending.value }
  let changed = false
  for (const [k, p] of Object.entries(next)) {
    const i = Number(k)
    if (cur.value?.relay?.[i] === p.want || Date.now() - p.at > 8000) {
      delete next[i]
      changed = true
    }
  }
  if (changed) relayPending.value = next
})

function relayChecked(index: number): boolean {
  const p = relayPending.value[index]
  if (p) return p.want === 1
  return cur.value?.relay?.[index] === 1
}

async function beep() {
  beeping.value = true
  error.value = null
  try {
    await sendConfig({ buzzer: true })
  } catch (err) {
    error.value = messageOf(err)
  } finally {
    setTimeout(() => { beeping.value = false }, 1000)
  }
}

onBeforeUnmount(() => {
  // The device would stop by itself at the end of the time; nobody is
  // watching any more, so end it now (this also restores the relays).
  if (running.value) sendConfig({ io_test: 0 }).catch(() => {})
})

function formatTemp(c: number | undefined): string {
  return c === undefined ? '–' : `${c.toFixed(1)} °C`
}
</script>

<template>
  <div class="space-y-6">
    <!-- Header / controls -->
    <div class="rounded-xl border bg-card p-4 sm:p-6">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-sm font-medium text-muted-foreground uppercase tracking-wide">{{ t('ioTest.title') }}</h2>
            <span class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium" :class="statusClass">
              {{ t(`ioTest.status.${status}`) }}<template v-if="running"> · {{ t('ioTest.remaining', { time: formatClockSeconds(remaining) }) }}</template>
            </span>
          </div>
          <p class="mt-1 max-w-2xl text-xs text-muted-foreground">{{ t('ioTest.hint') }}</p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button
            class="inline-flex h-8 items-center gap-1.5 rounded-md border border-input px-3 text-xs font-medium hover:bg-accent disabled:opacity-50"
            :disabled="!online || beeping"
            :title="t('ioTest.beepHint')"
            @click="beep"
          >
            <IconBell class="size-4" :class="beeping ? 'animate-pulse' : ''" />
            {{ t('ioTest.beep') }}
          </button>

          <label v-if="!running" class="flex items-center gap-1.5 text-xs text-muted-foreground">
            {{ t('ioTest.duration') }}
            <select
              v-model.number="durationSec"
              class="h-8 rounded-md border border-input bg-background px-2 text-xs focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option v-for="d in DURATIONS" :key="d" :value="d">{{ t('ioTest.durationOption', { n: d / 60 }) }}</option>
            </select>
          </label>

          <button
            v-if="!running"
            class="inline-flex h-8 items-center gap-1.5 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
            :disabled="starting || !online || status === 'waiting'"
            @click="start"
          >
            <IconLoader2 v-if="starting || status === 'waiting'" class="size-4 animate-spin" />
            <IconPlayerPlay v-else class="size-4" />
            {{ t('ioTest.start') }}
          </button>
          <button
            v-else
            class="inline-flex h-8 items-center gap-1.5 rounded-md border border-input px-3 text-xs font-medium hover:bg-accent"
            @click="stop"
          >
            <IconPlayerStop class="size-4" />
            {{ t('ioTest.stop') }}
          </button>
        </div>
      </div>

      <p v-if="error" class="mt-3 text-xs text-red-600 dark:text-red-400">{{ error }}</p>
      <p v-else-if="!online" class="mt-3 text-xs text-amber-600 dark:text-amber-500">{{ t('ioTest.offline') }}</p>
      <p v-else-if="silent" class="mt-3 text-xs text-amber-600 dark:text-amber-500">{{ t('ioTest.silent') }}</p>
      <p v-if="cur?.updated_at" class="mt-3 text-xs text-muted-foreground">
        {{ t('ioTest.updated', { time: timeAgo(cur.updated_at, t) }) }}
      </p>
    </div>

    <div class="grid gap-6 lg:grid-cols-3" :class="live ? '' : 'opacity-60'">
      <!-- Inputs -->
      <div class="rounded-xl border bg-card p-4 sm:p-6">
        <h3 class="text-sm font-medium">{{ t('ioTest.inputs') }}</h3>
        <p class="mt-1 text-xs text-muted-foreground">{{ t('ioTest.inputsHint') }}</p>
        <ul class="mt-4 space-y-3">
          <li v-for="(inp, i) in INPUTS" :key="inp.label" class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <p class="text-sm font-medium">{{ t('ioTest.input', { n: i + 1 }) }}</p>
              <p class="text-xs text-muted-foreground font-mono">{{ inp.label }} · GPIO{{ inp.gpio }}</p>
            </div>
            <div class="flex items-center gap-3">
              <span class="text-xs tabular-nums text-muted-foreground" :title="t('ioTest.changesHint')">
                {{ t('ioTest.changes', { n: changes[i] }) }}
              </span>
              <span
                v-if="cur?.in?.[i] !== undefined"
                class="inline-flex min-w-24 items-center justify-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium transition-shadow"
                :class="[
                  cur.in[i] === 0
                    ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400'
                    : 'bg-gray-100 text-gray-800 dark:bg-gray-800 dark:text-gray-300',
                  flash[i] ? 'ring-2 ring-primary' : '',
                ]"
              >
                <span class="size-2 rounded-full" :class="cur.in[i] === 0 ? 'bg-green-500' : 'bg-gray-400'" />
                {{ cur.in[i] === 0 ? t('ioTest.closed') : t('ioTest.open') }}
              </span>
              <span v-else class="min-w-24 text-center text-xs text-muted-foreground">–</span>
            </div>
          </li>
        </ul>
      </div>

      <!-- Relays -->
      <div class="rounded-xl border bg-card p-4 sm:p-6">
        <h3 class="text-sm font-medium">{{ t('ioTest.relays') }}</h3>
        <p class="mt-1 text-xs text-muted-foreground">{{ t('ioTest.relaysHint') }}</p>
        <ul class="mt-4 space-y-3">
          <li v-for="(rel, i) in RELAYS" :key="rel.label" class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <p class="text-sm font-medium">{{ t('ioTest.relay', { n: i + 1 }) }}</p>
              <p class="text-xs text-muted-foreground font-mono">{{ rel.label }} · GPIO{{ rel.gpio }}</p>
            </div>
            <div class="flex items-center gap-2">
              <IconLoader2 v-if="relayPending[i]" class="size-4 animate-spin text-muted-foreground" />
              <span class="w-8 text-right text-xs font-medium" :class="relayChecked(i) ? 'text-primary' : 'text-muted-foreground'">
                {{ relayChecked(i) ? t('ioTest.on') : t('ioTest.off') }}
              </span>
              <Switch
                :checked="relayChecked(i)"
                :disabled="!running || !!relayPending[i]"
                @update:checked="(v: boolean) => setRelay(i, v)"
              />
            </div>
          </li>
        </ul>
        <p v-if="!running" class="mt-4 text-xs text-muted-foreground">{{ t('ioTest.relaysNeedTest') }}</p>
      </div>

      <!-- Temperatures -->
      <div class="rounded-xl border bg-card p-4 sm:p-6">
        <h3 class="text-sm font-medium">{{ t('ioTest.sensors') }}</h3>
        <p class="mt-1 text-xs text-muted-foreground">{{ t('ioTest.sensorsHint') }}</p>

        <div class="mt-4 flex items-center justify-between gap-3">
          <div>
            <p class="text-sm font-medium">{{ sensorNames.get(NTC_SENSOR_ID) ?? t('ioTest.ntc') }}</p>
            <p class="text-xs text-muted-foreground font-mono">
              <template v-if="sensorNames.has(NTC_SENSOR_ID)">{{ t('ioTest.ntc') }} · </template>TH1 · GPIO7
            </p>
          </div>
          <span class="text-sm font-medium tabular-nums">{{ formatTemp(cur?.ntc) }}</span>
        </div>

        <div v-for="(bus, b) in BUSES" :key="bus.label" class="mt-4 border-t pt-3">
          <p class="text-sm font-medium">{{ t('ioTest.bus', { n: b + 1 }) }}</p>
          <p class="text-xs text-muted-foreground font-mono">{{ bus.label }} · GPIO{{ bus.gpio }}</p>

          <p v-if="!cur?.ow" class="mt-2 text-xs text-muted-foreground">
            {{ running ? t('ioTest.scanning') : '–' }}
          </p>
          <p v-else-if="(cur.ow[b] ?? []).length === 0" class="mt-2 text-xs text-muted-foreground">
            {{ t('ioTest.noDevices') }}
          </p>
          <ul v-else class="mt-2 space-y-1">
            <li v-for="dev in cur.ow[b]" :key="dev.id" class="flex items-center justify-between gap-3 text-xs">
              <span class="min-w-0 truncate font-mono text-muted-foreground" :title="dev.id">
                <span v-if="sensorNames.get(dev.id.toUpperCase())" class="mr-1 font-sans font-medium text-foreground">{{ sensorNames.get(dev.id.toUpperCase()) }}</span>
                <span v-if="oneWireFamily(dev.id)" class="mr-1 font-sans text-foreground">{{ oneWireFamily(dev.id) }}</span>{{ dev.id }}
              </span>
              <span class="shrink-0 font-medium tabular-nums">{{ formatTemp(dev.t) }}</span>
            </li>
          </ul>
        </div>
        <p v-if="cur?.ow" class="mt-3 text-xs text-muted-foreground">{{ t('ioTest.rescanHint') }}</p>

        <!-- Points operators to where sensors get a name and are picked for display -->
        <div class="mt-4 rounded-md border border-dashed bg-muted/40 p-3 text-xs text-muted-foreground">
          <p>{{ t('ioTest.sensorsSettingsHint') }}</p>
          <button
            type="button"
            class="mt-2 inline-flex items-center gap-1 font-medium text-primary hover:underline"
            @click="emit('openSettings')"
          >
            <IconSettings class="size-3.5" />
            {{ t('ioTest.openSettings') }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
