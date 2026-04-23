package de.kerlhandel.vmflow.data.repository

import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.Warehouse
import de.kerlhandel.vmflow.data.model.WarehouseProductSummary
import de.kerlhandel.vmflow.data.model.WarehouseStockBatch
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.IoDispatcher
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class WarehouseRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @IoDispatcher private val io: CoroutineDispatcher,
) {
    @Serializable
    private data class BatchWithProduct(
        val id: String,
        @SerialName("product_id") val productId: String,
        val quantity: Int,
        @SerialName("expiration_date") val expirationDate: String? = null,
        val products: NestedProduct? = null,
    ) {
        @Serializable
        data class NestedProduct(
            val name: String? = null,
            @SerialName("image_path") val imagePath: String? = null,
        )
    }

    @Serializable
    data class IntakePayload(
        @SerialName("warehouse_id") val warehouseId: String,
        @SerialName("product_id") val productId: String,
        val quantity: Int,
        @SerialName("batch_number") val batchNumber: String?,
        @SerialName("expiration_date") val expirationDate: String?,
        @SerialName("company_id") val companyId: String,
    )

    @Serializable
    data class TransactionPayload(
        @SerialName("warehouse_id") val warehouseId: String,
        @SerialName("product_id") val productId: String,
        @SerialName("transaction_type") val transactionType: String,
        @SerialName("quantity_change") val quantityChange: Int,
        @SerialName("user_id") val userId: String,
        @SerialName("batch_id") val batchId: String?,
        val notes: String?,
        @SerialName("company_id") val companyId: String,
        @SerialName("batch_number") val batchNumber: String?,
        @SerialName("expiration_date") val expirationDate: String?,
    )

    @Serializable
    private data class InsertedId(val id: String)

    @Serializable
    private data class BarcodeRow(@SerialName("product_id") val productId: String)

    suspend fun fetchWarehouses(): List<Warehouse> = withContext(io) {
        clientProvider.require().from("warehouses").select(
            Columns.raw("id, name, address, notes, company_id")
        ) { order("name", Order.ASCENDING) }.decodeList<Warehouse>()
    }

    suspend fun fetchActiveProducts(): List<Product> = withContext(io) {
        clientProvider.require().from("products").select(
            Columns.raw("id, name, image_path, discontinued, sellprice, category")
        ) { order("name", Order.ASCENDING) }.decodeList<Product>()
            .filter { it.discontinued != true }
    }

    suspend fun fetchBatchesForProduct(warehouseId: String, productId: String): List<WarehouseStockBatch> =
        withContext(io) {
            clientProvider.require().from("warehouse_stock_batches").select(
                Columns.raw("id, warehouse_id, product_id, quantity, batch_number, expiration_date")
            ) {
                filter {
                    eq("warehouse_id", warehouseId)
                    eq("product_id", productId)
                    gt("quantity", 0)
                }
                order("expiration_date", Order.ASCENDING)
            }.decodeList<WarehouseStockBatch>()
        }

    suspend fun fetchProductSummaries(warehouseId: String): List<WarehouseProductSummary> = withContext(io) {
        val batches = clientProvider.require().from("warehouse_stock_batches").select(
            Columns.raw("id, product_id, quantity, expiration_date, products(name, image_path)")
        ) {
            filter { eq("warehouse_id", warehouseId); gt("quantity", 0) }
        }.decodeList<BatchWithProduct>()

        val grouped = mutableMapOf<String, WarehouseProductSummary>()
        for (b in batches) {
            val existing = grouped[b.productId]
            val newEarliest = listOfNotNull(existing?.earliestExpiration, b.expirationDate).minOrNull()
            grouped[b.productId] = WarehouseProductSummary(
                productId = b.productId,
                productName = b.products?.name ?: existing?.productName ?: "Unknown",
                imagePath = b.products?.imagePath ?: existing?.imagePath,
                totalQuantity = (existing?.totalQuantity ?: 0) + b.quantity,
                batchCount = (existing?.batchCount ?: 0) + 1,
                earliestExpiration = newEarliest,
            )
        }
        grouped.values.sortedWith(
            compareByDescending<WarehouseProductSummary> { it.isOutOfStock }
                .thenByDescending { it.isLow }
                .thenBy { it.productName.lowercase() }
        )
    }

    suspend fun bookIntake(
        warehouseId: String,
        productId: String,
        quantity: Int,
        batchNumber: String?,
        expirationDate: String?,
    ) = withContext(io) {
        val client = clientProvider.require()
        val companyId = fetchWarehouses().firstOrNull { it.id == warehouseId }?.companyId
            ?: return@withContext
        val userId = client.auth.currentUserOrNull()?.id ?: return@withContext

        val batchRows: List<InsertedId> = client.from("warehouse_stock_batches").insert(
            IntakePayload(warehouseId, productId, quantity, batchNumber, expirationDate, companyId),
        ) { select(Columns.raw("id")) }.decodeList()
        val batchId = batchRows.firstOrNull()?.id

        client.from("warehouse_transactions").insert(
            TransactionPayload(
                warehouseId = warehouseId,
                productId = productId,
                transactionType = "intake",
                quantityChange = quantity,
                userId = userId,
                batchId = batchId,
                notes = batchNumber?.takeIf { it.isNotBlank() }?.let { "Batch: $it" },
                companyId = companyId,
                batchNumber = batchNumber,
                expirationDate = expirationDate,
            ),
        )
    }

    /** Resolve product_id from a barcode. Null = unknown barcode. */
    suspend fun lookupBarcode(barcode: String): String? = withContext(io) {
        clientProvider.require().from("product_barcodes").select(Columns.raw("product_id")) {
            filter { eq("barcode", barcode) }
            limit(1)
        }.decodeList<BarcodeRow>().firstOrNull()?.productId
    }
}
