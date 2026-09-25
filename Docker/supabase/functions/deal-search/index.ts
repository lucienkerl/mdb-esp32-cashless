import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import type { NormalizedOffer } from '../_shared/providers/deal-source.ts'
import { resolveProviders, type ResolvedProvider } from './resolve-providers.ts'
import { toOfferDate } from './offer-date.ts'
import { sendPushToUsers } from '../_shared/web-push.ts'
import { t, type Locale } from '../_shared/notification-i18n.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// Marktguru is now a DealSourceProvider plugin — see
// Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts

// ─── Retailer prospekt URLs ─────────────────────────────────────────────────

// ─── Country-based keyword presets ──────────────────────────────────────────

interface DealConfig {
  generic_terms: string[]
  wildcard_phrases: string[]
  app_detection_patterns: string[]
  retailer_prospekt_urls: Record<string, string>
}

const COUNTRY_PRESETS: Record<string, DealConfig> = {
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
    retailer_prospekt_urls: {
      'lidl': 'https://www.lidl.de/c/online-prospekte/s10005610',
      'kaufland': 'https://www.kaufland.de/angebote/aktuelle-prospekte.html',
      'rewe': 'https://www.rewe.de/angebote/nationale-angebote/',
      'aldi-sued': 'https://www.aldi-sued.de/de/angebote.html',
      'aldi-nord': 'https://www.aldi-nord.de/angebote.html',
      'penny': 'https://www.penny.de/angebote',
      'netto-marken-discount': 'https://www.netto-online.de/angebote',
      'norma': 'https://www.norma-online.de/de/angebote/',
      'edeka': 'https://www.edeka.de/angebote.jsp',
      'rossmann': 'https://www.rossmann.de/de/angebote.html',
      'dm': 'https://www.dm.de/angebote',
      'real': 'https://www.real.de/angebote/',
      'müller': 'https://www.mueller.de/angebote/',
      'globus': 'https://www.globus.de/angebote/',
      'tegut': 'https://www.tegut.com/angebote/aktuelle-angebote.html',
      'hit': 'https://www.hit.de/angebote/',
      'famila': 'https://www.famila-nordost.de/angebote/',
      'metro': 'https://www.metro.de/angebote',
      'selgros': 'https://www.selgros.de/angebote',
    },
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
    retailer_prospekt_urls: {
      'billa': 'https://www.billa.at/angebote/aktuelle-angebote',
      'billa-plus': 'https://www.billa.at/angebote/aktuelle-angebote',
      'spar': 'https://www.spar.at/angebote',
      'eurospar': 'https://www.spar.at/angebote',
      'interspar': 'https://www.spar.at/angebote',
      'hofer': 'https://www.hofer.at/de/angebote.html',
      'lidl': 'https://www.lidl.at/angebote',
      'penny': 'https://www.penny.at/angebote',
    },
  },
}

/** Merge company overrides on top of country defaults */
function resolveConfig(countryCode: string, overrides: Partial<DealConfig> | null): DealConfig {
  const base = COUNTRY_PRESETS[countryCode] ?? COUNTRY_PRESETS['DE']
  if (!overrides) return base
  return {
    generic_terms: overrides.generic_terms ?? base.generic_terms,
    wildcard_phrases: overrides.wildcard_phrases ?? base.wildcard_phrases,
    app_detection_patterns: overrides.app_detection_patterns ?? base.app_detection_patterns,
    retailer_prospekt_urls: overrides.retailer_prospekt_urls
      ? { ...base.retailer_prospekt_urls, ...overrides.retailer_prospekt_urls }
      : base.retailer_prospekt_urls,
  }
}

/**
 * Detect app requirement from offer description text.
 */
function detectAppRequirement(description: string, patterns: string[]): boolean {
  const lower = description.toLowerCase()
  return patterns.some((p) => lower.includes(p))
}

// ─── Fuzzy matching ─────────────────────────────────────────────────────────

/** Normalize string for comparison: lowercase, remove special chars but keep
 *  commas and dots within numbers (e.g. "5,0" stays "5,0", not "50") */
