import { classifyDeal, isCardSuppressed, type DealVerdict, type PurchaseSummary } from '~/lib/purchaseComparison'

export interface DealKeyword {
  id: string
  label: string | null
  terms: string[]
  product_ids: string[]
  created_at: string
  updated_at: string
}

export interface Deal {
  id: string
  product_id: string | null
  keyword_id: string | null
  matched_term: string | null
  retailer: string
  deal_title: string
  deal_price: number | null
  regular_price: number | null
  discount_pct: number | null
  valid_from: string | null
  valid_until: string | null
  image_url: string | null
  image_url_large: string | null
  source_url: string | null
  external_url: string | null
  matched_by: string
  confidence: number
  matched_tokens: string[] | null
  requires_app: boolean
  fetched_at: string
  offer_id: string
  products: {
    id: string
    name: string
    image_path: string | null
    sellprice: number | null
  } | null
  deal_keywords: {
    id: string
    label: string | null
    terms: string[]
    deal_keyword_products: Array<{
      products: { id: string; name: string; image_path: string | null; sellprice: number | null }
    }>
  } | null
}

interface DealSearchResponse {
  deals: Deal[]
  fromCache: boolean
  searchedProducts?: number
  totalDeals?: number
  error?: string
  message?: string
}

/**
 * Deduplicated view of a deal: one card per (retailer, offer_id), aggregating
 * all matched products (when the same offer fuzzy-matched multiple catalog
 * items). The `primary` field carries the highest-confidence raw row — used
 * for sorting and to back the existing detail-sheet UI.
 *
 * `matchedProducts` contains every product the offer matched against (across
 * all duplicates of the same offer), so the user can see "this Red Bull deal
 * applies to Red Bull Energy / Red Bull Sugarfree / …" without having three
 * separate cards.
 */
export interface DedupedDeal {
  /** Stable cross-refresh key: `${retailer}::${offer_id}` */
  key: string
  retailer: string
  offer_id: string
  primary: Deal
  matchedProducts: Array<{
    id: string
    name: string
    image_path: string | null
    sellprice: number | null
    confidence: number
  }>
  /** Keyword groups that matched this offer (one entry per keyword group) */
  matchedKeywords: Array<{
    id: string
    label: string | null
    matched_term: string | null
    products: Array<{ id: string; name: string; image_path: string | null; sellprice: number | null }>
  }>
  archived: boolean
  pinned: boolean
  pinnedAt: string | null
}

interface DealUserStateRow {
  retailer: string
  offer_id: string
  archived_at: string | null
  pinned_at: string | null
}

// Country presets — must stay in sync with edge function COUNTRY_PRESETS
export interface DealsConfig {
  generic_terms: string[]
  wildcard_phrases: string[]
  app_detection_patterns: string[]
}

export const DEALS_COUNTRY_PRESETS: Record<string, DealsConfig> = {
  DE: {
    generic_terms: [
      'verschiedene', 'sorten', 'versch', 'diverse', 'oder', 'und', 'z.b',
      'zb', 'jede', 'jeder', 'je',
      'stück', 'packung', 'dose', 'flasche', 'dosen', 'flaschen',
      'kasten', 'kiste', 'krat', 'tray', 'pack', 'beutel', 'becher',
      'tafel', 'riegel', 'tube', 'glas',
      'drink', 'drinks', 'getränk', 'getränke',
      'light', 'free', 'sugar',
      'bio', 'vegan',
      'ml', 'cl', 'liter', 'kg', 'gr',
    ],
    wildcard_phrases: [
      'verschiedene', 'versch', 'diverse', 'sorten', 'sort',
      'alle sorten', 'viele sorten', 'mehrere sorten',
    ],
    app_detection_patterns: [
      'mit app', 'in der app',
      'netto-app', 'netto app',
      'lidl plus', 'lidl-plus',
      'rewe bonus', 'rewe-bonus',
      'penny app', 'penny-app',
      'kaufland card', 'kaufland-card',
      'app-preis', 'app preis', 'apppreis',
      'nur mit',
      'app-coupon', 'app coupon',
      'digital-coupon', 'digital coupon',
    ],
  },
  AT: {
    generic_terms: [
      'verschiedene', 'sorten', 'versch', 'diverse', 'oder', 'und', 'z.b',
      'zb', 'jede', 'jeder', 'je',
      'stück', 'packung', 'dose', 'flasche', 'dosen', 'flaschen',
      'kasten', 'kiste', 'krat', 'tray', 'pack', 'beutel', 'becher',
      'tafel', 'riegel', 'tube', 'glas',
      'drink', 'drinks', 'getränk', 'getränke',
      'light', 'free', 'sugar',
      'bio', 'vegan',
      'ml', 'cl', 'liter', 'kg', 'gr',
    ],
    wildcard_phrases: [
      'verschiedene', 'versch', 'diverse', 'sorten', 'sort',
      'alle sorten', 'viele sorten', 'mehrere sorten',
    ],
    app_detection_patterns: [
      'mit app', 'in der app',
      'billa plus', 'billa-plus',
      'jö bonus', 'jö-bonus', 'jö app',
      'spar app', 'spar-app',
      'lidl plus', 'lidl-plus',
      'app-preis', 'app preis',
      'nur mit',
    ],
  },
}

