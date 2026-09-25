package xyz.vmflow.data

import kotlinx.datetime.LocalDate
import kotlinx.datetime.daysUntil
import xyz.vmflow.models.Deal
import xyz.vmflow.models.DealKeywordMatch
import xyz.vmflow.models.ProductPurchaseSummary
import kotlin.math.abs

// ─── Validity ────────────────────────────────────────────────────────────────

enum class DealValidityStatus { UPCOMING, ACTIVE, EXPIRING, EXPIRED }

/**
 * Whether an offer can be bought *today*. `valid_from`/`valid_until` are DATE
 * columns holding calendar days in the company's timezone, so they're compared
 * as plain [LocalDate]s against the device's local "today". Mirrors the web's
 * `app/lib/dealValidity.ts` and iOS `Deal.validityStatus` — keep all three in
 * sync.
 */
data class DealValidity(
    val status: DealValidityStatus,
    val from: LocalDate?,
    val until: LocalDate?,
    /** Whole days until the offer starts (≥ 1), only for [DealValidityStatus.UPCOMING]. */
    val startsInDays: Int?,
    /** Whole days until the last valid day (0 = today is the last day). */
    val daysLeft: Int?,
) {
    val isValidToday: Boolean
        get() = status == DealValidityStatus.ACTIVE || status == DealValidityStatus.EXPIRING

    /** Sort rank: valid today first, then upcoming, then expired. */
    val rank: Int
        get() = when (status) {
            DealValidityStatus.ACTIVE, DealValidityStatus.EXPIRING -> 0
            DealValidityStatus.UPCOMING -> 1
            DealValidityStatus.EXPIRED -> 2
        }
}

object DealValidityLogic {
    /** Deals whose last day is within this many days count as expiring. */
    const val EXPIRING_WITHIN_DAYS = 2