function normalize(s: string): string {
  return s
    .toLowerCase()
    // Keep commas/dots that sit between digits (e.g. "5,0", "0.5")
    .replace(/([0-9])[,.]([0-9])/g, '$1\x00$2')  // temp placeholder
    .replace(/[^a-zäöüß0-9\s]/g, '')
    .replace(/\x00/g, ',')                         // restore as comma
    .replace(/\s+/g, ' ')
    .trim()
}

/** Extract brand/core name tokens from a product name */
function extractTokens(name: string): string[] {
  return normalize(name).split(' ').filter((t) => t.length > 1)
}

interface MatchResult {
  confidence: number
  matchedTokens: string[]
}

/**
 * Compute a match confidence between a local product name and a marktguru offer.
 *
 * Handles cases like "Red Bull verschiedene Sorten" matching
 * "Red Bull Energy Drink", "Red Bull Sugarfree", etc.
 *
 * Strategy:
 * 1. Check if the core brand/product tokens from our product appear in the offer
 * 2. Check if the offer brand matches our product name
 * 3. Penalize generic terms like "verschiedene Sorten"
 *
 * Returns both confidence score and list of matched tokens for validation UI.
 */
function matchConfidence(
  productName: string,
  offerDescription: string,
  offerBrand: string,
  config: DealConfig,
): MatchResult {
  const productNorm = normalize(productName)
  const offerNorm = normalize(offerDescription)
  const brandNorm = normalize(offerBrand)
  const matchedTokens: string[] = []

  // Exact match
  if (productNorm === offerNorm) {
    return { confidence: 1.0, matchedTokens: extractTokens(productName) }
  }

  const productTokens = extractTokens(productName)
  if (productTokens.length === 0) return { confidence: 0, matchedTokens: [] }

  const genericTerms = new Set(config.generic_terms)

  /** Check if a token appears in text — numeric tokens (e.g. "50", "5,0")
   *  must match as a whole word to avoid "50" matching inside "500ml". */
  function tokenInText(token: string, text: string): boolean {
    const isNumeric = /^[\d,]+$/.test(token)
    if (isNumeric) {
      // Escape the token for regex (commas are special in some contexts)
      const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
      // Must be surrounded by non-digit/comma chars or string boundaries
      const re = new RegExp(`(?<![0-9,])${escaped}(?![0-9,])`)
      return re.test(text)
    }
    return text.includes(token)
  }

  // Check how many product tokens appear in the offer description
  let tokenMatches = 0
  for (const token of productTokens) {
    if (genericTerms.has(token)) continue
    if (tokenInText(token, offerNorm) || tokenInText(token, brandNorm)) {
      tokenMatches++
      matchedTokens.push(token)
    }
  }

  const meaningfulTokens = productTokens.filter((t) => !genericTerms.has(t))
  // If all tokens are generic, fall back to using all tokens
  const scoringTokens = meaningfulTokens.length > 0 ? meaningfulTokens : productTokens

  const tokenScore = tokenMatches / scoringTokens.length

  // Bonus: brand name from offer matches first word(s) of product
  let brandBonus = 0
  if (brandNorm && productNorm.startsWith(brandNorm)) {
    brandBonus = 0.15
    if (!matchedTokens.includes(brandNorm)) matchedTokens.push(brandNorm)
  } else if (brandNorm && productNorm.includes(brandNorm)) {
    brandBonus = 0.1
    if (!matchedTokens.includes(brandNorm)) matchedTokens.push(brandNorm)
  }

  // Check reverse: do offer description tokens appear in product?
  const offerTokens = extractTokens(offerDescription).filter((t) => !genericTerms.has(t))
  let reverseMatches = 0
  for (const token of offerTokens) {
    if (tokenInText(token, productNorm)) {
      reverseMatches++
      if (!matchedTokens.includes(token)) matchedTokens.push(token)
    }
  }
  const reverseScore = offerTokens.length > 0 ? reverseMatches / offerTokens.length : 0

  // Wildcard boost: if the offer says "versch. Sorten" / "verschiedene Sorten"
  // etc., it means ALL variants of the brand are included. In that case, a
  // brand match alone is sufficient — boost the score significantly.
  let wildcardBonus = 0
  const hasWildcard = config.wildcard_phrases.some((p) => offerNorm.includes(p))
  if (hasWildcard && brandBonus > 0) {
    // Brand matches + offer is a wildcard → strong match
    wildcardBonus = 0.3
  }

  // Combined score (weighted)
  const combined = Math.min(1.0, tokenScore * 0.6 + reverseScore * 0.25 + brandBonus + wildcardBonus)

  return {
    confidence: Math.round(combined * 100) / 100,
    matchedTokens,
  }
}

