import { useState, useRoute, useRouter } from '#imports'
import { watch } from 'vue'

export interface AnalyticsFilter {
  v: number                  // schema version
  from: string               // ISO 8601 UTC
  to: string                 // ISO 8601 UTC
  compare: boolean
  machines: string[]
  channels: string[]
  categories: string[]
  vatRates: number[]
}

const today = () => new Date().toISOString()
const daysAgo = (n: number) => new Date(Date.now() - n * 86400_000).toISOString()

export const DEFAULT_FILTER: AnalyticsFilter = {
  v: 1,
  from: daysAgo(30),
  to: today(),
  compare: false,
  machines: [],
  channels: [],
  categories: [],
  vatRates: [],
}

const ALLOWED_KEYS = new Set<keyof AnalyticsFilter>([
  'v', 'from', 'to', 'compare', 'machines', 'channels', 'categories', 'vatRates'
])

export function serializeFilter(f: AnalyticsFilter): string {
  // base64url-encoded JSON, only known keys
  const cleaned: Partial<AnalyticsFilter> = {}
  for (const k of ALLOWED_KEYS) cleaned[k] = (f as any)[k]
  cleaned.v = 1  // always emit current schema version
  const json = JSON.stringify(cleaned)
  // base64url
  return btoa(json).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function deserializeFilter(s: string): AnalyticsFilter {
  try {
    const padded = s.replace(/-/g, '+').replace(/_/g, '/')
    const json = atob(padded + '==='.slice((padded.length + 3) % 4))
    const raw = JSON.parse(json)
    const out: AnalyticsFilter = { ...DEFAULT_FILTER }
    for (const k of ALLOWED_KEYS) {
      if (k in raw) (out as any)[k] = raw[k]
    }
    out.v = 1  // clamp to current schema
    return out
  } catch {
    return { ...DEFAULT_FILTER }
  }
}

export function useAnalyticsFilters() {
  const filter = useState<AnalyticsFilter>('analytics-filters', () => ({ ...DEFAULT_FILTER }))

  // URL sync — read on mount (client only), write debounced on change
  if (import.meta.client) {
    const route = useRoute()
    const router = useRouter()
    const initial = (route.query.f as string | undefined)
    if (initial) {
      filter.value = deserializeFilter(initial)
    }
    let urlSyncTimer: number | null = null
    watch(filter, (val) => {
      if (urlSyncTimer) window.clearTimeout(urlSyncTimer)
      urlSyncTimer = window.setTimeout(() => {
        router.replace({ query: { ...route.query, f: serializeFilter(val) } })
      }, 300) as unknown as number
    }, { deep: true })
  }

  function reset() { filter.value = { ...DEFAULT_FILTER } }

  // Preset persistence (localStorage)
  function savePreset(name: string) {
    if (!import.meta.client) return
    const presets = JSON.parse(localStorage.getItem('analytics.presets') || '[]')
    const idx = presets.findIndex((p: any) => p.name === name)
    const entry = { name, filter: filter.value }
    if (idx >= 0) presets[idx] = entry; else presets.push(entry)
    localStorage.setItem('analytics.presets', JSON.stringify(presets))
  }
  function loadPreset(name: string) {
    if (!import.meta.client) return
    const presets = JSON.parse(localStorage.getItem('analytics.presets') || '[]')
    const found = presets.find((p: any) => p.name === name)
    if (found) filter.value = { ...DEFAULT_FILTER, ...found.filter }
  }
  function listPresets(): string[] {
    if (!import.meta.client) return []
    return JSON.parse(localStorage.getItem('analytics.presets') || '[]').map((p: any) => p.name)
  }
  function deletePreset(name: string) {
    if (!import.meta.client) return
    const presets = JSON.parse(localStorage.getItem('analytics.presets') || '[]')
    const next = presets.filter((p: any) => p.name !== name)
    localStorage.setItem('analytics.presets', JSON.stringify(next))
  }

  return { filter, reset, savePreset, loadPreset, listPresets, deletePreset }
}
