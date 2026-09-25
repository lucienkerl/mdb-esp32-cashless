/**
 * Deal validity: is an offer usable *today*, or does it only start later?
 *
 * The one question this answers for the /deals page is "can I drive to the
 * store today and get this price?". `deal_cache.valid_from/valid_until` are
 * DATE columns holding calendar days in the company's timezone, so they are
 * parsed as local calendar days here — `new Date('2026-05-04')` would parse
 * as UTC midnight and shift the boundary by the UTC offset.
 *
 * Mirrored in the iOS app (`Deal.validityStatus`), keep both in sync.
 */

export type DealValidityStatus = 'upcoming' | 'active' | 'expiring' | 'expired'

export interface DealValidityInfo {
  status: DealValidityStatus
  /** Local-midnight start day, or null if open-ended. */
  from: Date | null
  /** Local-midnight last valid day, or null if open-ended. */
  until: Date | null
  /** Whole days until the offer starts (≥ 1), only for `upcoming`. */
  startsInDays: number | null
  /** Whole days until the last valid day (0 = today is the last day). */
  daysLeft: number | null
}

/** Deals whose last day is within this many days count as `expiring`. */
export const EXPIRING_WITHIN_DAYS = 2

const DAY_MS = 24 * 60 * 60 * 1000

/** Parse `YYYY-MM-DD` (or a timestamp's date part) as a local calendar day. */
export function parseDealDate(value: string | null | undefined): Date | null {
  if (!value) return null
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(value)
  if (!m) return null
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
}

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate())
}

/** Calendar-day difference; rounding absorbs DST-length days. */
function dayDiff(from: Date, to: Date): number {
  return Math.round((to.getTime() - from.getTime()) / DAY_MS)
}

export function dealValidityInfo(
  validFrom: string | null | undefined,
  validUntil: string | null | undefined,
  now: Date = new Date(),
): DealValidityInfo {
  const today = startOfDay(now)
  const from = parseDealDate(validFrom)
  const until = parseDealDate(validUntil)
  const daysLeft = until ? dayDiff(today, until) : null

  if (daysLeft != null && daysLeft < 0) {
    return { status: 'expired', from, until, startsInDays: null, daysLeft }
  }
  if (from && from > today) {
    return { status: 'upcoming', from, until, startsInDays: dayDiff(today, from), daysLeft }
  }
  if (daysLeft != null && daysLeft <= EXPIRING_WITHIN_DAYS) {
    return { status: 'expiring', from, until, startsInDays: null, daysLeft }
  }
  return { status: 'active', from, until, startsInDays: null, daysLeft }
}

/** True when the offer can be used today (active or expiring). */
export function isValidToday(info: DealValidityInfo): boolean {
  return info.status === 'active' || info.status === 'expiring'
}

const STATUS_RANK: Record<DealValidityStatus, number> = {
  active: 0,
  expiring: 0,
  upcoming: 1,
  expired: 2,
}

/**
 * Sort comparator: valid-today first, then upcoming by start day (soonest
 * first), then expired. Ties return 0 so a stable sort keeps the caller's
 * existing order (e.g. discount desc) within each bucket.
 */
export function compareByValidity(a: DealValidityInfo, b: DealValidityInfo): number {
  const r = STATUS_RANK[a.status] - STATUS_RANK[b.status]
  if (r !== 0) return r
  if (a.status === 'upcoming' && b.status === 'upcoming') {
    return (a.from?.getTime() ?? 0) - (b.from?.getTime() ?? 0)
  }
  return 0
}

export interface ValiditySection<T> {
  /** `now`, `expired`, or `from:YYYY-MM-DD` for an upcoming start day. */
  key: string
  kind: 'now' | 'upcoming' | 'expired'
  /** Start day for `upcoming` sections. */
  from: Date | null
  startsInDays: number | null
  items: T[]
}

function dayKey(d: Date): string {
  const mm = String(d.getMonth() + 1).padStart(2, '0')
  const dd = String(d.getDate()).padStart(2, '0')
  return `${d.getFullYear()}-${mm}-${dd}`
}

/**
 * Split items into "valid now", one section per upcoming start day
 * (ascending), and "expired". Empty sections are omitted; item order within
 * a section is preserved.
 */
export function groupByValidity<T>(
  items: T[],
  infoOf: (item: T) => DealValidityInfo,
): ValiditySection<T>[] {
  const now: T[] = []
  const expired: T[] = []
  const upcoming = new Map<string, ValiditySection<T>>()

  for (const item of items) {
    const info = infoOf(item)
    if (info.status === 'upcoming' && info.from) {
      const key = `from:${dayKey(info.from)}`
      let section = upcoming.get(key)
      if (!section) {
        section = { key, kind: 'upcoming', from: info.from, startsInDays: info.startsInDays, items: [] }
        upcoming.set(key, section)
      }
      section.items.push(item)
    } else if (info.status === 'expired') {
      expired.push(item)
    } else {
      now.push(item)
    }
  }

  const result: ValiditySection<T>[] = []
  if (now.length) result.push({ key: 'now', kind: 'now', from: null, startsInDays: null, items: now })
  result.push(...[...upcoming.values()].sort((a, b) => a.from!.getTime() - b.from!.getTime()))
  if (expired.length) result.push({ key: 'expired', kind: 'expired', from: null, startsInDays: null, items: expired })
  return result
}
