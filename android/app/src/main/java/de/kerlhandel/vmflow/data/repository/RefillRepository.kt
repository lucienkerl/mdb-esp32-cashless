package de.kerlhandel.vmflow.data.repository

import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.Tray
import de.kerlhandel.vmflow.data.model.VendingMachine
import de.kerlhandel.vmflow.data.model.Warehouse
import de.kerlhandel.vmflow.data.model.WarehouseProductPosition
import de.kerlhandel.vmflow.data.model.WarehousePositionGroup
import de.kerlhandel.vmflow.data.model.WarehouseStockBatch
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.IoDispatcher
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Data access for the refill wizard. All DB mutations during a tour (stock
 * updates, activity log, warehouse deduction) also live here.
 */
@Singleton
class RefillRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @IoDispatcher private val io: CoroutineDispatcher,
) {
    data class RefillData(
        val machines: List<VendingMachine>,
        val trays: List<Tray>,
        val warehouses: List<Warehouse>,
        val activeProducts: List<Product>,
    )

    suspend fun loadAll(): RefillData = withContext(io) {
        coroutineScope {
            val client = clientProvider.require()
            val machines = async {
                client.from("vendingMachine").select(
                    Columns.raw("id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")
                ).decodeList<VendingMachine>()
            }
            val trays = async {
                client.from("machine_trays").select(
                    Columns.raw("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
                ) { order("item_number", Order.ASCENDING) }.decodeList<Tray>()
            }
            val warehouses = async {
                client.from("warehouses").select(
                    Columns.raw("id, name, address, notes, company_id")
                ).decodeList<Warehouse>()
            }
            val products = async {
                client.from("products").select(
                    Columns.raw("id, name, image_path, discontinued, sellprice, category")
                ) { order("name", Order.ASCENDING) }.decodeList<Product>()
                    .filter { it.discontinued != true }
            }
            RefillData(machines.await(), trays.await(), warehouses.await(), products.await())
        }
    }

    suspend fun loadStockBatches(warehouseId: String): List<WarehouseStockBatch> = withContext(io) {
        clientProvider.require().from("warehouse_stock_batches").select(
            Columns.raw("id, warehouse_id, product_id, quantity, batch_number, expiration_date")
        ) {
            filter { eq("warehouse_id", warehouseId); gt("quantity", 0) }
        }.decodeList<WarehouseStockBatch>()
    }

    suspend fun loadPickOrder(warehouseId: String): List<String> = withContext(io) {
        coroutineScope {
            val client = clientProvider.require()
            val groupsDeferred = async {
                client.from("warehouse_position_groups").select(
                    Columns.raw("id, parent_id, sort_order")
                ) {
                    filter { eq("warehouse_id", warehouseId) }
                    order("sort_order", Order.ASCENDING)
                }.decodeList<WarehousePositionGroup>()
            }
            val positionsDeferred = async {
                client.from("warehouse_product_positions").select(
                    Columns.raw("product_id, sort_order, group_id")
                ) {
                    filter { eq("warehouse_id", warehouseId) }
                    order("sort_order", Order.ASCENDING)
                }.decodeList<WarehouseProductPosition>()
            }
            val groups = groupsDeferred.await()
            val positions = positionsDeferred.await()

            // Depth-first traversal through groups (matches iOS RefillWizardViewModel).
            data class Node(
                val id: String,
                val parentId: String?,
                val sortOrder: Int,
                val children: MutableList<Node> = mutableListOf(),
                val productIds: MutableList<String> = mutableListOf(),
            )
            val map = groups.associate { it.id to Node(it.id, it.parentId, it.sortOrder) }
            val roots = mutableListOf<Node>()
            for (node in map.values) {
                val parent = node.parentId?.let(map::get)
                if (parent != null) parent.children.add(node) else roots.add(node)
            }
            fun sortLevel(node: Node) {
                node.children.sortBy { it.sortOrder }
                for (child in node.children) sortLevel(child)
            }
            roots.sortBy { it.sortOrder }
            for (r in roots) sortLevel(r)

            val ungrouped = mutableListOf<String>()
            for (p in positions) {
                val g = p.groupId?.let(map::get)
                if (g != null) g.productIds.add(p.productId) else ungrouped.add(p.productId)
            }
            val result = mutableListOf<String>()
            fun traverse(list: List<Node>) {
                for (n in list) { result.addAll(n.productIds); traverse(n.children) }
            }
            traverse(roots)
            result.addAll(ungrouped)
            result
        }
    }

    suspend fun updateTrayStock(trayId: String, newStock: Int) = withContext(io) {
        clientProvider.require().from("machine_trays").update(mapOf("current_stock" to newStock)) {
            filter { eq("id", trayId) }
        }
    }

    suspend fun updateTrayProduct(trayId: String, productId: String) = withContext(io) {
        clientProvider.require().from("machine_trays").update(mapOf("product_id" to productId)) {
            filter { eq("id", trayId) }
        }
    }
}
