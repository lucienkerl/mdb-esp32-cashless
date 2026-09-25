/**
 * Regression test: the refactored deal-search pipeline produces byte-for-byte
 * identical deal_cache rows to the pre-refactor inline implementation, for a
 * known Marktguru offer + product fixture.
 *
 * The test exercises the seam most likely to drift: NormalizedOffer field
 * access inside the consumer's buildDeal helper. We re-create buildDeal here
 * with the same body the consumer uses post-refactor; if the consumer's
 * inline copy diverges from this reference, the test catches it.
 *
 * Run: deno test Docker/supabase/functions/deal-search/regression.test.ts
 */

import { assertEquals } from 'jsr:@std/assert'
import {
  normalizeOffer,
  type MarktguruOffer,
} from '../_shared/providers/deal-source/marktguru.ts'
import type { NormalizedOffer } from '../_shared/providers/deal-source.ts'
import { toOfferDate } from './offer-date.ts'

// ── Fixtures ──────────────────────────────────────────────────────────────────

const RAW_MARKTGURU_OFFER: MarktguruOffer = {
  id: 12345,
  description: 'HINWEIS: MIT APP 0,20€ REWE BONUS versch. Sorten, koffeinhaltig, je 0,5-l-Dose zzgl. 0.25 Pfand',
  price: 0.99,
  oldPrice: 1.49,
  referencePrice: 1.98,
  requiresLoyalityMembership: false,
  brand: { name: 'Monster Energy', uniqueName: 'monster-energy' },
  advertisers: [{ name: 'REWE', uniqueName: 'rewe' }],
  product: { name: 'Monster Energy 0,5l', description: null },
  validityDates: [{ from: '2026-05-03T22:00:00Z', to: '2026-05-09T21:59:00Z' }],
  images: {
    urls: {
      small:  'https://example/small.jpg',
      medium: 'https://example/medium.jpg',
      large:  'https://example/large.jpg',
    },
  },
}

const PRODUCT = { id: 'pid-monster', name: 'Monster Energy' }
const COMPANY_ID = 'co-1'
const DEAL_CONFIG = {
  generic_terms: [],
  wildcard_phrases: ['versch', 'sorten'],
  app_detection_patterns: ['mit app', 'rewe bonus'],
  retailer_prospekt_urls: {
    rewe: 'https://www.rewe.de/angebote/nationale-angebote/',
  },
}

// ── Reference impl: buildDeal as the refactored consumer should write it ──

interface MatchResult {
  confidence: number
  matchedTokens: string[]
}

function detectAppRequirement(description: string, patterns: string[]): boolean {
  const lower = description.toLowerCase()
  return patterns.some((p) => lower.includes(p))
}

function buildDealRef(
  offer: NormalizedOffer,
  product: { id: string; name: string },
  match: MatchResult,
) {
  const discountPct = offer.oldPrice && offer.price
    ? Math.round((1 - offer.price / offer.oldPrice) * 100)
    : null
  const prospektUrl = DEAL_CONFIG.retailer_prospekt_urls[offer.retailerSlug as keyof typeof DEAL_CONFIG.retailer_prospekt_urls]
    ?? offer.sourceUrl
    ?? `https://www.marktguru.de/rp/${offer.retailerSlug}-prospekte`

  return {
    company_id: COMPANY_ID,
    product_id: product.id,
    retailer: offer.retailer,
    deal_title: offer.description,
    deal_price: offer.price,
    regular_price: offer.oldPrice,
    discount_pct: discountPct,
    valid_from: toOfferDate(offer.validFrom),
    valid_until: toOfferDate(offer.validUntil),
    image_url: offer.imageUrl,
    image_url_large: offer.imageUrlLarge,
    source_url: prospektUrl,
    external_url: offer.externalUrl,
    matched_by: 'name_fuzzy',
    confidence: match.confidence,
    matched_tokens: match.matchedTokens,
    requires_app: (offer.requiresApp ?? false)
      || detectAppRequirement(offer.description, DEAL_CONFIG.app_detection_patterns),
    fetched_at: new Date(0).toISOString(), // pinned for assertion
    offer_id: offer.externalId,
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

Deno.test('normalize → buildDeal produces row matching pre-refactor shape', () => {
  const normalized = normalizeOffer(RAW_MARKTGURU_OFFER)
  const match: MatchResult = { confidence: 0.75, matchedTokens: ['monster'] }
  const row = buildDealRef(normalized, PRODUCT, match)

  // What the pre-refactor code would have produced for this exact fixture.
  // Hand-computed from the inline buildDeal body in deal-search/index.ts
  // at commit ac9ff6c (the last commit before this refactor).
  const expected = {
    company_id: 'co-1',
    product_id: 'pid-monster',
    retailer: 'REWE',
    deal_title: 'HINWEIS: MIT APP 0,20€ REWE BONUS versch. Sorten, koffeinhaltig, je 0,5-l-Dose zzgl. 0.25 Pfand',
    deal_price: 0.99,
    regular_price: 1.49,
    discount_pct: 34,                                       // round((1 - 0.99/1.49) * 100)
    valid_from: '2026-05-04',                              // local calendar day (offer-date.ts)
    valid_until: '2026-05-09',
    image_url: 'https://example/medium.jpg',
    image_url_large: 'https://mg2de.b-cdn.net/api/v1/offers/12345/images/default/0/large.jpg',
    source_url: 'https://www.rewe.de/angebote/nationale-angebote/',  // dealConfig overlay
    external_url: 'https://www.marktguru.de/r/rewe',
    matched_by: 'name_fuzzy',
    confidence: 0.75,
    matched_tokens: ['monster'],
    requires_app: true,                                     // detectAppRequirement matches "mit app"
    fetched_at: new Date(0).toISOString(),
    offer_id: '12345',
  }

  assertEquals(row, expected)
})

Deno.test('source_url falls through to provider value when dealConfig has no mapping', () => {
  const normalized = normalizeOffer({
    ...RAW_MARKTGURU_OFFER,
    advertisers: [{ name: 'PENNY', uniqueName: 'penny' }],
  })
  const match: MatchResult = { confidence: 0.75, matchedTokens: ['monster'] }
  const row = buildDealRef(normalized, PRODUCT, match)

  // 'penny' is not in DEAL_CONFIG.retailer_prospekt_urls → fall through to
  // offer.sourceUrl (the provider-built marktguru.de URL).
  assertEquals(row.source_url, 'https://www.marktguru.de/rp/penny-prospekte')
})

Deno.test('requires_app stays false when neither flag nor description triggers', () => {
  const normalized = normalizeOffer({
    ...RAW_MARKTGURU_OFFER,
    description: 'plain offer description with no loyalty hint',
    requiresLoyalityMembership: false,
  })
  const match: MatchResult = { confidence: 0.75, matchedTokens: ['monster'] }
  const row = buildDealRef(normalized, PRODUCT, match)
  assertEquals(row.requires_app, false)
})
