package de.kerlhandel.vmflow.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class DealSearchResponse(
    val deals: List<Deal>,
    val fromCache: Boolean = false,
    val searchedProducts: Int? = null,
    val totalDeals: Int? = null,
)

@Serializable
data class DealProduct(
    val name: String? = null,
    @SerialName("image_path") val imagePath: String? = null,
    val sellprice: Double? = null,
)

@Serializable
data class Deal(
    val id: String,
    @SerialName("product_id") val productId: String,
    val retailer: String,
    @SerialName("deal_title") val dealTitle: String,
    @SerialName("deal_price") val dealPrice: Double? = null,
    @SerialName("regular_price") val regularPrice: Double? = null,
    @SerialName("discount_pct") val discountPct: Double? = null,
    @SerialName("valid_from") val validFrom: String? = null,
    @SerialName("valid_until") val validUntil: String? = null,
    @SerialName("image_url") val imageUrl: String? = null,
    @SerialName("image_url_large") val imageUrlLarge: String? = null,
    @SerialName("source_url") val sourceUrl: String? = null,
    @SerialName("external_url") val externalUrl: String? = null,
    @SerialName("matched_by") val matchedBy: String,
    val confidence: Double,
    @SerialName("matched_tokens") val matchedTokens: List<String>? = null,
    @SerialName("requires_app") val requiresApp: Boolean = false,
    @SerialName("fetched_at") val fetchedAt: String,
    @SerialName("offer_id") val offerId: String? = null,
    val products: DealProduct? = null,
) {
    enum class ValidityStatus { Upcoming, Active, Expiring, Expired }
    enum class ConfidenceLevel { High, Medium, Low }

    val productName: String get() = products?.name ?: "Unknown Product"

    fun formattedDealPrice(): String? = dealPrice?.let { String.format("%.2f €", it) }
    fun formattedRegularPrice(): String? = regularPrice?.let { String.format("%.2f €", it) }
    fun formattedDiscount(): String? = discountPct?.takeIf { it > 0 }?.let { "-${it.toInt()}%" }

    val confidenceLevel: ConfidenceLevel
        get() = when {
            confidence >= 0.85 -> ConfidenceLevel.High
            confidence >= 0.65 -> ConfidenceLevel.Medium
            else -> ConfidenceLevel.Low
        }

    fun formattedConfidence(): String = "${(confidence * 100).toInt()}%"
}
