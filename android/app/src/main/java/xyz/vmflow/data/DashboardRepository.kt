package xyz.vmflow.data

import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.CancellationException
import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import xyz.vmflow.models.ActivityLogRow
import xyz.vmflow.models.IntakeTransactionRow
import xyz.vmflow.models.Sale
import xyz.vmflow.models.SaleWithMachine
import xyz.vmflow.models.Tray
import xyz.vmflow.models.VendingMachineWithEmbedded

/**
 * Per-machine (not per-tray) stock health, mirrors `loadMachineStats()` in
 * `ios/VMflow/ViewModels/DashboardViewModel.swift`. A machine is counted at
 * most once — the buckets come from [StockHealth.buckets], which is disjoint
 * by construction.
 */
data class MachineStockHealth(
    val total: Int,
    val online: Int,
    val criticalMachines: Int,
    val lowMachines: Int,
)

/**
 * Dashboard-tile projection of the cash book (Barkasse) state. Deliberately
 * thinner than the full `ios/VMflow/ViewModels/CashBookViewModel.swift`
 * pipeline (no per-machine breakdown, no write paths) — this only backs the
 * dashboard's compact summary tile, not the (not yet ported) Cash Book
 * screen itself.
 */
data class CashBookSummary(
    val hasCashBook: Boolean,
    val bookName: String? = null,
    /** Latest `balance_after`, falling back to `initial_balance` with no entries yet. */
    val currentBalance: Double = 0.0,
    /** `cash_sales_since` from the `get_theoretical_cash` RPC — cash sitting in the machines. */
    val cashInMachines: Double = 0.0,
    val lastDepositAt: Instant? = null,
)

/**
 * Seam between [DashboardViewModel][xyz.vmflow.ui.dashboard.DashboardViewModel]
 * and the network so tests can substitute a fake — no Robolectric, no fake
 * Postgrest server, no new test dependency.
 */
interface DashboardDataSource {
    suspend fun fetchSalesSince(since: Instant): List<Sale>
    suspend fun fetchMachineStockHealth(): MachineStockHealth
    suspend fun fetchRecentSaleItems(windowStart: Instant): Pair<List<SaleWithMachine>, Int>
    suspend fun fetchActivityRows(windowStart: Instant): List<ActivityLogRow>
    suspend fun fetchIntakeRows(windowStart: Instant): List<IntakeTransactionRow>
    suspend fun resolveUserNames(ids: List<String>): Map<String, String>
    /** Product names by lowercased id, for slot change feed rows; never throws. */
    suspend fun resolveProductNames(ids: List<String>): Map<String, String> = emptyMap()
    suspend fun fetchNewDealsCount(): Int
    suspend fun fetchCashBookSummary(): CashBookSummary
}

/** `users` row shape used only to resolve intake attribution display names. */
@Serializable
private data class UserRow(
    val id: String,
    @SerialName("first_name") val firstName: String? = null,
    @SerialName("last_name") val lastName: String? = null,
    val email: String? = null,
)

/** `products` row shape used only to name slot change feed rows. */
@Serializable
private data class ProductNameRow(val id: String, val name: String? = null)

/** `cash_books` row shape used only by the dashboard summary tile. */
@Serializable
private data class CashBookRow(
    val id: String,
    val name: String,
    @SerialName("company_id") val companyId: String,
    @SerialName("initial_balance") val initialBalance: Double = 0.0,
    @SerialName("is_active") val isActive: Boolean = true,
)

@Serializable
private data class CashBookBalanceRow(
    @SerialName("balance_after") val balanceAfter: Double = 0.0,
)

@Serializable
private data class CashBookPayoutRow(
    @SerialName("created_at") val createdAt: Instant,
)

@Serializable
private data class TheoreticalCashParams(
    @SerialName("p_cash_book_id") val cashBookId: String,
    @SerialName("p_company_id") val companyId: String,
)