    /** Parses `YYYY-MM-DD` (tolerating a timestamp suffix); null for empty/garbage input. */
    fun parseDay(value: String?): LocalDate? {
        if (value.isNullOrBlank() || value.length < 10) return null
        return try {
            LocalDate.parse(value.substring(0, 10))
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    /**
     * The upcoming check deliberately doesn't require an end date — a deal
     * without `valid_until` must not read as valid when it only starts next week.
     */
    fun validity(validFrom: String?, validUntil: String?, today: LocalDate): DealValidity {
        val from = parseDay(validFrom)
        val until = parseDay(validUntil)
        val daysLeft = until?.let { today.daysUntil(it) }

        if (daysLeft != null && daysLeft < 0) {
            return DealValidity(DealValidityStatus.EXPIRED, from, until, null, daysLeft)
        }
        if (from != null && from > today) {
            return DealValidity(DealValidityStatus.UPCOMING, from, until, today.daysUntil(from), daysLeft)
        }
        if (daysLeft != null && daysLeft <= EXPIRING_WITHIN_DAYS) {
            return DealValidity(DealValidityStatus.EXPIRING, from, until, null, daysLeft)
        }
        return DealValidity(DealValidityStatus.ACTIVE, from, until, null, daysLeft)
    }

    fun validity(deal: Deal, today: LocalDate): DealValidity = validity(deal.validFrom, deal.validUntil, today)
}

// ─── Purchase-price (EK) comparison ──────────────────────────────────────────

enum class DealVerdict { NO_EK, IMPLAUSIBLE, GOOD_BEST, GOOD, SIMILAR, WORSE }

data class DealComparison(
    val verdict: DealVerdict,
    /** vs newest (usual) gross EK; negative = cheaper. */
    val deltaPct: Double?,
)

data class MarginDelta(val currentPct: Double, val dealPct: Double)

/**
 * Pure purchase-price comparison. 1:1 port of the web's `purchaseComparison.ts`
 * and iOS `PurchaseComparison` — keep all three in sync.
 */
object PurchaseComparison {
    fun classifyDeal(dealGross: Double?, summary: ProductPurchaseSummary?, tolerancePct: Double = 3.0): DealComparison {
        if (dealGross == null || summary == null || summary.ekCount <= 0) return DealComparison(DealVerdict.NO_EK, null)
        val maxG = summary.maxGross ?: return DealComparison(DealVerdict.NO_EK, null)
        val newest = summary.newestGross ?: return DealComparison(DealVerdict.NO_EK, null)
        val deltaPct = ((dealGross - newest) / newest) * 100
        if (dealGross > maxG) return DealComparison(DealVerdict.IMPLAUSIBLE, deltaPct)
        val minG = summary.minGross
        if (minG != null && dealGross <= minG) return DealComparison(DealVerdict.GOOD_BEST, deltaPct)
        if (dealGross < newest && abs(deltaPct) > tolerancePct) return DealComparison(DealVerdict.GOOD, deltaPct)
        if (abs(deltaPct) <= tolerancePct) return DealComparison(DealVerdict.SIMILAR, deltaPct)
        return DealComparison(DealVerdict.WORSE, deltaPct)
    }

    /** Margin if the deal replaced the usual EK. Null if not computable. */
    fun marginDelta(sellpriceGross: Double?, dealGross: Double, summary: ProductPurchaseSummary): MarginDelta? {
        val s = sellpriceGross ?: return null
        val rate = summary.effectiveTaxRate ?: return null
        val newestNet = summary.newestNet ?: return null
        val vkNet = s / (1 + rate)
        if (vkNet <= 0) return null
        val dealNet = dealGross / (1 + rate)
        return MarginDelta(((vkNet - newestNet) / vkNet) * 100, ((vkNet - dealNet) / vkNet) * 100)
    }

    /** A deal card is suppressed iff it has matched products and ALL are implausible. */
    fun isCardSuppressed(verdicts: List<DealVerdict>): Boolean =
        verdicts.isNotEmpty() && verdicts.all { it == DealVerdict.IMPLAUSIBLE }
}

/** Per-deal EK result for the card pill, suppression and the "usual EK" line. */
data class DealEk(
    val suppressed: Boolean,
    val bestVerdict: DealVerdict?,
    val bestDeltaPct: Double?,
    val usualEkGross: Double?,
)

// ─── Deduplicated deals + grouping ───────────────────────────────────────────

data class DealUserState(val archivedAt: String?, val pinnedAt: String?) {
    val archived: Boolean get() = archivedAt != null
    val pinned: Boolean get() = pinnedAt != null
}

/**
 * One card per (retailer, offer_id): brand-wide offers that fuzzy-matched many
 * catalog products collapse into a single entry. Mirrors iOS `DedupedDeal`.
 */
data class DedupedDeal(
    /** `retailer::offer_id` — matches the server-side `deal_user_state` key. */
    val key: String,
    val retailer: String,
    val offerId: String,
    val primary: Deal,
    val matchedProducts: List<MatchedProduct>,
    val matchedKeywords: List<DealKeywordMatch>,
    val archived: Boolean,
    val pinned: Boolean,
    val pinnedAt: String?,
) {
    data class MatchedProduct(
        val id: String,
        val name: String,
        val imagePath: String?,
        val sellprice: Double?,
        val confidence: Double,
    )
}

enum class DealGroupMode { VALIDITY, RETAILER, PRODUCT }

enum class DealListMode { ACTIVE, ARCHIVED }

/** A list section. [label] is set for retailer/product groups; the UI localizes the other kinds. */
data class DealGroup(
    val id: String,
    val kind: Kind,
    val label: String? = null,
    /** Start day, for [Kind.UPCOMING]. */
    val from: LocalDate? = null,
    val startsInDays: Int? = null,
    val deals: List<DedupedDeal>,
) {
    enum class Kind { PINNED, VALID_NOW, UPCOMING, EXPIRED, PLAIN }
}

object DealsLogic {
    fun stateKey(retailer: String, offerId: String): String = "$retailer::$offerId"

    private val verdictRank = mapOf(
        DealVerdict.GOOD_BEST to 5, DealVerdict.GOOD to 4, DealVerdict.SIMILAR to 3,
        DealVerdict.WORSE to 2, DealVerdict.NO_EK to 1, DealVerdict.IMPLAUSIBLE to 0,
    )

    /**
     * Collapses raw rows into one entry per (retailer, offer_id), dropping
     * expired rows. The highest-confidence row becomes the primary; matched
     * products keep their best confidence. Sorted by key so the order is
     * deterministic across recomputes.
     */
    fun dedupe(deals: List<Deal>, userStates: Map<String, DealUserState>, today: LocalDate): List<DedupedDeal> {
        val groups = LinkedHashMap<String, MutableList<Deal>>()
        for (d in deals) {
            val offerId = d.offerId ?: continue
            val until = DealValidityLogic.parseDay(d.validUntil)
            if (until != null && until < today) continue
            groups.getOrPut(stateKey(d.retailer, offerId)) { mutableListOf() }.add(d)
        }

        return groups.map { (key, rows) ->
            val sorted = rows.sortedByDescending { it.confidence }
            val primary = sorted.first()
            val productMap = LinkedHashMap<String, DedupedDeal.MatchedProduct>()
            val keywordMap = LinkedHashMap<String, DealKeywordMatch>()
            for (r in sorted) {
                val p = r.products
                val pid = r.productId
                val name = p?.name
                if (p != null && pid != null && name != null) {
                    val existing = productMap[pid]
                    if (existing == null || existing.confidence < r.confidence) {
                        productMap[pid] = DedupedDeal.MatchedProduct(pid, name, p.imagePath, p.sellprice, r.confidence)
                    }
                }
                val kw = r.dealKeywords
                val kid = kw?.id
                if (kw != null && kid != null && kid !in keywordMap) keywordMap[kid] = kw
            }
            val state = userStates[key]
            DedupedDeal(
                key = key,
                retailer = primary.retailer,
                offerId = primary.offerId!!,
                primary = primary,
                matchedProducts = productMap.values.sortedByDescending { it.confidence },
                matchedKeywords = keywordMap.values.toList(),
                archived = state?.archived ?: false,
                pinned = state?.pinned ?: false,
                pinnedAt = state?.pinnedAt,
            )
        }.sortedBy { it.key }
    }

    /** Non-archived: pinned first (most recent pin first), then discount desc, key asc as tiebreak. */
    fun activeDeals(deduped: List<DedupedDeal>): List<DedupedDeal> =
        deduped.filter { !it.archived }.sortedWith(
            compareByDescending<DedupedDeal> { it.pinned }
                .thenByDescending { if (it.pinned) it.pinnedAt ?: "" else "" }
                .thenByDescending { if (it.pinned) Double.NEGATIVE_INFINITY else it.primary.discountPct ?: -1.0 }
                .thenBy { it.key },
        )

    fun archivedDeals(deduped: List<DedupedDeal>): List<DedupedDeal> =
        deduped.filter { it.archived }.sortedWith(
            compareByDescending<DedupedDeal> { it.primary.discountPct ?: -1.0 }.thenBy { it.key },
        )

    /** All catalog product ids an offer references (name matches + keyword-group products). */
    fun dealProductIds(deal: DedupedDeal): List<String> {
        val ids = LinkedHashSet<String>()
        deal.matchedProducts.forEach { ids.add(it.id) }
        deal.matchedKeywords.forEach { kw -> kw.linkedProducts.forEach { p -> p.id?.let(ids::add) } }
        return ids.toList()
    }

    /** Product ids to fetch EK summaries for, from the raw rows. */
    fun rawProductIds(deals: List<Deal>): List<String> {
        val ids = LinkedHashSet<String>()
        for (d in deals) {
            d.productId?.let(ids::add)
            d.dealKeywords?.linkedProducts?.forEach { p -> p.id?.let(ids::add) }
        }
        return ids.toList()
    }

    /**
     * EK verdict for a card. [DealEk.usualEkGross] is the usual EK of the
     * *cheapest* matched product with EK data, independent of verdict ranking.
     */
    fun dealEk(deal: DedupedDeal, summaries: Map<String, ProductPurchaseSummary>): DealEk {
        val dealGross = deal.primary.dealPrice
        val productSummaries = dealProductIds(deal).map { summaries[it] }
        val comparisons = productSummaries.map { PurchaseComparison.classifyDeal(dealGross, it) }
        val suppressed = PurchaseComparison.isCardSuppressed(comparisons.map { it.verdict })
        val best = comparisons
            .filter { it.verdict != DealVerdict.NO_EK }
            .maxByOrNull { verdictRank[it.verdict] ?: 0 }
        val usual = productSummaries
            .mapNotNull { s -> if (s != null && s.ekCount > 0) s.newestGross else null }
            .minOrNull()
        return DealEk(suppressed, best?.verdict, best?.deltaPct, usual)
    }

    fun matchesSearch(deal: DedupedDeal, query: String): Boolean {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return true
        return deal.primary.dealTitle.lowercase().contains(q) ||
            deal.retailer.lowercase().contains(q) ||
            deal.matchedProducts.any { it.name.lowercase().contains(q) } ||
            deal.matchedKeywords.any { (it.label ?: "").lowercase().contains(q) }
    }

    /** Stable sort: valid today first (keeping incoming order), upcoming by start day, then expired. */
    fun sortByValidity(list: List<DedupedDeal>, today: LocalDate): List<DedupedDeal> =
        list.withIndex().sortedWith(
            compareBy<IndexedValue<DedupedDeal>> { DealValidityLogic.validity(it.value.primary, today).rank }
                .thenBy {
                    val v = DealValidityLogic.validity(it.value.primary, today)
                    if (v.status == DealValidityStatus.UPCOMING) v.from else null
                }
                .thenBy { it.index },
        ).map { it.value }

    /**
     * Sections for the list: pinned first (active list only), then either
     * "valid now" + one section per upcoming start day + expired, or
     * retailer/product groups (alphabetical, each sorted by validity).
     */
    fun group(source: List<DedupedDeal>, mode: DealGroupMode, listMode: DealListMode, today: LocalDate): List<DealGroup> {
        val isActive = listMode == DealListMode.ACTIVE
        val result = mutableListOf<DealGroup>()
        val pinned = sortByValidity(if (isActive) source.filter { it.pinned } else emptyList(), today)
        val rest = sortByValidity(if (isActive) source.filter { !it.pinned } else source, today)

        if (pinned.isNotEmpty()) result += DealGroup(id = "__pinned__", kind = DealGroup.Kind.PINNED, deals = pinned)

        when (mode) {
            DealGroupMode.VALIDITY -> result += validityGroups(rest, today)
            DealGroupMode.RETAILER, DealGroupMode.PRODUCT -> {
                val grouped = rest.groupBy { deal ->
                    if (mode == DealGroupMode.RETAILER) {
                        deal.retailer
                    } else {
                        deal.matchedProducts.firstOrNull()?.name ?: deal.matchedKeywords.firstOrNull()?.label ?: "—"
                    }
                }
                grouped.toSortedMap().forEach { (key, deals) ->
                    result += DealGroup(id = "plain:$key", kind = DealGroup.Kind.PLAIN, label = key, deals = deals)
                }
            }
        }
        return result
    }

    private fun validityGroups(sorted: List<DedupedDeal>, today: LocalDate): List<DealGroup> {
        val now = mutableListOf<DedupedDeal>()
        val expired = mutableListOf<DedupedDeal>()
        val upcoming = LinkedHashMap<LocalDate, MutableList<DedupedDeal>>()
        for (deal in sorted) {
            val v = DealValidityLogic.validity(deal.primary, today)
            when {
                v.status == DealValidityStatus.UPCOMING && v.from != null ->
                    upcoming.getOrPut(v.from) { mutableListOf() }.add(deal)
                v.status == DealValidityStatus.EXPIRED -> expired += deal
                else -> now += deal
            }
        }
        val result = mutableListOf<DealGroup>()
        if (now.isNotEmpty()) result += DealGroup(id = "__valid_now__", kind = DealGroup.Kind.VALID_NOW, deals = now)
        upcoming.toSortedMap().forEach { (day, deals) ->
            result += DealGroup(
                id = "__from_${day}__",
                kind = DealGroup.Kind.UPCOMING,
                from = day,
                startsInDays = today.daysUntil(day),
                deals = deals,
            )
        }
        if (expired.isNotEmpty()) result += DealGroup(id = "__expired__", kind = DealGroup.Kind.EXPIRED, deals = expired)
        return result
    }

    fun avgDiscount(deals: List<DedupedDeal>): Int {
        val discounts = deals.mapNotNull { it.primary.discountPct }
        if (discounts.isEmpty()) return 0
        return (discounts.sum() / discounts.size).toInt()
    }
}
