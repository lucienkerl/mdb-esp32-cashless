package de.kerlhandel.vmflow.data.model

import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Product info joined from the snapshotted product_id FK on sales. */
@Serializable
data class SaleProduct(
    val name: String? = null,
    @SerialName("image_path") val imagePath: String? = null,
)

/** A vend event — maps to the `sales` table. item_price is EUR (not cents). */
@Serializable
data class Sale(
    val id: String,
    @SerialName("created_at") val createdAt: Instant,
    @SerialName("machine_id") val machineId: String? = null,
    @SerialName("embedded_id") val embeddedId: String? = null,
    @SerialName("item_price") val itemPrice: Double? = null,
    @SerialName("item_number") val itemNumber: Int? = null,
    val channel: String? = null,
    @SerialName("product_id") val productId: String? = null,
    val products: SaleProduct? = null,
) {
    fun formattedPrice(): String =
        itemPrice?.let { String.format("%.2f €", it) } ?: "--"
}

/** Sale with joined machine name for display in lists. */
data class SaleWithMachine(
    val sale: Sale,
    val machineName: String? = null,
    val productName: String? = null,
    val productImagePath: String? = null,
) {
    val id: String get() = sale.id
}

/** Aggregated daily sales for charting. */
data class DailySales(
    val date: LocalDate,
    val revenue: Double,
    val count: Int,
) {
    val id: LocalDate get() = date
}

/** Paxcounter foot-traffic entry. */
@Serializable
data class Paxcounter(
    val id: String,
    @SerialName("embedded_id") val embeddedId: String? = null,
    val count: Int,
    @SerialName("created_at") val createdAt: Instant? = null,
)
