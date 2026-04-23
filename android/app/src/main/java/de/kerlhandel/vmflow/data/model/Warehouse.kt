package de.kerlhandel.vmflow.data.model

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class Warehouse(
    val id: String,
    val name: String,
    val address: String? = null,
    val notes: String? = null,
    @SerialName("company_id") val companyId: String,
)

@Serializable
data class WarehouseStockBatch(
    val id: String,
    @SerialName("warehouse_id") val warehouseId: String,
    @SerialName("product_id") val productId: String,
    val quantity: Int,
    @SerialName("batch_number") val batchNumber: String? = null,
    @SerialName("expiration_date") val expirationDate: String? = null,
)

/** Aggregated warehouse stock per product (sum of all batches). */
data class WarehouseProductStock(
    val productId: String,
    val productName: String,
    val totalQuantity: Int,
    val imagePath: String? = null,
)

/** Product stock summary for warehouse overview (with batch + expiration info). */
data class WarehouseProductSummary(
    val productId: String,
    val productName: String,
    val imagePath: String? = null,
    val totalQuantity: Int,
    val batchCount: Int,
    val earliestExpiration: String? = null,
) {
    val isLow: Boolean get() = totalQuantity < 10
    val isOutOfStock: Boolean get() = totalQuantity == 0
}

data class IntakeEntry(
    val id: String,
    val productId: String,
    val productName: String,
    val imagePath: String?,
    val quantity: Int,
    val batchNumber: String?,
    val expirationDate: String?,
    val createdAt: Instant,
)

@Serializable
data class InsertStockBatch(
    @SerialName("warehouse_id") val warehouseId: String,
    @SerialName("product_id") val productId: String,
    val quantity: Int,
    @SerialName("batch_number") val batchNumber: String?,
    @SerialName("expiration_date") val expirationDate: String?,
    @SerialName("company_id") val companyId: String,
)

@Serializable
data class InsertWarehouseTransaction(
    @SerialName("warehouse_id") val warehouseId: String,
    @SerialName("product_id") val productId: String,
    @SerialName("transaction_type") val transactionType: String,
    @SerialName("quantity_change") val quantityChange: Int,
    @SerialName("user_id") val userId: String,
    @SerialName("batch_id") val batchId: String?,
    val notes: String?,
    @SerialName("company_id") val companyId: String,
    @SerialName("quantity_before") val quantityBefore: Int? = null,
    @SerialName("quantity_after") val quantityAfter: Int? = null,
    @SerialName("batch_number") val batchNumber: String? = null,
    @SerialName("expiration_date") val expirationDate: String? = null,
)

@Serializable
data class InsertedBatchResponse(val id: String)

@Serializable
data class WarehouseProductPosition(
    @SerialName("product_id") val productId: String,
    @SerialName("sort_order") val sortOrder: Int,
    @SerialName("group_id") val groupId: String? = null,
)

@Serializable
data class WarehousePositionGroup(
    val id: String,
    @SerialName("parent_id") val parentId: String? = null,
    @SerialName("sort_order") val sortOrder: Int,
)

/** Adjustment reasons — maps directly to `warehouse_transactions.transaction_type`. */
enum class AdjustReason(val raw: String) {
    RefillReturn("adjustment_refill_return"),
    Correction("adjustment_correction"),
    Damage("adjustment_damage"),
    Expired("adjustment_expired"),
}
