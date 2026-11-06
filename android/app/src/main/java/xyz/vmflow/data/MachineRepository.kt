package xyz.vmflow.data

import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.datetime.Clock
import kotlinx.datetime.LocalDate
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.encodeToJsonElement
import xyz.vmflow.R
import xyz.vmflow.VMflowApp
import xyz.vmflow.models.DeviceRestart
import xyz.vmflow.models.MachineWithStats
import xyz.vmflow.models.MdbLogEntry
import xyz.vmflow.models.Paxcounter
import xyz.vmflow.models.Sale
import xyz.vmflow.models.SuppressedSale
import xyz.vmflow.models.Tray
import xyz.vmflow.models.VendingMachineWithEmbedded

/**
 * Lightweight decode target for the warehouse-availability presence check —
 * mirrors iOS's private `WarehouseStockBatchLite`. Selecting only these two
 * columns keeps the query cheap; the full `WarehouseStockBatch` model
 * requires columns (`id`, `warehouse_id`) this query doesn't fetch.
 */
@Serializable
private data class WarehouseStockBatchLite(
    @SerialName("product_id") val productId: String,
    val quantity: Int = 0
)

@Serializable
private data class RestoreSuppressedSaleParams(
    @SerialName("p_suppressed_id") val suppressedId: String
)

@Serializable
private data class SendCreditBody(
    @SerialName("device_id") val deviceId: String,
    val amount: Double
)

/** Full-row patch for the Machine Settings sheet — one `update` call, same shape as iOS `updateSettings(...)`'s `Patch`. */
@Serializable
private data class MachineSettingsPatch(
    @SerialName("location_lat") val locationLat: Double?,
    @SerialName("location_lon") val locationLon: Double?,
    @SerialName("address_street") val addressStreet: String?,
    @SerialName("address_house_number") val addressHouseNumber: String?,
    @SerialName("address_postal_code") val addressPostalCode: String?,
    @SerialName("address_city") val addressCity: String?,
    @SerialName("formatted_address") val formattedAddress: String?,
    @SerialName("country_code") val countryCode: String?,
    @SerialName("nayax_machine_id") val nayaxMachineId: String?,
    @SerialName("public_listing") val publicListing: Boolean
)

object MachineRepository {
    private val postgrest get() = SupabaseService.client.postgrest
    private val functions get() = SupabaseService.client.functions

