package xyz.vmflow.data

import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.postgrest.query.filter.FilterOperator
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** One slot of the quittance for `apply_slot_change` (`p_items`). */
data class SlotChangeApplyItem(
    val itemId: String,
    val action: RebuildAction,
    val removed: Int,
    val filled: Int,
    val priceSet: Boolean,
    val ageSet: Boolean = false
)

/** One product's leftovers for `apply_slot_change` (`p_leftovers`). */
data class SlotChangeLeftoverPayload(
    val productId: String,
    val vanQty: Int,
    val machineQty: Int,
    val destination: LeftoverDestination,
    val expirationDate: String?,
    val batchNumber: String?
)

@Serializable
private data class SlotChangeRequestRow(
    val id: String,
    @SerialName("machine_id") val machineId: String,
    val note: String? = null
)

@Serializable
private data class SlotRequestStatusRow(val status: String)

@Serializable
private data class SlotTrayStockRow(
    val id: String,
    @SerialName("current_stock") val currentStock: Int = 0
)

@Serializable
private data class SlotTrayCapacityRow(val id: String, val capacity: Int? = null)

@Serializable
private data class SlotExpiryRow(@SerialName("expiration_date") val expirationDate: String? = null)

/**
 * Slot change requests ("Fächer umbelegen"). A planned layout is a change
 * request, never a tray update: the refill tour shows it as a change note and
 * the refiller quits the rebuild at the machine ([applySlotChange]). Every
 * write goes through the SECURITY DEFINER RPCs in
 * `Docker/supabase/migrations/20261008120000_slot_change_requests.sql`, which
 * web and iOS call the same way. Port of
 * `management-frontend/app/composables/useSlotChangeRequests.ts`.
 */
object SlotChangeRepository {
    private val postgrest get() = SupabaseService.client.postgrest

    /** FK-named joins: the item references `products` twice. */
    private const val ITEM_SELECT =
        "id, request_id, tray_id, item_number, from_product_id, to_product_id, " +
            "from_capacity, to_capacity, from_price, to_price, skip_count, from_min_age, to_min_age, " +
            "from_product:products!slot_change_request_items_from_product_id_fkey(name, image_path), " +
            "to_product:products!slot_change_request_items_to_product_id_fkey(name, image_path)"

