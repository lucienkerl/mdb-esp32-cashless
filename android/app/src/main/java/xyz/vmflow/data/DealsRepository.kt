package xyz.vmflow.data

import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.ktor.client.call.body
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import xyz.vmflow.models.DealSearchResponse
import xyz.vmflow.models.DealUserStateRow
import xyz.vmflow.models.NewDealKeyRow
import xyz.vmflow.models.ProductPurchaseSummary

/** Warehouse + machine stock for one product, shown next to matched products in the deal detail. */
data class DealStockTotals(
    val warehouseQty: Int = 0,
    val trayStock: Int = 0,
    val trayCapacity: Int = 0,
)

/**
 * Data access for the Deals screen. An interface so the state engine can be
 * unit-tested with a fake, same pattern as [DashboardDataSource].
 */
interface DealsDataSource {
    /** `companies.deals_enabled` for the caller's company (RLS scopes the read). */
    suspend fun fetchDealsEnabled(): Boolean
    suspend fun searchDeals(forceRefresh: Boolean): DealSearchResponse
    suspend fun fetchUserStates(): Map<String, DealUserState>
    suspend fun fetchNewDealKeys(): Set<String>
    suspend fun fetchPurchaseSummaries(productIds: List<String>): Map<String, ProductPurchaseSummary>
    suspend fun upsertUserState(retailer: String, offerId: String, archivedAt: String?, pinnedAt: String?)
    suspend fun fetchStockTotals(productIds: List<String>): Map<String, DealStockTotals>
}

@Serializable
private data class CompanyDealSettingsRow(
    @SerialName("deals_enabled") val dealsEnabled: Boolean? = null,
)

@Serializable
private data class DealSearchBody(
    val forceRefresh: Boolean,
    val minConfidence: Double,
)

/**
 * Upsert payload. Deliberately no default values: every field must be encoded
 * — including explicit nulls — so un-archiving/un-pinning actually clears the
 * column instead of the upsert leaving the old timestamp in place.
 */
@Serializable
private data class DealUserStateUpsert(
    @SerialName("user_id") val userId: String,
    @SerialName("company_id") val companyId: String,
    val retailer: String,
    @SerialName("offer_id") val offerId: String,
    @SerialName("archived_at") val archivedAt: String?,
    @SerialName("pinned_at") val pinnedAt: String?,
)

@Serializable
private data class StockBatchRow(
    @SerialName("product_id") val productId: String? = null,
    val quantity: Int = 0,
)

@Serializable
private data class TrayStockRow(
    @SerialName("product_id") val productId: String? = null,
    @SerialName("current_stock") val currentStock: Int = 0,
    val capacity: Int = 0,
)

object DealsRepository : DealsDataSource {
    private val postgrest get() = SupabaseService.client.postgrest
    private val functions get() = SupabaseService.client.functions
    private val auth get() = SupabaseService.client.auth

    private val json = Json { ignoreUnknownKeys = true }

    /** Mirrors iOS `DealsViewModel.minConfidence` (0.5) sent to `deal-search`. */
    private const val MIN_CONFIDENCE = 0.5

    /**
     * Not cached: this object outlives sign-out and server switches, and a
     * stale company id would write pin/archive state into the wrong company.
     */
    private suspend fun companyId(): String =
        AuthRepository.fetchOrganization().getOrThrow().organization?.id
            ?: throw IllegalStateException("Could not determine company")

    private fun userId(): String =
        auth.currentUserOrNull()?.id ?: throw IllegalStateException("Not signed in")

    override suspend fun fetchDealsEnabled(): Boolean =
        postgrest.from("companies")
            .select(Columns.raw("deals_enabled")) { limit(1) }
            .decodeList<CompanyDealSettingsRow>()
            .firstOrNull()?.dealsEnabled ?: false

    override suspend fun searchDeals(forceRefresh: Boolean): DealSearchResponse {
        val response = functions.invoke(
            "deal-search",
            DealSearchBody(forceRefresh = forceRefresh, minConfidence = MIN_CONFIDENCE),
        )
        return json.decodeFromString<DealSearchResponse>(response.body<String>())
    }

    override suspend fun fetchUserStates(): Map<String, DealUserState> {
        val companyId = companyId()
        val userId = userId()
        return postgrest.from("deal_user_state")
            .select(Columns.raw("retailer, offer_id, archived_at, pinned_at")) {
                filter {
                    eq("company_id", companyId)
                    eq("user_id", userId)
                }
            }
            .decodeList<DealUserStateRow>()
            .associate { DealsLogic.stateKey(it.retailer, it.offerId) to DealUserState(it.archivedAt, it.pinnedAt) }
    }

    override suspend fun fetchNewDealKeys(): Set<String> =
        postgrest.rpc("get_new_deal_keys")
            .decodeList<NewDealKeyRow>()
            .map { DealsLogic.stateKey(it.retailer, it.offerId) }
            .toSet()

    override suspend fun fetchPurchaseSummaries(productIds: List<String>): Map<String, ProductPurchaseSummary> {
        if (productIds.isEmpty()) return emptyMap()
        val params = buildJsonObject {
            put("p_product_ids", JsonArray(productIds.map { JsonPrimitive(it) }))
        }
        return postgrest.rpc("get_product_purchase_summary", params)
            .decodeList<ProductPurchaseSummary>()
            .associateBy { it.productId }
    }

    override suspend fun upsertUserState(retailer: String, offerId: String, archivedAt: String?, pinnedAt: String?) {
        val payload = DealUserStateUpsert(
            userId = userId(),
            companyId = companyId(),
            retailer = retailer,
            offerId = offerId,
            archivedAt = archivedAt,
            pinnedAt = pinnedAt,
        )
        postgrest.from("deal_user_state").upsert(payload) {
            onConflict = "user_id,company_id,retailer,offer_id"
        }
    }

    /**
     * Two reads (warehouse batches + machine trays) aggregated per product —
     * cheap even when a brand-wide deal matches a dozen SKUs. Products without
     * any stock still get a zero entry so the UI can tell "loaded, none" from
     * "not loaded yet". A failing read degrades to zeros rather than failing
     * the whole detail sheet.
     */
    override suspend fun fetchStockTotals(productIds: List<String>): Map<String, DealStockTotals> {
        if (productIds.isEmpty()) return emptyMap()
        return coroutineScope {
            val batches = async {
                safeList {
                    postgrest.from("warehouse_stock_batches")
                        .select(Columns.raw("product_id, quantity")) {
                            filter {
                                isIn("product_id", productIds)
                                gt("quantity", 0)
                            }
                        }
                        .decodeList<StockBatchRow>()
                }
            }
            val trays = async {
                safeList {
                    postgrest.from("machine_trays")
                        .select(Columns.raw("product_id, current_stock, capacity")) {
                            filter { isIn("product_id", productIds) }
                        }
                        .decodeList<TrayStockRow>()
                }
            }
            val totals = productIds.associateWith { DealStockTotals() }.toMutableMap()
            for (row in batches.await()) {
                val pid = row.productId ?: continue
                val t = totals[pid] ?: DealStockTotals()
                totals[pid] = t.copy(warehouseQty = t.warehouseQty + row.quantity)
            }
            for (row in trays.await()) {
                val pid = row.productId ?: continue
                val t = totals[pid] ?: DealStockTotals()
                totals[pid] = t.copy(trayStock = t.trayStock + row.currentStock, trayCapacity = t.trayCapacity + row.capacity)
            }
            totals
        }
    }

    private suspend fun <T> safeList(block: suspend () -> List<T>): List<T> =
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyList()
        }
}
