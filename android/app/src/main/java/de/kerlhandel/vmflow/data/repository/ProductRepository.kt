package de.kerlhandel.vmflow.data.repository

import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.ProductBarcode
import de.kerlhandel.vmflow.data.model.ProductCategory
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
class ProductRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @IoDispatcher private val io: CoroutineDispatcher,
) {
    @Serializable
    private data class OrgMemberRow(
        @SerialName("company_id") val companyId: String,
    )

    @Serializable
    private data class InsertedId(val id: String)

    @Serializable
    data class ProductPayload(
        val name: String,
        val discontinued: Boolean,
        val sellprice: Double? = null,
        val category: String? = null,
        val company: String? = null,
        @SerialName("image_path") val imagePath: String? = null,
    )

    @Serializable
    data class CategoryPayload(val name: String, val company: String)

    @Serializable
    data class BarcodePayload(
        @SerialName("product_id") val productId: String,
        val barcode: String,
        val format: String,
        @SerialName("company_id") val companyId: String,
    )

    suspend fun fetchProducts(): List<Product> = withContext(io) {
        clientProvider.require().from("products").select(
            Columns.raw("id, name, image_path, discontinued, sellprice, category")
        ) {
            order("name", Order.ASCENDING)
        }.decodeList<Product>()
    }

    suspend fun fetchCategories(): List<ProductCategory> = withContext(io) {
        clientProvider.require().from("product_category").select(
            Columns.raw("id, name, company")
        ) {
            order("name", Order.ASCENDING)
        }.decodeList<ProductCategory>()
    }

    suspend fun fetchBarcodes(productId: String): List<ProductBarcode> = withContext(io) {
        clientProvider.require().from("product_barcodes").select(
            Columns.raw("id, product_id, barcode, format, company_id")
        ) {
            filter { eq("product_id", productId) }
            order("created_at", Order.DESCENDING)
        }.decodeList<ProductBarcode>()
    }

    /** Helper: resolve the current user's company_id from organization_members. */
    suspend fun currentCompanyId(): String? = withContext(io) {
        val client = clientProvider.require()
        val userId = client.auth.currentUserOrNull()?.id ?: return@withContext null
        val result = client.from("organization_members").select(Columns.raw("company_id")) {
            filter { eq("user_id", userId) }
            limit(1)
        }.decodeList<OrgMemberRow>()
        result.firstOrNull()?.companyId
    }

    suspend fun createProduct(
        name: String,
        sellprice: Double?,
        categoryId: String?,
        discontinued: Boolean,
    ): String? = withContext(io) {
        val company = currentCompanyId() ?: return@withContext null
        val payload = ProductPayload(
            name = name,
            discontinued = discontinued,
            sellprice = sellprice,
            category = categoryId,
            company = company,
        )
        val rows: List<InsertedId> = clientProvider.require().from("products")
            .insert(payload) { select(Columns.raw("id")) }
            .decodeList()
        rows.firstOrNull()?.id
    }

    suspend fun updateProduct(
        id: String,
        name: String,
        sellprice: Double?,
        categoryId: String?,
        discontinued: Boolean,
    ) = withContext(io) {
        val payload = ProductPayload(
            name = name,
            discontinued = discontinued,
            sellprice = sellprice,
            category = categoryId,
        )
        clientProvider.require().from("products").update(payload) {
            filter { eq("id", id) }
        }
    }

    suspend fun deleteProduct(id: String) = withContext(io) {
        clientProvider.require().from("products").delete {
            filter { eq("id", id) }
        }
    }

    suspend fun createCategory(name: String): String? = withContext(io) {
        val company = currentCompanyId() ?: return@withContext null
        val rows: List<InsertedId> = clientProvider.require().from("product_category")
            .insert(CategoryPayload(name, company)) { select(Columns.raw("id")) }
            .decodeList()
        rows.firstOrNull()?.id
    }

    suspend fun updateCategory(id: String, name: String) = withContext(io) {
        clientProvider.require().from("product_category")
            .update(mapOf("name" to name)) { filter { eq("id", id) } }
    }

    suspend fun deleteCategory(id: String) = withContext(io) {
        clientProvider.require().from("product_category").delete {
            filter { eq("id", id) }
        }
    }

    suspend fun addBarcode(productId: String, barcode: String, format: String = "EAN-13"): Boolean =
        withContext(io) {
            val company = currentCompanyId() ?: return@withContext false
            runCatching {
                clientProvider.require().from("product_barcodes")
                    .insert(BarcodePayload(productId, barcode, format, company))
            }.isSuccess
        }

    suspend fun deleteBarcode(id: String) = withContext(io) {
        clientProvider.require().from("product_barcodes").delete {
            filter { eq("id", id) }
        }
    }
}