    /**
     * Open requests with their pending items, keyed by machine id. A request
     * whose items are all done or withdrawn is left out.
     */
    suspend fun fetchOpenRequests(machineIds: Collection<String>): Result<Map<String, SlotChangeRequest>> {
        return try {
            if (machineIds.isEmpty()) return Result.success(emptyMap())
            val requests = postgrest.from("slot_change_requests")
                .select(Columns.raw("id, machine_id, note")) {
                    filter {
                        eq("status", "open")
                        isIn("machine_id", machineIds.toList())
                    }
                }
                .decodeList<SlotChangeRequestRow>()
            if (requests.isEmpty()) return Result.success(emptyMap())

            val items = postgrest.from("slot_change_request_items")
                .select(Columns.raw(ITEM_SELECT)) {
                    filter {
                        eq("status", "pending")
                        isIn("request_id", requests.map { it.id })
                    }
                    order("item_number", Order.ASCENDING)
                }
                .decodeList<SlotChangeItem>()

            val byRequest = items.groupBy { it.requestId }
            val result = LinkedHashMap<String, SlotChangeRequest>()
            for (r in requests) {
                val own = byRequest[r.id].orEmpty().sortedBy { it.itemNumber }
                if (own.isEmpty()) continue
                result[r.machineId] = SlotChangeRequest(id = r.id, machineId = r.machineId, note = r.note, items = own)
            }
            Result.success(result)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Replaces the machine's pending plan with [changes] (the RPC drops slots
     * that change nothing). Returns the request id, or `null` when nothing is
     * left to change.
     */
    suspend fun saveRequest(machineId: String, changes: List<PlannedChange>, note: String? = null): Result<String?> {
        return try {
            val params = buildJsonObject {
                put("p_machine_id", machineId)
                put(
                    "p_items",
                    JsonArray(
                        changes.map { c ->
                            buildJsonObject {
                                put("tray_id", c.trayId)
                                put("to_product_id", c.toProductId?.let { JsonPrimitive(it) } ?: JsonNull)
                                put("to_capacity", c.toCapacity)
                            }
                        }
                    )
                )
                put("p_note", note?.let { JsonPrimitive(it) } ?: JsonNull)
            }
            val body = postgrest.rpc("save_slot_change_request", params).data.trim()
            val id = if (body.isEmpty() || body == "null") null else Json.decodeFromString<String>(body)
            Result.success(id)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Puts [productId] into [trayId] on the machine's change request, keeping
     * every other pending item and the slot's capacity (from the request,
     * else from the tray). Returns the trays now pending. Port of web
     * `useMachineAnalysis.applySwap`.
     */
    suspend fun queueReplacement(machineId: String, trayId: String, productId: String): Result<Set<String>> {
        return try {
            val open = fetchOpenRequests(listOf(machineId)).getOrThrow()[machineId]
            val capacity = postgrest.from("machine_trays")
                .select(Columns.raw("id, capacity")) {
                    filter { eq("id", trayId) }
                }
                .decodeSingle<SlotTrayCapacityRow>()
                .capacity ?: 0
            val changes = SlotChange.queueReplacement(open?.items.orEmpty(), trayId, productId, capacity)
            saveRequest(machineId, changes).getOrThrow()
            Result.success(changes.map { it.trayId }.toSet())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Quits the rebuild at the machine. Idempotent per (request, tour) on the
     * server, so a retry after a network error cannot book anything twice.
     */
    suspend fun applySlotChange(
        requestId: String,
        tourId: String,
        warehouseId: String?,
        items: List<SlotChangeApplyItem>,
        leftovers: List<SlotChangeLeftoverPayload>
    ): Result<Unit> {
        return try {
            val params = buildJsonObject {
                put("p_request_id", requestId)
                put("p_tour_id", tourId)
                put("p_warehouse_id", warehouseId?.let { JsonPrimitive(it) } ?: JsonNull)
                put(
                    "p_items",
                    JsonArray(
                        items.map { i ->
                            buildJsonObject {
                                put("item_id", i.itemId)
                                put("action", i.action.raw)
                                put("removed", i.removed)
                                put("filled", i.filled)
                                put("price_set", i.priceSet)
                                put("age_set", i.ageSet)
                            }
                        }
                    )
                )
                put("p_leftovers", leftoversJson(leftovers))
            }
            postgrest.rpc("apply_slot_change", params)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Books the leftovers of a whole tour at the warehouse, at the end of the
     * tour (`return_slot_change_leftovers`,
     * `Docker/supabase/migrations/20261010090000_slot_change_tour_returns.sql`).
     * Idempotent per tour on the server: a retry gets the first result back.
     */
    suspend fun returnTourLeftovers(
        tourId: String,
        warehouseId: String?,
        leftovers: List<SlotChangeLeftoverPayload>
    ): Result<Unit> {
        return try {
            val params = buildJsonObject {
                put("p_tour_id", tourId)
                put("p_warehouse_id", warehouseId?.let { JsonPrimitive(it) } ?: JsonNull)
                put("p_leftovers", leftoversJson(leftovers))
            }
            postgrest.rpc("return_slot_change_leftovers", params)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /** `p_leftovers` — the same element shape for both RPCs. */
    private fun leftoversJson(leftovers: List<SlotChangeLeftoverPayload>): JsonArray =
        JsonArray(
            leftovers.map { l ->
                buildJsonObject {
                    put("product_id", l.productId)
                    put("van_qty", l.vanQty)
                    put("machine_qty", l.machineQty)
                    put("destination", l.destination.raw)
                    put("expiration_date", l.expirationDate?.let { JsonPrimitive(it) } ?: JsonNull)
                    put("batch_number", l.batchNumber?.let { JsonPrimitive(it) } ?: JsonNull)
                }
            }
        )

    /** Live `current_stock` of the given trays — the "removed" default at the machine. */
    suspend fun fetchTrayStocks(trayIds: Collection<String>): Result<Map<String, Int>> {
        return try {
            if (trayIds.isEmpty()) return Result.success(emptyMap())
            val rows = postgrest.from("machine_trays")
                .select(Columns.raw("id, current_stock")) {
                    filter { isIn("id", trayIds.toList()) }
                }
                .decodeList<SlotTrayStockRow>()
            Result.success(rows.associate { it.id to it.currentStock })
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Status of a change request ("open", "done", "withdrawn"), or "missing"
     * when the row is gone or no longer visible. `null` when the lookup
     * failed — the caller then keeps the note and `apply_slot_change` tells.
     */
    suspend fun fetchRequestStatus(requestId: String): String? {
        return try {
            val rows = postgrest.from("slot_change_requests")
                .select(Columns.raw("status")) {
                    filter { eq("id", requestId) }
                }
                .decodeList<SlotRequestStatusRow>()
            rows.firstOrNull()?.status ?: "missing"
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Best-before date to suggest for goods taken out of a machine: the date
     * of the batch the last refill of that product into this machine came
     * from. The machine does not track batches, so the refiller confirms it.
     * `null` when nothing is known (or the lookup failed).
     */
    suspend fun suggestExpiry(machineId: String, productId: String): String? {
        return try {
            postgrest.from("warehouse_transactions")
                .select(Columns.raw("expiration_date")) {
                    filter {
                        eq("reference_id", machineId)
                        eq("product_id", productId)
                        eq("transaction_type", "outgoing_refill")
                        filterNot("expiration_date", FilterOperator.IS, "null")
                    }
                    order("created_at", Order.DESCENDING)
                    limit(1)
                }
                .decodeList<SlotExpiryRow>()
                .firstOrNull()?.expirationDate
        } catch (_: Exception) {
            null
        }
    }
}
