import { useNow } from '@vueuse/core'
import {
  deviceConnectivity,
  durationParts,
  formatContactClock,
  type Connectivity,
  type ConnectivityState,
  type EmbeddedLike,
} from '@/lib/connectivity'
import { timeAgo } from '@/lib/utils'

/**
 * Labels and colours for the device connectivity of `app/lib/connectivity.ts`,
 * with a clock that ticks every 30 s so "contact 2 min ago" and the
 * stale/online decision move on by themselves.
 */
export function useConnectivity() {
  const { t, locale } = useI18n()
  const now = useNow({ interval: 30_000 })

  const of = (embedded: EmbeddedLike | null | undefined): Connectivity => deviceConnectivity(embedded, now.value)

  // timeAgo reads Date.now(); touching `now` keeps the label reactive to the tick.
  const ago = (d: Date | null): string => {
    void now.value
    return d ? timeAgo(d.toISOString(), t) : '—'
  }
  const clock = (d: Date | null): string => (d ? formatContactClock(d, now.value, locale.value) : '—')

  const duration = (ms: number): string => {
    const p = durationParts(ms)
    if (p.days > 0) return t('connectivity.duration.days', { days: p.days, hours: p.hours })
    if (p.hours > 0) return t('connectivity.duration.hours', { hours: p.hours, minutes: p.minutes })
    return t('connectivity.duration.minutes', { minutes: p.minutes })
  }

  const stateLabel = (c: Connectivity): string => t(`connectivity.state.${c.state}`)

  /** The one line under a status: "Contact 2 min ago", "Offline since Mon 14:32 · 2h ago", … */
  const timeLabel = (c: Connectivity): string => {
    switch (c.state) {
      case 'online': return t('connectivity.time.contact', { ago: ago(c.lastContactAt) })
      case 'stale': return t('connectivity.time.lastContact', { ago: ago(c.lastContactAt) })
      case 'offline': return c.since
        ? t('connectivity.time.offlineSince', { clock: clock(c.since), ago: ago(c.since) })
        : stateLabel(c)
      case 'updating': return t('connectivity.time.updateStarted', { ago: ago(c.since) })
      case 'never': return t('connectivity.time.never')
      case 'none': return t('connectivity.time.noDevice')
    }
  }

  const readerLabel = (c: Connectivity): string | null => (c.reader ? t(`connectivity.reader.${c.reader}`) : null)

  return { now, of, ago, clock, duration, stateLabel, timeLabel, readerLabel, chipClass, dotClass, textClass }
}

export function chipClass(state: ConnectivityState): string {
  switch (state) {
    case 'online': return 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
    case 'stale': return 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400'
    case 'offline': return 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400'
    case 'updating': return 'bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-300'
    default: return 'bg-muted text-muted-foreground'
  }
}

export function dotClass(state: ConnectivityState): string {
  switch (state) {
    case 'online': return 'bg-green-500'
    case 'stale': return 'bg-amber-500'
    case 'offline': return 'bg-red-500'
    case 'updating': return 'bg-purple-500'
    default: return 'bg-muted-foreground/40'
  }
}

/** Colour for the time line when it carries the problem (offline / stale). */
export function textClass(state: ConnectivityState): string {
  switch (state) {
    case 'offline': return 'text-red-600 dark:text-red-400'
    case 'stale': return 'text-amber-700 dark:text-amber-400'
    default: return 'text-muted-foreground'
  }
}