    suspend fun fetchMachines(): Result<List<VendingMachineWithEmbedded>> {
        return try {
            val machines = postgrest.from("vendingMachine")
                .select(Columns.raw("id, name, location_lat, location_lon, country_code, linked_selections, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version, mdb_diagnostics, online_since)"))
                .decodeList<VendingMachineWithEmbedded>()
            Result.success(machines)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Product ids with any positive-quantity warehouse stock, for the
     * machine list's per-product warehouse-availability check. Presence
     * only (yes/no), not quantity — mirrors iOS's actual behaviour, not a
     * coverage percentage. Fetched once for all machines by
     * [fetchMachinesWithStats], not per-machine.
     */
    suspend fun fetchWarehouseStockProductIds(): Result<Set<String>> {
        return try {
            val batches = postgrest.from("warehouse_stock_batches")
                .select(Columns.raw("product_id, quantity")) {
                    filter {
                        gt("quantity", 0)
                    }
                }
                .decodeList<WarehouseStockBatchLite>()
            Result.success(batches.map { it.productId }.toSet())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchMachinesWithStats(): Result<List<MachineWithStats>> {
        return try {
            val machines = fetchMachines().getOrThrow()
            // A warehouse-fetch failure degrades gracefully to "no warehouse
            // data" (every product refillable, deficit rows UNKNOWN) rather than failing
            // the whole machine list — this is enrichment, not core data.
            val warehouseProductIds = fetchWarehouseStockProductIds().getOrDefault(emptySet())
            val hasWarehouses = warehouseProductIds.isNotEmpty()
            val now = Clock.System.now()
            val tz = TimeZone.currentSystemDefault()
            val todayDate = now.toLocalDateTime(tz).date
            val yesterdayDate = LocalDate(todayDate.year, todayDate.month, todayDate.dayOfMonth)
                .let {
                    val epochDays = it.toEpochDays() - 1
                    LocalDate.fromEpochDays(epochDays)
                }
            val todayStart = "${todayDate}T00:00:00"
            val yesterdayStart = "${yesterdayDate}T00:00:00"
            val yesterdayEnd = "${todayDate}T00:00:00"

            val machinesWithStats = machines.map { machine ->
                try {
                    val todaySales = postgrest.from("sales")
                        .select {
                            filter {
                                eq("machine_id", machine.id)
                                gte("created_at", todayStart)
                            }
                        }
                        .decodeList<Sale>()

                    val yesterdaySales = postgrest.from("sales")
                        .select {
                            filter {
                                eq("machine_id", machine.id)
                                gte("created_at", yesterdayStart)
                                lt("created_at", yesterdayEnd)
                            }
                        }
                        .decodeList<Sale>()

                    val lastSale = postgrest.from("sales")
                        .select {
                            filter {
                                eq("machine_id", machine.id)
                            }
                            order("created_at", Order.DESCENDING)
                            limit(1)
                        }
                        .decodeList<Sale>()
                        .firstOrNull()

                    val trays = postgrest.from("machine_trays")
                        .select(Columns.raw("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(id, name, image_path, discontinued, sellprice)")) {
                            filter {
                                eq("machine_id", machine.id)
                            }
                            order("item_number", Order.ASCENDING)
                        }
                        .decodeList<Tray>()

                    val paxCount = machine.embeddeds?.id?.let { embeddedId ->
                        try {
                            postgrest.from("paxcounter")
                                .select {
                                    filter {
                                        eq("embedded_id", embeddedId)
                                        gte("created_at", todayStart)
                                    }
                                }
                                .decodeList<Paxcounter>()
                                .sumOf { it.count }
                        } catch (_: Exception) { 0 }
                    } ?: 0

                    val deficitSummary = MachineDeficits.computeDeficits(trays, warehouseProductIds, hasWarehouses) { itemNumber ->
                        VMflowApp.instance.getString(R.string.machine_card_unassigned_slot, itemNumber)
                    }

                    MachineWithStats(
                        machine = machine,
                        todayRevenue = todaySales.sumOf { it.itemPrice },
                        todaySalesCount = todaySales.size,
                        yesterdayRevenue = yesterdaySales.sumOf { it.itemPrice },
                        lastSaleAt = lastSale?.createdAt,
                        paxCount = paxCount,
                        trays = trays,
                        trayDeficits = deficitSummary.trayDeficits,
                        swapNeededCount = deficitSummary.swapNeededCount,
                        noStockCount = deficitSummary.noStockCount,
                        warehouseProductIds = warehouseProductIds,
                        hasWarehouses = hasWarehouses
                    )
                } catch (_: Exception) {
                    MachineWithStats(machine = machine)
                }
            }

            // PWA order: critical > low > top off > ok, then sold-out + low products desc.
            // Devices that need attention (offline, no response, machine not
            // talking to the reader) first, then stock urgency — same as iOS.
            val sorted = machinesWithStats.sortedWith(
                compareBy<MachineWithStats> { if (it.machine.connectivity(now).needsAttention) 0 else 1 }
                    .then(MachineWithStats.STOCK_URGENCY)
            )

            Result.success(sorted)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchMachineDetail(machineId: String): Result<MachineWithStats> {
        return try {
            val machine = postgrest.from("vendingMachine")
                .select(
                    Columns.raw(
                        "id, name, location_lat, location_lon, country_code, " +
                            "address_street, address_house_number, address_postal_code, address_city, " +
                            "formatted_address, nayax_machine_id, public_listing, linked_selections, " +
                            "embeddeds(id, status, status_at, subdomain, mac_address, firmware_version, " +
                            "mdb_diagnostics, last_restart_reason, last_restart_at, online_since)"
                    )
                ) {
                    filter { eq("id", machineId) }
                    limit(1)
                }
                .decodeSingle<VendingMachineWithEmbedded>()

            // Degrades to "no warehouse data" (every product refillable) on failure, like the list.
            val warehouseProductIds = fetchWarehouseStockProductIds().getOrDefault(emptySet())

            val now = Clock.System.now()
            val tz = TimeZone.currentSystemDefault()
            val todayDate = now.toLocalDateTime(tz).date
            val yesterdayDate = LocalDate.fromEpochDays(todayDate.toEpochDays() - 1)
            val todayStart = "${todayDate}T00:00:00"
            val yesterdayStart = "${yesterdayDate}T00:00:00"
            val yesterdayEnd = "${todayDate}T00:00:00"

            val todaySales = postgrest.from("sales")
                .select {
                    filter {
                        eq("machine_id", machineId)
                        gte("created_at", todayStart)
                    }
                }
                .decodeList<Sale>()

            val yesterdaySales = postgrest.from("sales")
                .select {
                    filter {
                        eq("machine_id", machineId)
                        gte("created_at", yesterdayStart)
                        lt("created_at", yesterdayEnd)
                    }
                }
                .decodeList<Sale>()

            val lastSale = postgrest.from("sales")
                .select {
                    filter { eq("machine_id", machineId) }
                    order("created_at", Order.DESCENDING)
                    limit(1)
                }
                .decodeList<Sale>()
                .firstOrNull()

            val trays = postgrest.from("machine_trays")
                .select(Columns.raw("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(id, name, image_path, discontinued, sellprice)")) {
                    filter { eq("machine_id", machineId) }
                    order("item_number", Order.ASCENDING)
                }
                .decodeList<Tray>()

            val paxCount = machine.embeddeds?.id?.let { embeddedId ->
                try {
                    postgrest.from("paxcounter")
                        .select {
                            filter {
                                eq("embedded_id", embeddedId)
                                gte("created_at", todayStart)
                            }
                        }
                        .decodeList<Paxcounter>()
                        .sumOf { it.count }
                } catch (_: Exception) { 0 }
            } ?: 0

            Result.success(
                MachineWithStats(
                    machine = machine,
                    todayRevenue = todaySales.sumOf { it.itemPrice },
                    todaySalesCount = todaySales.size,
                    yesterdayRevenue = yesterdaySales.sumOf { it.itemPrice },
                    lastSaleAt = lastSale?.createdAt,
                    paxCount = paxCount,
                    trays = trays,
                    // Same warehouse-aware counts as the machine list's card.
                    warehouseProductIds = warehouseProductIds,
                    hasWarehouses = warehouseProductIds.isNotEmpty()
                )
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchRecentSales(limit: Int = 20): Result<List<Sale>> {
        return try {
            val sales = postgrest.from("sales")
                .select {
                    order("created_at", Order.DESCENDING)
                    limit(limit.toLong())
                }
                .decodeList<Sale>()
            Result.success(sales)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchMachineSales(machineId: String, limit: Int = 50): Result<List<Sale>> {
        return try {
            val sales = postgrest.from("sales")
                .select {
                    filter { eq("machine_id", machineId) }
                    order("created_at", Order.DESCENDING)
                    limit(limit.toLong())
                }
                .decodeList<Sale>()
            Result.success(sales)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Auto-dropped brownout duplicates for a machine's embedded device, newest
     * first. Mirrors iOS `loadSuppressedSales()` — empty list when the machine
     * has no linked device (caller passes the `embedded_id`, not the machine).
     */
    suspend fun fetchSuppressedSales(embeddedId: String, limit: Int = 100): Result<List<SuppressedSale>> {
        return try {
            val sales = postgrest.from("suppressed_sales")
                .select(
                    Columns.raw(
                        "id, embedded_id, item_number, item_price, channel, sale_seq, device_created_at, " +
                            "received_at, matched_sale_id, reason, product_id, products(name, image_path), " +
                            "matched:sales!matched_sale_id(created_at)"
                    )
                ) {
                    filter { eq("embedded_id", embeddedId) }
                    order("received_at", Order.DESCENDING)
                    limit(limit.toLong())
                }
                .decodeList<SuppressedSale>()
            Result.success(sales)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Past reboots of a machine's embedded device, newest first. Feeds the
     * Device Health sheet's "Restart History" section (all members).
     */
    suspend fun fetchDeviceRestarts(embeddedId: String, limit: Int = 50): Result<List<DeviceRestart>> {
        return try {
            val restarts = postgrest.from("device_restarts")
                .select(Columns.raw("id, created_at, reason, uptime_sec, firmware_version, hw_reason")) {
                    filter { eq("embedded_id", embeddedId) }
                    order("created_at", Order.DESCENDING)
                    limit(limit.toLong())
                }
                .decodeList<DeviceRestart>()
            Result.success(restarts)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Past MDB state transitions of a machine's embedded device, newest
     * first. Feeds the Device Health sheet's admin-only "MDB State Changes"
     * section.
     */
    suspend fun fetchMdbLog(embeddedId: String, limit: Int = 50): Result<List<MdbLogEntry>> {
        return try {
            val logs = postgrest.from("mdb_log")
                .select(Columns.raw("id, created_at, state, prev_state, addr, polls, chk_err, last_cmd")) {
                    filter { eq("embedded_id", embeddedId) }
                    order("created_at", Order.DESCENDING)
                    limit(limit.toLong())
                }
                .decodeList<MdbLogEntry>()
            Result.success(logs)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Status changes (`embedded_status_log`, one row per change of
     * `embeddeds.status`) since [since], oldest first — the input of the
     * 24-hour bar ([StatusHistory.build]).
     */
    suspend fun fetchStatusLog(embeddedId: String, since: String): Result<List<StatusLogRow>> {
        return try {
            val rows = postgrest.from("embedded_status_log")
                .select(Columns.raw("status, prev_status, created_at")) {
                    filter {
                        eq("embedded_id", embeddedId)
                        gte("created_at", since)
                    }
                    order("created_at", Order.ASCENDING)
                }
                .decodeList<StatusLogRow>()
            Result.success(rows)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Promotes an auto-removed sale back into a real sale via the
     * `restore_suppressed_sale` RPC (admin-only — the RPC itself enforces it).
     * Caller reloads machine detail on success so trays/sales/suppressedSales
     * all reflect the change.
     */
    suspend fun restoreSuppressedSale(suppressedId: String): Result<Unit> {
        return try {
            val params = Json.encodeToJsonElement(RestoreSuppressedSaleParams(suppressedId)).jsonObject
            postgrest.rpc("restore_suppressed_sale", params)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Sends free credit to a machine's device via the `send-credit` edge
     * function — same effect as inserting a coin/card payment. No sale is
     * recorded here; the device reports the vend itself over MQTT when it
     * happens. Mirrors iOS `MachineDetailViewModel.sendCredit(amount:)`: the
     * response body isn't consumed, a non-throwing call is success.
     */
    suspend fun sendCredit(deviceId: String, amount: Double): Result<Unit> {
        return try {
            functions.invoke("send-credit", SendCreditBody(deviceId = deviceId, amount = amount))
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Persists the Machine Settings sheet's fields (location, address,
     * country, Nayax ID, public listing) in a single `update`. Mirrors iOS
     * `MachineDetailViewModel.updateSettings(...)`. No admin gating here —
     * matches the iOS UI, which lets any member open and save this sheet; a
     * non-admin write rejected by RLS surfaces as a normal failure.
     */
    suspend fun updateMachineSettings(
        machineId: String,
        locationLat: Double?,
        locationLon: Double?,
        addressStreet: String?,
        addressHouseNumber: String?,
        addressPostalCode: String?,
        addressCity: String?,
        formattedAddress: String?,
        countryCode: String?,
        nayaxMachineId: String?,
        publicListing: Boolean
    ): Result<Unit> {
        return try {
            postgrest.from("vendingMachine")
                .update(
                    MachineSettingsPatch(
                        locationLat = locationLat,
                        locationLon = locationLon,
                        addressStreet = addressStreet,
                        addressHouseNumber = addressHouseNumber,
                        addressPostalCode = addressPostalCode,
                        addressCity = addressCity,
                        formattedAddress = formattedAddress,
                        countryCode = countryCode,
                        nayaxMachineId = nayaxMachineId,
                        publicListing = publicListing
                    )
                ) {
                    filter { eq("id", machineId) }
                }
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
