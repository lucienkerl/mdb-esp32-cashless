package de.kerlhandel.vmflow.data.repository

import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.Tray
import de.kerlhandel.vmflow.data.model.TrayUpsert
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.IoDispatcher
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TrayRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @IoDispatcher private val io: CoroutineDispatcher,
) {
    suspend fun fetchTrays(machineId: String): List<Tray> = withContext(io) {
        clientProvider.require().from("machine_trays").select(
            Columns.raw(
                "id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)"
            )
        ) {
            filter { eq("machine_id", machineId) }
            order("item_number", Order.ASCENDING)
        }.decodeList<Tray>()
    }

    /** Returns all non-discontinued products (client-side filter — SDK has no clean `or is null` syntax). */
    suspend fun fetchActiveProducts(): List<Product> = withContext(io) {
        clientProvider.require().from("products").select(
            Columns.raw("id, name, image_path, discontinued, sellprice, category")
        ) {
            order("name", Order.ASCENDING)
        }.decodeList<Product>()
            .filter { it.discontinued != true }
    }

    suspend fun createTray(payload: TrayUpsert) = withContext(io) {
        clientProvider.require().from("machine_trays").insert(payload)
    }

    suspend fun batchCreateTrays(machineId: String, startSlot: Int, count: Int, capacity: Int) = withContext(io) {
        val payloads = (0 until count).map { i ->
            TrayUpsert(
                machineId = machineId,
                itemNumber = startSlot + i,
                productId = null,
                capacity = capacity,
                currentStock = 0,
                minStock = 0,
                fillWhenBelow = 0,
            )
        }
        clientProvider.require().from("machine_trays").insert(payloads)
    }

    suspend fun updateTray(trayId: String, payload: TrayUpsert) = withContext(io) {
        clientProvider.require().from("machine_trays").update(payload) {
            filter { eq("id", trayId) }
        }
    }

    suspend fun updateStock(trayId: String, newStock: Int) = withContext(io) {
        clientProvider.require().from("machine_trays").update(mapOf("current_stock" to newStock)) {
            filter { eq("id", trayId) }
        }
    }

    suspend fun deleteTray(trayId: String) = withContext(io) {
        clientProvider.require().from("machine_trays").delete {
            filter { eq("id", trayId) }
        }
    }
}