export function getDealsPreset(countryCode: string): DealsConfig {
  return DEALS_COUNTRY_PRESETS[countryCode] ?? DEALS_COUNTRY_PRESETS['DE']
}

export function useDeals() {
  const supabase = useSupabaseClient()
  const user = useSupabaseUser()
  const { organization } = useOrganization()

  // ── EK (purchase-price) comparison ───────────────────────────────────────
  const { fetchSummaries } = usePurchasePrices()
  const ekSummaries = ref<Record<string, PurchaseSummary>>({})

  /** All catalog product ids an offer matched (name matches + keyword-group products). */
  function dealProductIds(d: DedupedDeal): string[] {
    const ids = new Set<string>()
    for (const p of d.matchedProducts) ids.add(p.id)
    for (const k of d.matchedKeywords) for (const p of k.products) ids.add(p.id)
    return [...ids]
  }

  /** Fetch EK summaries for every product referenced by the current deal set. */
  async function fetchEkSummaries() {
    const ids = new Set<string>()
    for (const d of deals.value) {
      if (d.products?.id) ids.add(d.products.id)
      for (const kp of d.deal_keywords?.deal_keyword_products ?? []) {
        if (kp.products?.id) ids.add(kp.products.id)
      }
    }
    ekSummaries.value = await fetchSummaries([...ids])
  }

  const VERDICT_RANK: Record<DealVerdict, number> = {
    good_best: 5, good: 4, similar: 3, worse: 2, no_ek: 1, implausible: 0,
  }

  /** Per-deal EK comparison: per-product verdicts, card-suppression flag, best verdict for the pill. */
  function dealEk(d: DedupedDeal) {
    const dealGross = d.primary.deal_price
    const perProduct = dealProductIds(d).map((id) => ({
      productId: id,
      summary: ekSummaries.value[id] ?? null,
      ...classifyDeal(dealGross, ekSummaries.value[id]),
    }))
    const verdicts = perProduct.map((p) => p.verdict)
    const suppressed = isCardSuppressed(verdicts)
    const ranked = verdicts.filter((v) => v !== 'no_ek').sort((a, b) => VERDICT_RANK[b] - VERDICT_RANK[a])
    const bestVerdict = ranked[0] ?? null
    return { perProduct, suppressed, bestVerdict }
  }

  const deals = ref<Deal[]>([])
  const loading = ref(false)
  const error = ref('')
  const fromCache = ref(false)
  const searchedProducts = ref(0)
  const lastFetchedAt = ref<string | null>(null)
  // True when deal-search reports no enabled deal-source provider — drives a
  // distinct empty state on /deals that points the admin at the extensions UI.
  const noProviders = ref(false)

  // Per-user state for each (retailer, offer_id) — archived / pinned flags.
  // Keyed by `${retailer}::${offer_id}` to match DedupedDeal.key.
  const userStates = ref<Map<string, { archived: boolean; pinnedAt: string | null }>>(new Map())

  // Surface the most recent archive/pin failure so the UI can show it
  // (e.g. RLS denial or missing migration → otherwise looks like the button
  // does nothing because the optimistic update gets rolled back silently).
  const userStateError = ref<string | null>(null)

  // Deal search settings
  const dealsEnabled = ref(false)
  const dealsZipCode = ref('')
  // Hour-of-day (0..23, company timezone) for the daily auto-refresh; null = off.
  const dealsRefreshHour = ref<number | null>(null)
  const settingsLoading = ref(false)
  const settingsError = ref('')
  const settingsSuccess = ref('')

  // Configurable keyword lists (null = use country defaults)
  interface DealsConfigOverrides {
    generic_terms: string[] | null
    wildcard_phrases: string[] | null
    app_detection_patterns: string[] | null
    retailer_prospekt_urls: Record<string, string> | null
  }
  const dealsConfig = ref<DealsConfigOverrides>({
    generic_terms: null,
    wildcard_phrases: null,
    app_detection_patterns: null,
    retailer_prospekt_urls: null,
  })
  const hasCustomConfig = computed(() => {
    const c = dealsConfig.value
    return c.generic_terms !== null || c.wildcard_phrases !== null
      || c.app_detection_patterns !== null || c.retailer_prospekt_urls !== null
  })

  // ── New-deal tracking (inbox model) ──────────────────────────────────────
  // Keys (`${retailer}::${offerId}`) of offers that are NEW + unhandled for the
  // current user: first seen after their baseline and not yet pinned/archived.
  // Computed server-side by get_new_deal_keys (which also seeds the baseline).
  const newDealKeys = ref<Set<string>>(new Set())

  async function fetchNewDealKeys() {
    const { data, error: err } = await (supabase as any).rpc('get_new_deal_keys')
    if (!err && data) {
      newDealKeys.value = new Set(
        (data as Array<{ retailer: string; offer_id: string }>).map(
          (r) => `${r.retailer}::${r.offer_id}`,
        ),
      )
    }
  }

  /** A deal is "new" if the RPC flagged it AND the user hasn't pinned/archived
   *  it yet this session (so the badge clears optimistically on pin/archive). */
  function isNew(deal: DedupedDeal): boolean {
    return newDealKeys.value.has(deal.key) && !deal.archived && !deal.pinned
  }

  // Seeing a new offer in the list is enough to clear it. The card reports
  // itself once it scrolls into view; keys are batched into one
  // mark_deals_seen call. The local badge deliberately stays until the next
  // fetchNewDealKeys (reload / pull-to-refresh), so the user actually gets to
  // see which offers were new — the server-side count drops immediately.
  const seenQueue = new Map<string, { retailer: string; offer_id: string }>()
  const seenSent = new Set<string>()
  let seenTimer: ReturnType<typeof setTimeout> | null = null

  function markDealSeen(deal: DedupedDeal) {
    if (!newDealKeys.value.has(deal.key) || seenSent.has(deal.key)) return
    seenSent.add(deal.key)
    seenQueue.set(deal.key, { retailer: deal.retailer, offer_id: deal.offer_id })
    if (!seenTimer) seenTimer = setTimeout(flushSeenDeals, 1000)
  }

  async function flushSeenDeals() {
    if (seenTimer) { clearTimeout(seenTimer); seenTimer = null }
    if (seenQueue.size === 0) return
    const batch = [...seenQueue.entries()]
    seenQueue.clear()
    const { error: err } = await (supabase as any).rpc('mark_deals_seen', {
      p_keys: batch.map(([, v]) => v),
    })
    if (err) {
      console.error('[useDeals] mark_deals_seen failed:', err)
      // Allow a retry the next time the card comes into view.
      for (const [key] of batch) seenSent.delete(key)
    }
  }

  async function loadSettings() {
    if (!organization.value?.id) return
    const { data } = await supabase
      .from('companies')
      .select('deals_enabled, deals_zip_code, deals_config, deals_refresh_hour')
      .eq('id', organization.value.id)
      .single()
    if (data) {
      dealsEnabled.value = (data as any).deals_enabled ?? false
      dealsZipCode.value = (data as any).deals_zip_code ?? ''
      dealsRefreshHour.value = (data as any).deals_refresh_hour ?? null
      const cfg = (data as any).deals_config
      if (cfg) {
        dealsConfig.value = {
          generic_terms: cfg.generic_terms ?? null,
          wildcard_phrases: cfg.wildcard_phrases ?? null,
          app_detection_patterns: cfg.app_detection_patterns ?? null,
          retailer_prospekt_urls: cfg.retailer_prospekt_urls ?? null,
        }
      }
    }
  }

  // Hour the daily auto-refresh defaults to the first time deals are switched
  // on. 06:00 (company timezone) refreshes the cache before business hours.
  const DEFAULT_DEALS_REFRESH_HOUR = 6

  /**
   * Toggle the deals feature. When switching ON, seed the daily auto-refresh
   * hour if it isn't set yet — so enabling deals "just works" with automatic
   * refresh, mirroring the Marktguru provider auto-seed in saveSettings().
   * Only fills an unset hour, so a deliberate "Off" on an already-enabled
   * account is never overwritten.
   */
  function setDealsEnabled(enabled: boolean) {
    dealsEnabled.value = enabled
    if (enabled && dealsRefreshHour.value == null) {
      dealsRefreshHour.value = DEFAULT_DEALS_REFRESH_HOUR
    }
  }

  async function saveSettings() {
    settingsError.value = ''
    settingsSuccess.value = ''
    if (!organization.value?.id) return

    // Build config: only include non-null overrides
    const cfg = dealsConfig.value
    const configToSave = (cfg.generic_terms || cfg.wildcard_phrases || cfg.app_detection_patterns || cfg.retailer_prospekt_urls)
      ? {
          ...(cfg.generic_terms ? { generic_terms: cfg.generic_terms } : {}),
          ...(cfg.wildcard_phrases ? { wildcard_phrases: cfg.wildcard_phrases } : {}),
          ...(cfg.app_detection_patterns ? { app_detection_patterns: cfg.app_detection_patterns } : {}),
          ...(cfg.retailer_prospekt_urls ? { retailer_prospekt_urls: cfg.retailer_prospekt_urls } : {}),
        }
      : null

    settingsLoading.value = true
    try {
      const { error: err } = await supabase
        .from('companies')
        .update({
          deals_enabled: dealsEnabled.value,
          deals_zip_code: dealsZipCode.value.trim() || null,
          deals_config: configToSave,
          deals_refresh_hour: dealsRefreshHour.value,
        })
        .eq('id', organization.value.id)
      if (err) throw err

      // Auto-enable Marktguru as the default deal-source provider the first
      // time deals are turned on, so enabling deals "just works". The provider
      // pattern otherwise needs a separate toggle, which surfaces a confusing
      // "No deal-source providers enabled" empty state. Only seeds when NO
      // deal-source row exists yet — never re-enables one the user disabled.
      if (dealsEnabled.value) {
        const { data: existingProviders } = await supabase
          .from('provider_settings')
          .select('provider_id')
          .eq('company_id', organization.value.id)
          .eq('extension_point', 'deal-source')
          .limit(1)
        if (!existingProviders || existingProviders.length === 0) {
          const { error: seedErr } = await supabase
            .from('provider_settings')
            .insert({
              company_id: organization.value.id,
              extension_point: 'deal-source',
              provider_id: 'marktguru',
              enabled: true,
              config: {},
            })
          if (seedErr) console.error('[useDeals] marktguru auto-seed failed:', seedErr)
        }
      }

      settingsSuccess.value = 'saved'
    } catch (err: unknown) {
      settingsError.value = err instanceof Error ? err.message : 'Failed to save settings'
    } finally {
      settingsLoading.value = false
    }
  }

  function resetConfig() {
    dealsConfig.value = {
      generic_terms: null,
      wildcard_phrases: null,
      app_detection_patterns: null,
      retailer_prospekt_urls: null,
    }
  }

  async function fetchDeals(forceRefresh = false) {
    if (!organization.value?.id) return
    loading.value = true
    error.value = ''
    try {
      const { data, error: fnError } = await supabase.functions.invoke('deal-search', {
        body: { forceRefresh, minConfidence: 0.5 },
      })
      if (fnError) throw fnError
      const res = data as DealSearchResponse
      if (res.error) throw new Error(res.error)
      deals.value = res.deals ?? []
      fromCache.value = res.fromCache ?? false
      searchedProducts.value = res.searchedProducts ?? 0
      noProviders.value = res.message === 'No deal-source providers enabled'
      // Use the fetched_at from the first deal, or current time for fresh data
      if (deals.value.length > 0 && deals.value[0].fetched_at) {
        lastFetchedAt.value = deals.value[0].fetched_at
      } else if (!res.fromCache) {
        lastFetchedAt.value = new Date().toISOString()
      }
    } catch (err: unknown) {
      error.value = err instanceof Error ? err.message : 'Failed to fetch deals'
    } finally {
      loading.value = false
    }
  }

  // ── User-state (archive / pin) ──────────────────────────────────────────

  function stateKey(retailer: string, offerId: string): string {
    return `${retailer}::${offerId}`
  }

  /** Resolve the current user id. useSupabaseUser() is a Vue ref that may
   *  not be hydrated yet on first render (same workaround as useMachineTrays
   *  logActivity). Falls back to auth.getSession() which is always current. */
  async function resolveUserId(): Promise<string | null> {
    if (user.value?.id) return user.value.id
    const { data: { session } } = await supabase.auth.getSession()
    return session?.user?.id ?? null
  }

  async function fetchUserStates() {
    const uid = await resolveUserId()
    if (!organization.value?.id || !uid) return
    const { data, error: err } = await supabase
      .from('deal_user_state')
      .select('retailer, offer_id, archived_at, pinned_at')
      .eq('company_id', organization.value.id)
      .eq('user_id', uid)
    if (err) {
      console.error('[useDeals] fetchUserStates failed:', err)
      return
    }
    const map = new Map<string, { archived: boolean; pinnedAt: string | null }>()
    for (const row of (data ?? []) as DealUserStateRow[]) {
      map.set(stateKey(row.retailer, row.offer_id), {
        archived: row.archived_at != null,
        pinnedAt: row.pinned_at,
      })
    }
    userStates.value = map
  }

  /** Optimistically updates the local state map and writes to the DB. */
  async function upsertUserState(
    retailer: string,
    offerId: string,
    patch: { archived_at?: string | null; pinned_at?: string | null },
  ) {
    const uid = await resolveUserId()
    if (!organization.value?.id || !uid) {
      const reason = !organization.value?.id ? 'no organization' : 'no user'
      console.warn('[useDeals] upsertUserState skipped:', reason)
      userStateError.value = `Cannot save: ${reason}`
      return
    }
    const key = stateKey(retailer, offerId)
    const prev = userStates.value.get(key) ?? { archived: false, pinnedAt: null }
    const next = { ...prev }
    if ('archived_at' in patch) next.archived = patch.archived_at != null
    if ('pinned_at' in patch) next.pinnedAt = patch.pinned_at ?? null
    // New Map ref so Vue picks up the change.
    const newMap = new Map(userStates.value)
    newMap.set(key, next)
    userStates.value = newMap

    const payload = {
      user_id: uid,
      company_id: organization.value.id,
      retailer,
      offer_id: offerId,
      ...patch,
    }
    const { error: err } = await supabase
      .from('deal_user_state')
      .upsert(payload, { onConflict: 'user_id,company_id,retailer,offer_id' })
    if (err) {
      console.error('[useDeals] upsertUserState failed:', err)
      userStateError.value = err.message ?? 'Failed to update deal state'
      // Roll back the optimistic update on failure.
      const rollback = new Map(userStates.value)
      rollback.set(key, prev)
      userStates.value = rollback
    } else {
      userStateError.value = null
    }
  }

  function archiveDeal(retailer: string, offerId: string) {
    return upsertUserState(retailer, offerId, { archived_at: new Date().toISOString() })
  }
  function unarchiveDeal(retailer: string, offerId: string) {
    return upsertUserState(retailer, offerId, { archived_at: null })
  }
  function pinDeal(retailer: string, offerId: string) {
    return upsertUserState(retailer, offerId, { pinned_at: new Date().toISOString() })
  }
  function unpinDeal(retailer: string, offerId: string) {
    return upsertUserState(retailer, offerId, { pinned_at: null })
  }

  // ── Deduplicated deals ──────────────────────────────────────────────────

  /**
   * Collapse raw deal_cache rows into one entry per (retailer, offer_id),
   * aggregating matched products / keyword groups across the duplicates and
   * applying user state (archived / pinned). The "primary" raw deal is the
   * highest-confidence row, used by the existing detail-sheet UI.
   */
  const dedupedDeals = computed<DedupedDeal[]>(() => {
    const groups = new Map<string, Deal[]>()
    for (const d of deals.value) {
      const k = stateKey(d.retailer, d.offer_id)
      const existing = groups.get(k) ?? []
      existing.push(d)
      groups.set(k, existing)
    }

    const result: DedupedDeal[] = []
    for (const [key, rows] of groups) {
      // Sort by confidence desc; primary is the strongest match.
      rows.sort((a, b) => (b.confidence ?? 0) - (a.confidence ?? 0))
      const primary = rows[0]

      // Aggregate distinct products across all rows for this offer.
      const productMap = new Map<string, DedupedDeal['matchedProducts'][number]>()
      // Aggregate distinct keyword groups across all rows for this offer.
      const keywordMap = new Map<string, DedupedDeal['matchedKeywords'][number]>()

      for (const r of rows) {
        if (r.products) {
          const existing = productMap.get(r.products.id)
          if (!existing || (r.confidence ?? 0) > existing.confidence) {
            productMap.set(r.products.id, {
              id: r.products.id,
              name: r.products.name,
              image_path: r.products.image_path,
              sellprice: r.products.sellprice,
              confidence: r.confidence ?? 0,
            })
          }
        }
        if (r.deal_keywords) {
          if (!keywordMap.has(r.deal_keywords.id)) {
            keywordMap.set(r.deal_keywords.id, {
              id: r.deal_keywords.id,
              label: r.deal_keywords.label,
              matched_term: r.matched_term,
              products: r.deal_keywords.deal_keyword_products.map((kp) => kp.products),
            })
          }
        }
      }

      const state = userStates.value.get(key)
      result.push({
        key,
        retailer: primary.retailer,
        offer_id: primary.offer_id,
        primary,
        matchedProducts: Array.from(productMap.values()).sort((a, b) => b.confidence - a.confidence),
        matchedKeywords: Array.from(keywordMap.values()),
        archived: state?.archived ?? false,
        pinned: state?.pinnedAt != null,
        pinnedAt: state?.pinnedAt ?? null,
      })
    }

    return result
  })

  // Active deals (not archived). Pinned ones float to the top, then sorted
  // by discount_pct desc (matching the edge function order).
  const activeDeals = computed(() => {
    const list = dedupedDeals.value.filter((d) => !d.archived)
    list.sort((a, b) => {
      if (a.pinned && !b.pinned) return -1
      if (!a.pinned && b.pinned) return 1
      if (a.pinned && b.pinned) {
        // Most-recently pinned first.
        return (b.pinnedAt ?? '').localeCompare(a.pinnedAt ?? '')
      }
      const da = a.primary.discount_pct ?? -1
      const db = b.primary.discount_pct ?? -1
      return db - da
    })
    return list
  })

  const suppressedKeys = computed(() => {
    const s = new Set<string>()
    for (const d of activeDeals.value) if (dealEk(d).suppressed) s.add(d.key)
    return s
  })
  // Grid shows these; suppressed (deal > highest recorded EK → likely mismatch) are hidden.
  const visibleActiveDeals = computed(() => activeDeals.value.filter((d) => !suppressedKeys.value.has(d.key)))
  const suppressedActiveDeals = computed(() => activeDeals.value.filter((d) => suppressedKeys.value.has(d.key)))

  const archivedDeals = computed(() => dedupedDeals.value.filter((d) => d.archived))

  // Group deals by retailer
  const dealsByRetailer = computed(() => {
    const grouped = new Map<string, Deal[]>()
    for (const deal of deals.value) {
      const existing = grouped.get(deal.retailer) ?? []
      existing.push(deal)
      grouped.set(deal.retailer, existing)
    }
    return grouped
  })

  // Group deals by product
  const dealsByProduct = computed(() => {
    const grouped = new Map<string, Deal[]>()
    for (const deal of deals.value) {
      const name = deal.products?.name ?? deal.product_id
      const existing = grouped.get(name) ?? []
      existing.push(deal)
      grouped.set(name, existing)
    }
    return grouped
  })

  // Stats — based on deduped active (non-archived) deals so the user sees
  // numbers that match what's on screen.
  const totalDeals = computed(() => visibleActiveDeals.value.length)
  const uniqueRetailers = computed(() => new Set(visibleActiveDeals.value.map((d) => d.retailer)).size)
  const avgDiscount = computed(() => {
    const withDiscount = visibleActiveDeals.value.filter(
      (d) => d.primary.discount_pct != null && d.primary.discount_pct > 0,
    )
    if (withDiscount.length === 0) return 0
    return Math.round(
      withDiscount.reduce((sum, d) => sum + (d.primary.discount_pct ?? 0), 0) / withDiscount.length,
    )
  })
  const archivedCount = computed(() => archivedDeals.value.length)

  // Count of new/unhandled deals (reacts to optimistic pin/archive via isNew).
  const newDealsCount = computed(() => visibleActiveDeals.value.filter(isNew).length)

  // ── Keyword groups ─────────────────────────────────────────────────────────

  const keywords = useState<DealKeyword[]>('deal-keywords', () => [])

  async function fetchKeywords() {
    const { data, error: err } = await supabase
      .from('deal_keywords')
      .select('id, label, terms, created_at, updated_at, deal_keyword_products(product_id)')
      .order('label', { ascending: true, nullsFirst: false })

    if (err) {
      console.error('[useDeals] fetchKeywords failed:', err)
      keywords.value = []
      return
    }
    keywords.value = (data ?? []).map((row: any) => ({
      id: row.id,
      label: row.label,
      terms: row.terms ?? [],
      product_ids: (row.deal_keyword_products ?? []).map((kp: any) => kp.product_id),
      created_at: row.created_at,
      updated_at: row.updated_at,
    }))
  }

  async function createKeyword(input: {
    label?: string | null
    terms: string[]
    product_ids: string[]
  }): Promise<DealKeyword | null> {
    // Reuse the already-captured `organization` ref at the top of `useDeals()` —
    // do NOT call useOrganization() again inside this function (existing pattern
    // in this composable is to destructure once at the top).
    if (!organization.value) return null

    const { data, error: err } = await supabase
      .from('deal_keywords')
      .insert({
        company_id: organization.value.id,
        label: input.label ?? null,
        terms: input.terms,
      })
      .select('id, label, terms, created_at, updated_at')
      .single()

    if (err || !data) {
      console.error('[useDeals] createKeyword failed:', err)
      return null
    }

    if (input.product_ids.length > 0) {
      const { error: linkErr } = await supabase
        .from('deal_keyword_products')
        .insert(input.product_ids.map((pid) => ({ keyword_id: data.id, product_id: pid })))
      if (linkErr) console.error('[useDeals] createKeyword link failed:', linkErr)
    }

    await fetchKeywords()
    return keywords.value.find((k) => k.id === data.id) ?? null
  }

  async function updateKeyword(
    id: string,
    patch: { label?: string | null; terms?: string[] },
  ) {
    const { error: err } = await supabase
      .from('deal_keywords')
      .update(patch)
      .eq('id', id)
    if (err) {
      console.error('[useDeals] updateKeyword failed:', err)
      return
    }
    await fetchKeywords()
  }

  async function setKeywordProducts(id: string, productIds: string[]) {
    // Simple strategy: delete all + insert fresh. deal_keyword_products is
    // a PK-only junction, so no lost metadata.
    const { error: delErr } = await supabase
      .from('deal_keyword_products')
      .delete()
      .eq('keyword_id', id)
    if (delErr) {
      console.error('[useDeals] setKeywordProducts delete failed:', delErr)
      return
    }
    if (productIds.length > 0) {
      const { error: insErr } = await supabase
        .from('deal_keyword_products')
        .insert(productIds.map((pid) => ({ keyword_id: id, product_id: pid })))
      if (insErr) console.error('[useDeals] setKeywordProducts insert failed:', insErr)
    }
    await fetchKeywords()
  }

  async function deleteKeyword(id: string) {
    const { error: err } = await supabase
      .from('deal_keywords')
      .delete()
      .eq('id', id)
    if (err) {
      console.error('[useDeals] deleteKeyword failed:', err)
      return
    }
    await fetchKeywords()
  }

  return {
    deals,
    loading,
    error,
    fromCache,
    searchedProducts,
    lastFetchedAt,
    noProviders,
    dealsEnabled,
    setDealsEnabled,
    dealsZipCode,
    dealsRefreshHour,
    dealsConfig,
    hasCustomConfig,
    settingsLoading,
    settingsError,
    settingsSuccess,
    loadSettings,
    saveSettings,
    resetConfig,
    fetchDeals,
    dealsByRetailer,
    dealsByProduct,
    totalDeals,
    uniqueRetailers,
    avgDiscount,
    archivedCount,
    newDealKeys,
    newDealsCount,
    fetchNewDealKeys,
    isNew,
    markDealSeen,
    flushSeenDeals,
    dedupedDeals,
    activeDeals,
    archivedDeals,
    ekSummaries,
    fetchEkSummaries,
    dealEk,
    visibleActiveDeals,
    suppressedActiveDeals,
    fetchUserStates,
    archiveDeal,
    unarchiveDeal,
    pinDeal,
    unpinDeal,
    userStateError,
    keywords,
    fetchKeywords,
    createKeyword,
    updateKeyword,
    setKeywordProducts,
    deleteKeyword,
  }
}