/** Only the field the dashboard tile shows; the RPC returns more (see `get_theoretical_cash`). */
@Serializable
private data class TheoreticalCashResult(
    @SerialName("cash_sales_since") val cashSalesSince: Double = 0.0,
)

/**
 * Dashboard queries in one place. Mirrors the fetches in
 * `ios/VMflow/ViewModels/DashboardViewModel.swift` (Z. 82-117, 277-445) —
 * both clients must query and degrade identically or the same backend shows
 * a different dashboard on each phone.
 */
object DashboardRepository : DashboardDataSource {
    private val postgrest get() = SupabaseService.client.postgrest

    private const val SALE_COLUMNS =
        "id, created_at, item_price, item_number, machine_id, embedded_id, channel"
    private const val SALE_WITH_PRODUCT_COLUMNS =
        "id, created_at, item_price, item_number, machine_id, embedded_id, channel, product_id, products(name, image_path)"
    private const val MACHINE_COLUMNS =
        "id, name, location_lat, location_lon, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version, mdb_diagnostics, online_since)"
    private const val TRAY_COLUMNS =
        "id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(id, name, image_path, discontinued, sellprice)"

    override suspend fun fetchSalesSince(since: Instant): List<Sale> =
        postgrest.from("sales")
            .select(Columns.raw(SALE_COLUMNS)) {
                filter { gte("created_at", since.toString()) }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<Sale>()

    /**
     * Stock-semantics reminder (spec, not obvious from the column names):
     * these are MACHINE counts, not tray counts. The classification itself
     * lives in [StockHealth] and is shared with the PWA's
     * `app/lib/stock-health.ts`: an empty tray only makes a machine CRITICAL
     * when it holds a product the warehouse can actually refill — an
     * unassigned slot, or one whose product is out of stock everywhere, is a
     * swap candidate rather than a refill alert.
     */
    override suspend fun fetchMachineStockHealth(): MachineStockHealth {
        val machines = postgrest.from("vendingMachine")
            .select(Columns.raw(MACHINE_COLUMNS))
            .decodeList<VendingMachineWithEmbedded>()

        // Paged for the same reason as [RefillRepository.fetchRefillMachines]:
        // this is a company-wide read of a growing table, and PostgREST caps a
        // response at `db.max_rows` silently. Truncated, the dashboard would
        // under-count the machines that need refilling — a banner that
        // under-reports is worse than one that errors. Ordered by `id` purely
        // to give paging a total order; nothing downstream depends on the
        // order, only on having every row.
        val trays = fetchAllPages { from, to ->
            postgrest.from("machine_trays")
                .select(Columns.raw(TRAY_COLUMNS)) {
                    order("id", Order.ASCENDING)
                    range(from, to)
                }
                .decodeList<Tray>()
        }

        // A warehouse-fetch failure degrades to "no warehouse data", which
        // treats every product as refillable (the pre-warehouse behaviour),
        // rather than failing the dashboard: this is enrichment, not core
        // data. Same call and same fallback as the machine list's
        // [MachineRepository.fetchMachinesWithStats].
        val warehouseProductIds = MachineRepository.fetchWarehouseStockProductIds()
            .getOrDefault(emptySet())

        // Machines without a single tray row never reach `summaries` — they
        // have nothing to refill, which is exactly the OK bucket.
        val buckets = StockHealth.buckets(
            StockHealth.summaries(
                trays = trays,
                warehouseProductIds = warehouseProductIds,
                hasWarehouses = warehouseProductIds.isNotEmpty(),
            ).values
        )

        return MachineStockHealth(
            total = machines.size,
            online = machines.count { it.connectivity().isConnected },
            criticalMachines = buckets.critical,
            lowMachines = buckets.low,
        )
    }

    /**
     * Sales + machine names + product fallback via trays, unchanged pipeline
     * from iOS. Returns the display items plus the RAW row count — the
     * infinite-scroll exhaustion check in the ViewModel compares raw rows,
     * not merged items, because new transactions folding into an existing
     * intake group would otherwise leave the merged count unchanged and
     * falsely signal "no more history".
     */
    override suspend fun fetchRecentSaleItems(windowStart: Instant): Pair<List<SaleWithMachine>, Int> {
        val sales = postgrest.from("sales")
            .select(Columns.raw(SALE_WITH_PRODUCT_COLUMNS)) {
                filter { gte("created_at", windowStart.toString()) }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<Sale>()

        val machineIds = sales.mapNotNull { it.machineId }.toSet()
        val machineNames = mutableMapOf<String, String>()
        if (machineIds.isNotEmpty()) {
            val machines = postgrest.from("vendingMachine")
                .select(Columns.raw("id, name, location_lat, location_lon, country_code")) {
                    filter { isIn("id", machineIds.toList()) }
                }
                .decodeList<VendingMachineWithEmbedded>()
            for (machine in machines) machineNames[machine.id] = machine.displayName
        }

        // Fallback: tray -> product lookup only for old sales without a
        // snapshotted product_id.
        val salesWithoutProduct = sales.filter { it.productId == null && it.machineId != null }
        val trayProductLookup = mutableMapOf<String, Pair<String?, String?>>()
        if (salesWithoutProduct.isNotEmpty()) {
            val fallbackMachineIds = salesWithoutProduct.mapNotNull { it.machineId }.toSet()
            val trays = postgrest.from("machine_trays")
                .select(Columns.raw(TRAY_COLUMNS)) {
                    filter { isIn("machine_id", fallbackMachineIds.toList()) }
                }
                .decodeList<Tray>()
            for (tray in trays) {
                val key = "${tray.machineId}_${tray.itemNumber}"
                trayProductLookup[key] = tray.products?.name to tray.products?.imagePath
            }
        }

        val items = sales.map { sale ->
            val machineName = sale.machineId?.let { machineNames[it] }

            // Prefer the snapshotted product from the FK join, fall back to
            // the tray lookup for pre-product_id sales.
            var productName = sale.products?.name
            var productImagePath = sale.products?.imagePath
            if (productName == null && sale.machineId != null && sale.itemNumber != null) {
                val fallback = trayProductLookup["${sale.machineId}_${sale.itemNumber}"]
                productName = fallback?.first
                productImagePath = fallback?.second
            }

            SaleWithMachine(
                sale = sale,
                machineName = machineName,
                productName = productName,
                productImagePath = productImagePath,
            )
        }
        return items to sales.size
    }

    /** Refill + tour-start + slot-change + cash-book rows. RLS scopes to the user's company. */
    override suspend fun fetchActivityRows(windowStart: Instant): List<ActivityLogRow> =
        postgrest.from("activity_log")
            .select(Columns.raw("id, created_at, user_id, action, metadata")) {
                filter {
                    isIn("action", listOf("stock_refill_tour", "tour_started", "slot_change_applied", "cash_book_entry_created"))
                    gte("created_at", windowStart.toString())
                }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<ActivityLogRow>()

    /**
     * Incoming warehouse transactions with product/warehouse names joined.
     * Both type strings are read: the PWA books intakes as 'incoming', the
     * iOS/Android apps as 'intake' — a pre-existing cross-client divergence.
     * Querying only one silently drops half the feed.
     */
    override suspend fun fetchIntakeRows(windowStart: Instant): List<IntakeTransactionRow> =
        postgrest.from("warehouse_transactions")
            .select(Columns.raw("id, created_at, warehouse_id, user_id, quantity_change, products(name), warehouses(name)")) {
                filter {
                    isIn("transaction_type", listOf("incoming", "intake"))
                    gte("created_at", windowStart.toString())
                }
                order("created_at", Order.ASCENDING)
            }
            .decodeList<IntakeTransactionRow>()

    /**
     * Resolve display names for intake attribution. The `users` FK points to
     * `auth.users`, so PostgREST can't embed it — same lookup pattern as the
     * iOS ProductDetailSheet. Degrades to an empty map on any failure
     * (including a missing table under restrictive RLS): a missing name must
     * never take down the feed.
     */
    override suspend fun resolveUserNames(ids: List<String>): Map<String, String> {
        if (ids.isEmpty()) return emptyMap()
        return try {
            val rows = postgrest.from("users")
                .select(Columns.raw("id, first_name, last_name, email")) {
                    filter { isIn("id", ids) }
                }
                .decodeList<UserRow>()
            rows.associate { user ->
                val full = listOfNotNull(user.firstName, user.lastName)
                    .filter { it.isNotEmpty() }
                    .joinToString(" ")
                val display = full.ifEmpty { user.email ?: user.id.take(8) }
                user.id to display
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyMap()
        }
    }

    /**
     * Product names for the slot change feed rows, keyed by lowercased id.
     * Degrades to an empty map on any failure: the row then shows the slot
     * number only.
     */
    override suspend fun resolveProductNames(ids: List<String>): Map<String, String> {
        if (ids.isEmpty()) return emptyMap()
        return try {
            postgrest.from("products")
                .select(Columns.raw("id, name")) {
                    filter { isIn("id", ids) }
                }
                .decodeList<ProductNameRow>()
                .mapNotNull { p -> p.name?.let { p.id.lowercase() to it } }
                .toMap()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyMap()
        }
    }

    /**
     * New/unhandled deals count for the dashboard banner. Swallows failure
     * (including a backend without the `get_new_deals_count` RPC) so a
     * missing extension point never breaks the dashboard.
     */
    override suspend fun fetchNewDealsCount(): Int =
        try {
            postgrest.rpc("get_new_deals_count").decodeAs()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            0
        }

    /**
     * Dashboard cash-book tile. Picks the first active Barkasse (alphabetical
     * — Android has no persisted per-user selection like
     * `CashBookViewModel.selectedCashBookId` on iOS, so there is nothing to
     * reconcile against). Swallows any failure (missing tables on an older
     * backend, RPC error, etc.) down to "no cash book" so a Barkasse problem
     * never breaks the rest of the dashboard.
     */
    override suspend fun fetchCashBookSummary(): CashBookSummary = try {
        val books = postgrest.from("cash_books")
            .select(Columns.raw("id, name, company_id, initial_balance, is_active")) {
                order("name", Order.ASCENDING)
            }
            .decodeList<CashBookRow>()
        val book = books.firstOrNull { it.isActive } ?: books.firstOrNull()

        if (book == null) {
            CashBookSummary(hasCashBook = false)
        } else {
            val latest = postgrest.from("cash_book_entries")
                .select(Columns.raw("balance_after")) {
                    filter { eq("cash_book_id", book.id) }
                    order("entry_number", Order.DESCENDING)
                    limit(1)
                }
                .decodeList<CashBookBalanceRow>()
                .firstOrNull()

            val lastPayout = postgrest.from("cash_book_entries")
                .select(Columns.raw("created_at")) {
                    filter {
                        eq("cash_book_id", book.id)
                        eq("type", "payout")
                        eq("is_reversed", false)
                    }
                    order("entry_number", Order.DESCENDING)
                    limit(1)
                }
                .decodeList<CashBookPayoutRow>()
                .firstOrNull()

            val cashInMachines = try {
                val params = Json.encodeToJsonElement(
                    TheoreticalCashParams(cashBookId = book.id, companyId = book.companyId),
                ).jsonObject
                postgrest.rpc("get_theoretical_cash", params).decodeAs<TheoreticalCashResult>().cashSalesSince
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                0.0
            }

            CashBookSummary(
                hasCashBook = true,
                bookName = book.name,
                currentBalance = latest?.balanceAfter ?: book.initialBalance,
                cashInMachines = cashInMachines,
                lastDepositAt = lastPayout?.createdAt,
            )
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        CashBookSummary(hasCashBook = false)
    }
}
