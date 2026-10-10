import { computed, onUnmounted, ref, useSupabaseClient } from '#imports'
import {
  MAX_TRACE_ENTRIES,
  rowToEntries,
  type MdbTraceRow,
  type TraceEntry,
} from '~/lib/mdbTrace'

/** How far back the console looks when it opens (a trace may already be running). */
const BACKLOG_MINUTES = 10
const BACKLOG_ROWS = 200

/** No batch for this long while a trace should be running means nothing is arriving. */
export const SILENCE_MS = 12_000
/** A batch within this window counts as "receiving". */
const RECEIVING_MS = 4_000

/** Mirrors MDB_TRACE_MAX_SECONDS in the firmware and send-device-config. */
export const MAX_TRACE_SECONDS = 1800

/**
 * Live MDB bus trace for one device.
 *
 * Starting a trace asks the device (send-device-config, admin only) to publish
 * its raw bus words for N seconds; they arrive as `mdb_trace` rows over
 * realtime. The device stops by itself when the time is up, so closing the page
 * never leaves a trace running forever — `stop()` just ends it sooner.
 */
export function useMdbTrace() {
  const supabase = useSupabaseClient()

  const entries = ref<TraceEntry[]>([])
  const error = ref<string | null>(null)
  const starting = ref(false)

  /** Client-side estimate of when the device stops tracing (epoch ms). */
  const activeUntil = ref<number | null>(null)
  const startedAt = ref<number | null>(null)
  const lastBatchAt = ref<number | null>(null)
  const now = ref(Date.now())

  const seenRows = new Set<string>()
  let ticker: ReturnType<typeof setInterval> | null = null

  function ensureTicker() {
    if (ticker) return
    ticker = setInterval(() => { now.value = Date.now() }, 1000)
  }

  const running = computed(() => activeUntil.value !== null && now.value < activeUntil.value)
  const remainingSec = computed(() =>
    running.value ? Math.max(0, Math.ceil((activeUntil.value! - now.value) / 1000)) : 0)
  const receiving = computed(() =>
    lastBatchAt.value !== null && now.value - lastBatchAt.value < RECEIVING_MS)
  /** Started a while ago and still nothing: device offline, or firmware without trace support. */
  const silent = computed(() =>
    running.value && startedAt.value !== null &&
    now.value - Math.max(startedAt.value, lastBatchAt.value ?? 0) > SILENCE_MS)

  /** Add one stored batch; ignores a batch already shown (backlog vs realtime overlap). */
  function ingest(row: MdbTraceRow) {
    const key = String(row.id)
    if (seenRows.has(key)) return
    seenRows.add(key)

    const fresh = rowToEntries(row)
    if (fresh.length === 0) return

    entries.value.push(...fresh)
    if (entries.value.length > MAX_TRACE_ENTRIES) {
      entries.value.splice(0, entries.value.length - MAX_TRACE_ENTRIES)
    }
    lastBatchAt.value = Date.now()
    ensureTicker()
  }

  async function fetchRecent(embeddedId: string) {
    const since = new Date(Date.now() - BACKLOG_MINUTES * 60_000).toISOString()
    const { data, error: err } = await (supabase as any)
      .from('mdb_trace')
      .select('*')
      .eq('embedded_id', embeddedId)
      .gt('created_at', since)
      .order('created_at', { ascending: false })
      .limit(BACKLOG_ROWS)

    if (err) { error.value = err.message ?? String(err); return }

    // Newest first from the query; the console reads oldest first.
    const rows = ((data ?? []) as MdbTraceRow[]).slice().reverse()
    // Only the history of an already-running trace is useful, and only if the
    // live feed has not started filling the list first.
    if (entries.value.length === 0) rows.forEach(ingest)
  }

  function subscribe(embeddedId: string) {
    const channel = (supabase as any)
      .channel(`mdb-trace-${embeddedId}`)
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'mdb_trace', filter: `embedded_id=eq.${embeddedId}` },
        (payload: { new: MdbTraceRow }) => ingest(payload.new),
      )
      .subscribe()

    return () => (supabase as any).removeChannel(channel)
  }

  async function sendTraceConfig(embeddedId: string, seconds: number) {
    const session = useSupabaseSession()
    const token = session.value?.access_token
    if (!token) throw new Error('Not authenticated')

    await $fetch('/functions/v1/send-device-config', {
      baseURL: useRuntimeConfig().public.supabase.url,
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: { device_id: embeddedId, config: { mdb_trace: seconds } },
    })
  }

  function messageOf(err: unknown): string {
    const e = err as { data?: { error?: string }; message?: string }
    return e?.data?.error ?? e?.message ?? String(err)
  }

  async function start(embeddedId: string, seconds: number) {
    const clamped = Math.min(MAX_TRACE_SECONDS, Math.max(1, Math.floor(seconds)))
    starting.value = true
    error.value = null
    try {
      await sendTraceConfig(embeddedId, clamped)
      const t = Date.now()
      now.value = t
      startedAt.value = t
      activeUntil.value = t + clamped * 1000
      ensureTicker()
    } catch (err) {
      error.value = messageOf(err)
    } finally {
      starting.value = false
    }
  }

  async function stop(embeddedId: string) {
    error.value = null
    try {
      await sendTraceConfig(embeddedId, 0)
      activeUntil.value = null
      startedAt.value = null
    } catch (err) {
      error.value = messageOf(err)
    }
  }

  function clear() {
    entries.value = []
    seenRows.clear()
  }

  function dispose() {
    if (ticker) { clearInterval(ticker); ticker = null }
  }
  onUnmounted(dispose)

  return {
    entries,
    error,
    starting,
    running,
    remainingSec,
    receiving,
    silent,
    fetchRecent,
    subscribe,
    start,
    stop,
    clear,
    dispose,
  }
}
