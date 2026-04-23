package de.kerlhandel.vmflow.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Machine tray/slot — maps to `machine_trays`. Includes nested products. */
@Serializable
data class Tray(
    val id: String,
    @SerialName("machine_id") val machineId: String,
    @SerialName("item_number") val itemNumber: Int,
    @SerialName("product_id") val productId: String? = null,
    val capacity: Int,
    @SerialName("current_stock") val currentStock: Int,
    @SerialName("min_stock") val minStock: Int = 0,
    @SerialName("fill_when_below") val fillWhenBelow: Int = 0,
    val products: TrayProduct? = null,
) {
    val productName: String get() = products?.name?.takeIf { it.isNotBlank() } ?: "Slot $itemNumber"
    val isDiscontinued: Boolean get() = products?.discontinued == true
    val fillRatio: Double get() = if (capacity > 0) currentStock.toDouble() / capacity else 0.0
    val deficit: Int get() = (capacity - currentStock).coerceAtLeast(0)
    val isEmpty: Boolean get() = currentStock == 0
    val isBelowMinStock: Boolean get() = minStock > 0 && currentStock <= minStock
    val isBelowFillThreshold: Boolean get() = fillWhenBelow > 0 && currentStock <= fillWhenBelow

    val stockHealth: StockHealth
        get() = when {
            isEmpty -> StockHealth.Critical
            isBelowMinStock -> StockHealth.Low
            else -> StockHealth.Ok
        }

    /** Formatted EUR sell price, or `null` when no product is assigned. */
    fun formattedSellprice(): String? =
        products?.sellprice?.let { String.format("%.2f €", it) }
}

/**
 * Payload for creating/updating a tray.
 * NOTE: `product_id` is ALWAYS serialized (including as `null`). PostgREST
 * treats omitted fields as "don't change", so clearing a tray's product
 * requires an explicit `null`. See iOS [Tray.swift:118] for the bug this fixes.
 */
@Serializable
data class TrayUpsert(
    @SerialName("machine_id") val machineId: String,
    @SerialName("item_number") val itemNumber: Int,
    @SerialName("product_id") val productId: String?,
    val capacity: Int,
    @SerialName("current_stock") val currentStock: Int,
    @SerialName("min_stock") val minStock: Int,
    @SerialName("fill_when_below") val fillWhenBelow: Int,
)