// ─── Main handler ───────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    // Auth
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    // Body is parsed up-front: scheduled (cron) invocations carry
    // { company_id, scheduled } and authenticate with the service-role key
    // instead of a user JWT, so we need it before the auth decision.
    const body = await req.json().catch(() => ({}))
    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // Scheduled/service-role mode: dispatch_deal_refresh() (pg_cron) POSTs with
    // the service-role key + company_id. Must be handled BEFORE getUser(), which
    // would 401 on a non-JWT bearer. Mirrors trigger-ota / send-device-config.
    const isScheduled = token === serviceRoleKey && typeof body.company_id === 'string'

    let companyId: string
    if (isScheduled) {
      companyId = body.company_id as string
    } else {
      const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
      if (userError || !user) {
        return new Response(JSON.stringify({ error: 'Unauthorized' }), {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      // Get user's company
      const { data: membership } = await adminClient
        .from('organization_members')
        .select('company_id')
        .eq('user_id', user.id)
        .single()

      if (!membership) {
        return new Response(JSON.stringify({ error: 'No organization found' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      companyId = membership.company_id
    }

    // Check if deals feature is enabled + load config
    const { data: company } = await adminClient
      .from('companies')
      .select('deals_enabled, deals_zip_code, deals_config, country_code, timezone')
      .eq('id', companyId)
      .single()

    if (!company?.deals_enabled) {
      return new Response(JSON.stringify({ error: 'Deal search is not enabled for this company' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const zipCode = company.deals_zip_code || '60487'
    const countryCode = (company as any).country_code ?? 'DE'
    const dealConfig = resolveConfig(countryCode, (company as any).deals_config ?? null)
    // Validity boundaries are stored as calendar days in the company's zone
    // (see offer-date.ts for the off-by-one this prevents).
    const companyTz: string = (company as any).timezone || 'Europe/Berlin'

    // Scheduled runs always force a fresh fetch (that's the point of the cron).
    const forceRefresh = body.forceRefresh === true || isScheduled
    const minConfidence = typeof body.minConfidence === 'number' ? body.minConfidence : 0.5

    // Check cache age — if we have fresh data (< 12h), return cached
    if (!forceRefresh) {
      const twelveHoursAgo = new Date(Date.now() - 12 * 60 * 60 * 1000).toISOString()
      const { data: cached, count } = await adminClient
        .from('deal_cache')
        .select('*, products(name, image_path, sellprice)', { count: 'exact' })
        .eq('company_id', companyId)
        .gte('fetched_at', twelveHoursAgo)
        .gte('valid_until', new Date().toISOString().split('T')[0])
        .gte('confidence', minConfidence)
        .order('discount_pct', { ascending: false, nullsFirst: false })

      if (count && count > 0) {
        return new Response(JSON.stringify({ deals: cached, fromCache: true }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }
    }

    // Fetch products for this company (non-discontinued only)
    const { data: products } = await adminClient
      .from('products')
      .select('id, name, sellprice, image_path, category:product_category(name)')
      .eq('company', companyId)
      .or('discontinued.is.null,discontinued.eq.false')

    if (!products || products.length === 0) {
      return new Response(JSON.stringify({ deals: [], fromCache: false, message: 'No products found' }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Fetch keyword groups for this company
    interface DealKeyword {
      id: string
      label: string | null
      terms: string[]
      product_ids: string[]
    }

    const { data: keywordRows, error: keywordErr } = await adminClient
      .from('deal_keywords')
      .select('id, label, terms, deal_keyword_products(product_id)')
      .eq('company_id', companyId)

    if (keywordErr) {
      console.error('[deal-search] failed to load keywords:', keywordErr)
    }

    const keywords: DealKeyword[] = (keywordRows ?? []).map((row: any) => ({
      id: row.id,
      label: row.label,
      terms: row.terms ?? [],
      product_ids: (row.deal_keyword_products ?? []).map((kp: any) => kp.product_id),
    }))

    // Resolve enabled deal-source providers for this company.
    let resolved: ResolvedProvider[]
    try {
      resolved = await resolveProviders(adminClient, companyId)
    } catch (err) {
      console.error('[deal-search] failed to resolve providers:', err)
      return new Response(JSON.stringify({ error: 'Failed to load provider configuration' }), {
        status: 502,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
    if (resolved.length === 0) {
      return new Response(
        JSON.stringify({ deals: [], fromCache: false, message: 'No deal-source providers enabled' }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Search for each product and collect matches
    const allDeals: any[] = []
    const seen = new Set<string>() // dedup by offer_id + product_id

    // Per-offer set of products covered by a keyword-group hit. Populated inside
    // the queries loop (Step 2) and read by the suppression gate (Step 3).
    const keywordCovered = new Map<string, Set<string>>()

    // Queries Marktguru with: (1) user keyword terms — explicit brand/phrase
    // intent that often doesn't appear verbatim in any product name; (2) full
    // product names; (3) first-word brand queries — catches generic offers
    // like "Powerade versch. Sorten" for products named "Powerade Sports
    // Mountain Blast". Keyword-origin and product-origin queries get separate
    // caps below so keywords can't push products out of the budget (or vice
    // versa). matchProducts on keyword-only entries stays [] — the keyword-
    // matching and cross-product passes already iterate all keywords/products.
    const searchQueries = new Map<string, typeof products>()
    const keywordOriginQueries = new Set<string>()

    for (const keyword of keywords) {
      for (const term of keyword.terms) {
        const trimmed = term.trim()
        if (!trimmed) continue
        keywordOriginQueries.add(trimmed)
        if (!searchQueries.has(trimmed)) searchQueries.set(trimmed, [])
      }
    }

    for (const product of products) {
      if (!product.name) continue
      const fullName = product.name.trim()
      if (!fullName) continue

      // Full name query → best for exact matches
      const existing = searchQueries.get(fullName) ?? []
      existing.push(product)
      searchQueries.set(fullName, existing)

      // Short brand query (first 1–2 words) → catches generic offers
      const words = fullName.split(/\s+/)
      if (words.length >= 2) {
        // Use first word if long enough (>= 4 chars), else first two words
        const shortQuery = words[0].length >= 4 ? words[0] : words.slice(0, 2).join(' ')
        if (shortQuery !== fullName) {
          const shortExisting = searchQueries.get(shortQuery) ?? []
          // Only add if not already there
          if (!shortExisting.some((p: any) => p.id === product.id)) {
            shortExisting.push(product)
          }
          searchQueries.set(shortQuery, shortExisting)
        }
      }
    }

    // Split caps so keyword-origin queries never crowd out product-origin
    // queries (or vice versa). A query that originated from BOTH a keyword
    // term AND a product name (e.g. user keyword "Haribo" + product "Haribo
    // Goldbären" → short query "Haribo") counts as keyword-origin: explicit
    // user intent wins.
    const KEYWORD_QUERY_CAP = 100
    const PRODUCT_QUERY_CAP = 300
    const allEntries = Array.from(searchQueries.entries())
    const keywordEntries = allEntries
      .filter(([q]) => keywordOriginQueries.has(q))
      .slice(0, KEYWORD_QUERY_CAP)
    const productEntries = allEntries
      .filter(([q]) => !keywordOriginQueries.has(q))
      .slice(0, PRODUCT_QUERY_CAP)
    const queries = [...keywordEntries, ...productEntries]
    console.log(
      `[deal-search] queries: ${keywordEntries.length} keyword-origin + `
      + `${productEntries.length} product-only (caps ${KEYWORD_QUERY_CAP}/${PRODUCT_QUERY_CAP})`,
    )

    // Phase A: parallel provider fetches in bounded batches. For each query we
    // invoke every enabled provider in parallel, then merge their NormalizedOffer
    // results, deduping by (retailerSlug, externalId). Phase B (matching) stays
    // sequential because it mutates shared allDeals / seen / keywordCovered —
    // the keyword pass marks products as covered for an offer, which the later
    // product pass reads to dedupe.
    //
    // Concurrency 10 keeps query-fan-out below plausible upstream abuse
    // thresholds (Marktguru, kaufDA, etc. all rate-limit aggressive callers)
    // while cutting wall-clock by ~10× on large catalogs.
    const FETCH_CONCURRENCY = 10
    type FetchResult = { query: string; matchProducts: typeof products; offers: NormalizedOffer[] }
    const fetchResults: FetchResult[] = []
    for (let i = 0; i < queries.length; i += FETCH_CONCURRENCY) {
      const batch = queries.slice(i, i + FETCH_CONCURRENCY)
      const batchResults = await Promise.all(
        batch.map(async ([query, matchProducts]): Promise<FetchResult> => {
          const perProvider = await Promise.allSettled(
            resolved.map((r) =>
              r.provider.fetchOffers(query, {
                companyId,
                zipCode,
                config: r.row.config,
              }),
            ),
          )
          const seenOffer = new Set<string>()
          const offers: NormalizedOffer[] = []
          // Index-based loop: Promise.allSettled returns positional results that
          // need to be aligned with resolved[j].provider.id for the error log.
          for (let j = 0; j < perProvider.length; j++) {
            const res = perProvider[j]
            if (res.status === 'rejected') {
              console.error(
                `[deal-search] provider ${resolved[j].provider.id} failed for "${query}":`,
                res.reason,
              )
              continue
            }
            for (const offer of res.value) {
              const k = `${offer.retailerSlug}::${offer.externalId}`
              if (seenOffer.has(k)) continue
              seenOffer.add(k)
              offers.push(offer)
            }
          }
          return { query, matchProducts, offers }
        }),
      )
      fetchResults.push(...batchResults)
    }
    console.log(
      `[deal-search] fetched offers for ${fetchResults.length} queries `
      + `(concurrency ${FETCH_CONCURRENCY})`,
    )

    // Phase B: sequential matching over pre-fetched offers.
    for (const { query, matchProducts, offers } of fetchResults) {
      try {
        // Helper: build a keyword-match deal row for upsert.
        function buildKeywordDeal(
          offer: NormalizedOffer,
          keyword: DealKeyword,
          winning: { term: string; match: MatchResult },
        ) {
          const discountPct = offer.oldPrice && offer.price
            ? Math.round((1 - offer.price / offer.oldPrice) * 100)
            : null
          // Consumer-side overlay: dealConfig.retailer_prospekt_urls is the
          // canonical source-of-truth for prospekt URLs; fall back to whatever
          // the provider produced (Marktguru's marktguru.de/rp/{slug} URL).
          const prospektUrl = dealConfig.retailer_prospekt_urls[offer.retailerSlug]
            ?? offer.sourceUrl
            ?? `https://www.marktguru.de/rp/${offer.retailerSlug}-prospekte`

          return {
            company_id: companyId,
            product_id: null,
            keyword_id: keyword.id,
            matched_term: winning.term,
            retailer: offer.retailer,
            deal_title: offer.description,
            deal_price: offer.price,
            regular_price: offer.oldPrice,
            discount_pct: discountPct,
            valid_from: toOfferDate(offer.validFrom, companyTz),
            valid_until: toOfferDate(offer.validUntil, companyTz),
            image_url: offer.imageUrl,
            image_url_large: offer.imageUrlLarge,
            source_url: prospektUrl,
            external_url: offer.externalUrl,
            matched_by: 'keyword_fuzzy',
            confidence: winning.match.confidence,
            matched_tokens: winning.match.matchedTokens,
            requires_app: (offer.requiresApp ?? false)
              || detectAppRequirement(offer.description, dealConfig.app_detection_patterns),
            fetched_at: new Date().toISOString(),
            offer_id: offer.externalId,
          }
        }

        // Keyword matching pass — one row per (offer, keyword_group).
        for (const offer of offers) {
          for (const keyword of keywords) {
            let best: { term: string; match: MatchResult } | null = null
            for (const term of keyword.terms) {
              const m = matchConfidence(
                term,
                offer.description,
                offer.brand,
                dealConfig,
              )
              if (m.confidence >= minConfidence && (!best || m.confidence > best.match.confidence)) {
                best = { term, match: m }
              }
            }
            if (!best) continue

            // Prefix the dedup key with `kw-` so it cannot collide with the existing
            // product-pass dedup keys (`${offer.externalId}-${product.id}`).
            const dedup = `kw-${offer.externalId}-${keyword.id}`
            if (seen.has(dedup)) continue
            seen.add(dedup)

            allDeals.push(buildKeywordDeal(offer, keyword, best))

            // Mark the keyword's products as covered for this offer. Union with any
            // existing set so repeated offer IDs across query batches accumulate.
            const covered = keywordCovered.get(offer.externalId) ?? new Set<string>()
            for (const pid of keyword.product_ids) covered.add(pid)
            keywordCovered.set(offer.externalId, covered)
          }
        }

        // Helper to build a deal record from an offer + product match
        function buildDeal(offer: NormalizedOffer, product: any, match: MatchResult) {
          const discountPct = offer.oldPrice && offer.price
            ? Math.round((1 - offer.price / offer.oldPrice) * 100)
            : null
          // Consumer-side overlay (see buildKeywordDeal for the rationale).
          const prospektUrl = dealConfig.retailer_prospekt_urls[offer.retailerSlug]
            ?? offer.sourceUrl
            ?? `https://www.marktguru.de/rp/${offer.retailerSlug}-prospekte`

          return {
            company_id: companyId,
            product_id: product.id,
            retailer: offer.retailer,
            deal_title: offer.description,
            deal_price: offer.price,
            regular_price: offer.oldPrice,
            discount_pct: discountPct,
            valid_from: toOfferDate(offer.validFrom, companyTz),
            valid_until: toOfferDate(offer.validUntil, companyTz),
            image_url: offer.imageUrl,
            image_url_large: offer.imageUrlLarge,
            source_url: prospektUrl,
            external_url: offer.externalUrl,
            matched_by: 'name_fuzzy',
            confidence: match.confidence,
            matched_tokens: match.matchedTokens,
            requires_app: (offer.requiresApp ?? false)
              || detectAppRequirement(offer.description, dealConfig.app_detection_patterns),
            fetched_at: new Date().toISOString(),
            offer_id: offer.externalId,
          }
        }

        for (const offer of offers) {
          for (const product of matchProducts) {
            const match = matchConfidence(
              product.name,
              offer.description,
              offer.brand,
              dealConfig,
            )

            if (match.confidence < minConfidence) continue

            const dedup = `${offer.externalId}-${product.id}`
            if (seen.has(dedup)) continue
            seen.add(dedup)

            const coveredByKeyword = keywordCovered.get(offer.externalId)
            if (coveredByKeyword?.has(product.id)) continue

            allDeals.push(buildDeal(offer, product, match))
          }
        }

        // Also try to match each offer against ALL products (cross-match)
        // This catches "Red Bull versch. Sorten" matching all Red Bull variants
        for (const offer of offers) {
          for (const product of products) {
            const dedup = `${offer.externalId}-${product.id}`
            if (seen.has(dedup)) continue

            const match = matchConfidence(
              product.name,
              offer.description,
              offer.brand,
              dealConfig,
            )

            if (match.confidence < minConfidence) continue
            seen.add(dedup)

            const coveredByKeyword = keywordCovered.get(offer.externalId)
            if (coveredByKeyword?.has(product.id)) continue

            allDeals.push(buildDeal(offer, product, match))
          }
        }
      } catch (err) {
        console.error(`Matching failed for "${query}":`, err)
      }
    }

    // Clear old cache for this company and write new results
    await adminClient
      .from('deal_cache')
      .delete()
      .eq('company_id', companyId)

    const productDealRows = allDeals.filter((d) => d.product_id !== null && d.product_id !== undefined)
    const keywordDealRows = allDeals.filter((d) => d.keyword_id !== null && d.keyword_id !== undefined)

    // Plain INSERT (not upsert): the cache was DELETEd for this company at
    // the top of the refresh, so nothing exists to conflict with. In-batch
    // duplicates are already prevented by the `seen` set. Partial unique
    // indexes (uq_deal_cache_product / uq_deal_cache_keyword) aren't usable
    // as PostgREST onConflict targets because they require the WHERE
    // predicate, which the supabase-js client can't pass through.
    if (productDealRows.length > 0) {
      const { error: piErr } = await adminClient.from('deal_cache').insert(productDealRows)
      if (piErr) console.error('[deal-search] product insert failed:', piErr)
    }

    if (keywordDealRows.length > 0) {
      const { error: kiErr } = await adminClient.from('deal_cache').insert(keywordDealRows)
      if (kiErr) console.error('[deal-search] keyword insert failed:', kiErr)
    }

    console.log(`[deal-search] wrote ${productDealRows.length} product + ${keywordDealRows.length} keyword deals`)

    // ── Persist first-seen + detect genuinely-new offers ──────────────────
    // deal_cache is wiped + rewritten every run, so "new" can't come from it;
    // deal_offer_first_seen survives. Dedup across product + keyword rows: the
    // same (retailer, offer_id) can appear in both, so stamp the union ONCE.
    const firstSeenRows = Array.from(
      new Map(
        allDeals
          .filter((d) => d.offer_id)
          .map((d) => [
            `${d.retailer}::${d.offer_id}`,
            { company_id: companyId, retailer: d.retailer, offer_id: d.offer_id as string },
          ]),
      ).values(),
    )

    let newOfferCount = 0
    let newRetailers: string[] = []
    if (firstSeenRows.length > 0) {
      // ignoreDuplicates = ON CONFLICT DO NOTHING; .select() then returns ONLY
      // the rows actually inserted = offers seen for the very first time.
      const { data: inserted, error: fsErr } = await adminClient
        .from('deal_offer_first_seen')
        .upsert(firstSeenRows, {
          onConflict: 'company_id,retailer,offer_id',
          ignoreDuplicates: true,
        })
        .select('retailer, offer_id')
      if (fsErr) {
        console.error('[deal-search] first-seen stamp failed:', fsErr)
      } else {
        newOfferCount = inserted?.length ?? 0
        newRetailers = [...new Set((inserted ?? []).map((r: any) => r.retailer))]
        // Exclude implausible offers (deal price above the highest recorded EK
        // for ALL matched products) from the new-deal count + push, so junk/
        // mismatched matches never nudge users. No EK data → empty set → no-op.
        try {
          const { data: suppressed } = await adminClient
            .rpc('get_suppressed_offer_keys', { p_company_id: companyId })
          const suppressedSet = new Set(
            (suppressed ?? []).map((s: any) => `${s.retailer}::${s.offer_id}`),
          )
          if (suppressedSet.size > 0) {
            const survivors = (inserted ?? []).filter(
              (r: any) => !suppressedSet.has(`${r.retailer}::${r.offer_id}`),
            )
            newOfferCount = survivors.length
            newRetailers = [...new Set(survivors.map((r: any) => r.retailer))]
          }
        } catch (suppErr) {
          console.error('[deal-search] suppression filter failed (counting all):', suppErr)
        }
      }
    }
    console.log(`[deal-search] ${newOfferCount} newly-first-seen offers this run`)

    // ── Notify on genuinely-new offers (scheduled cron runs only) ─────────
    // Manual frontend refreshes never push. Opt-in per user via the
    // 'new_deals' notification preference (default-on, like the others).
    if (isScheduled && newOfferCount > 0) {
      try {
        const topRetailers = newRetailers.slice(0, 3).join(', ')
        await sendPushToUsers(adminClient, companyId, 'new_deals', (locale: Locale) => {
          const strings = t(locale)
          return {
            title: `🏷️ ${strings.newDealsTitle}`,
            body: strings.newDealsBody(newOfferCount, topRetailers),
            data: { type: 'new_deals', url: '/deals' },
          }
        })
      } catch (pushErr) {
        console.error('[deal-search] new-deals push failed:', pushErr)
      }
    }

    // Read back with product joins for the response
    const { data: result } = await adminClient
      .from('deal_cache')
      .select(`
        *,
        products(id, name, image_path, sellprice),
        deal_keywords(
          id,
          label,
          terms,
          deal_keyword_products(products(id, name, image_path, sellprice))
        )
      `)
      .eq('company_id', companyId)
      .gte('confidence', minConfidence)
      .order('discount_pct', { ascending: false, nullsFirst: false })

    return new Response(JSON.stringify({
      deals: result ?? [],
      fromCache: false,
      searchedProducts: queries.length,
      totalDeals: allDeals.length,
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    console.error('deal-search error:', err)
    return new Response(JSON.stringify({ error: err?.message ?? 'Internal error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
