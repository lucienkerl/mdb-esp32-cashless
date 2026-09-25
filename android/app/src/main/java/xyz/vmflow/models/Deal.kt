package xyz.vmflow.models

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Response of the `deal-search` edge function. Mirrors iOS `DealSearchResponse`
 * (`ios/VMflow/Models/Deal.swift`). `message` carries "No deal-source providers
 * enabled" when the company has no active provider (same check as the web's
 * `useDeals.noProviders`).
 */
@Serializable
data class DealSearchResponse(
    val deals: List<Deal> = emptyList(),
    val fromCache: Boolean = false,
    val searchedProducts: Int? = null,
    val totalDeals: Int? = null,
    val message: String? = null,
)

/** One `deal_cache` row as returned by `deal-search`. Mirrors iOS `Deal`. */
@Serializable
data class Deal(
    val id: String,
    @SerialName("product_id") val productId: String? = null,
    @SerialName("keyword_id") val keywordId: String? = null,
    @SerialName("matched_term") val matchedTerm: String? = null,
    val retailer: String,
    @SerialName("deal_title") val dealTitle: String,
    @SerialName("deal_price") val dealPrice: Double? = null,
    @SerialName("regular_price") val regularPrice: Double? = null,
    @SerialName("discount_pct") val discountPct: Double? = null,
    /** DATE column (`YYYY-MM-DD`), a calendar day in the company's timezone. */
    @SerialName("valid_from") val validFrom: String? = null,
    /** DATE column (`YYYY-MM-DD`), last valid calendar day. */
    @SerialName("valid_until") val validUntil: String? = null,
    @SerialName("image_url") val imageUrl: String? = null,
    @SerialName("image_url_large") val imageUrlLarge: String? = null,
    @SerialName("source_url") val sourceUrl: String? = null,
    @SerialName("external_url") val externalUrl: String? = null,
    @SerialName("matched_by") val matchedBy: String = "",
    val confidence: Double = 0.0,
    @SerialName("matched_tokens") val matchedTokens: List<String>? = null,
    @SerialName("requires_app") val requiresApp: Boolean = false,
    @SerialName("fetched_at") val fetchedAt: String? = null,
    @SerialName("offer_id") val offerId: String? = null,
    val products: DealProduct? = null,
    @SerialName("deal_keywords") val dealKeywords: DealKeywordMatch? = null,
)

/** Joined `products` relation on a deal row. */
@Serializable
data class DealProduct(
    val id: String? = null,
    val name: String? = null,
    @SerialName("image_path") val imagePath: String? = null,
    val sellprice: Double? = null,
)

/**
 * Keyword group embedded on keyword-matched rows. PostgREST returns the linked
 * products as `deal_keyword_products: [{ products: {...} }]`; [linkedProducts]
 * flattens that like iOS `DealKeywordMatch.linkedProducts`.
 */
@Serializable
data class DealKeywordMatch(
    val id: String? = null,
    val label: String? = null,
    val terms: List<String>? = null,
    @SerialName("deal_keyword_products") val dealKeywordProducts: List<LinkedProductRow> = emptyList(),
) {
    @Serializable
    data class LinkedProductRow(val products: DealProduct? = null)

    val linkedProducts: List<DealProduct>
        get() = dealKeywordProducts.mapNotNull { it.products }
}

/**
 * Per-user archive/pin annotation (`deal_user_state`), keyed by
 * (retailer, offer_id). Absence of a row means neither archived nor pinned.
 */
@Serializable
data class DealUserStateRow(
    val retailer: String,
    @SerialName("offer_id") val offerId: String,
    @SerialName("archived_at") val archivedAt: String? = null,
    @SerialName("pinned_at") val pinnedAt: String? = null,
)

/** Row of the `get_new_deal_keys` RPC. */
@Serializable
data class NewDealKeyRow(
    val retailer: String,
    @SerialName("offer_id") val offerId: String,
)

/** Per-product purchase-price aggregates from `get_product_purchase_summary`. Mirrors iOS `ProductPurchaseSummary`. */
@Serializable
data class ProductPurchaseSummary(
    @SerialName("product_id") val productId: String,
    @SerialName("ek_count") val ekCount: Int = 0,
    @SerialName("newest_net") val newestNet: Double? = null,
    @SerialName("newest_gross") val newestGross: Double? = null,
    @SerialName("newest_supplier") val newestSupplier: String? = null,
    @SerialName("newest_on") val newestOn: String? = null,
    @SerialName("min_gross") val minGross: Double? = null,
    @SerialName("min_supplier") val minSupplier: String? = null,
    @SerialName("min_on") val minOn: String? = null,
    @SerialName("max_gross") val maxGross: Double? = null,
    @SerialName("effective_tax_rate") val effectiveTaxRate: Double? = null,
)
