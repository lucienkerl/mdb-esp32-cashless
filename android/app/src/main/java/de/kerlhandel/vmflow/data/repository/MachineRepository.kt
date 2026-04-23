package de.kerlhandel.vmflow.data.repository

import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import de.kerlhandel.vmflow.data.model.MachineStats
import de.kerlhandel.vmflow.data.model.Paxcounter
import de.kerlhandel.vmflow.data.model.Sale
import de.kerlhandel.vmflow.data.model.StockSeverity
import de.kerlhandel.vmflow.data.model.Tray
import de.kerlhandel.vmflow.data.model.TrayDeficit
import de.kerlhandel.vmflow.data.model.VendingMachine
import de.kerlhandel.vmflow.data.model.WarehouseAvailability
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.IoDispatcher
import de.kerlhandel.vmflow.util.WeekBoundaries
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName

@Singleton
class MachineRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @IoDispatcher private val io: CoroutineDispatcher,
) {
    @Serializable
    private data class LiteBatch(
        @SerialName("product_id") val productId: String,
        val quantity: Int,
    )

    suspend fun fetchMachinesWithStats(): List<MachineStats> = withContext(io) {
        coroutineScope {
            val client = clientProvider.require()

            val startOfToday = WeekBoundaries.startOfToday()
            val startOfYesterday = WeekBoundaries.startOfYesterday()
            val startOfThisWeek = WeekBoundaries.startOfThisWeek()
            val startOfLastWeek = WeekBoundaries.startOfLastWeek()

            val machinesDeferred = async {
                client.from("vendingMachine").select(
                    Columns.raw(
                        "id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)"
                    )
                ).decodeList<VendingMachine>()
            }
            val salesDeferred = async {
                client.from("sales").select(
                    Columns.raw("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
                ) {
                    filter { gte("created_at", startOfLastWeek.toString()) }
                }.decodeList<Sale>()
            }
            val traysDeferred = async {
                client.from("machine_trays").select(
                    Columns.raw(
                        "id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)"
                    )
                ).decodeList<Tray>()
            }
            val paxDeferred = async {
                client.from("paxcounter").select(
                    Columns.raw("id, embedded_id, count, created_at")
                ) {
                    order("created_at", Order.DESCENDING)
                    limit(200)
                }.decodeList<Paxcounter>()
            }
            val batchesDeferred = async {
                client.from("warehouse_stock_batches").select(
                    Columns.raw("product_id, quantity")
                ) {
                    filter { gt("quantity", 0) }
                }.decodeList<LiteBatch>()
            }

            val machines = machinesDeferred.await()
            val sales = salesDeferred.await()
            val allTrays = traysDeferred.await()
            val paxData = paxDeferred.await()
            val stockBatches = batchesDeferred.await()

            val salesByMachine = sales.groupBy { it.machineId }
            val traysByMachine = allTrays.groupBy { it.machineId }

            // latest paxcounter per embedded id
            val latestPax = mutableMapOf<String, Int>()
            for (entry in paxData) {
                val embId = entry.embeddedId ?: continue
                if (embId !in latestPax) latestPax[embId] = entry.count
            }

            val warehouseStockMap = mutableMapOf<String, Int>()
            for (batch in stockBatches) {
                warehouseStockMap[batch.productId] = (warehouseStockMap[batch.productId] ?: 0) + batch.quantity
            }
            val hasWarehouses = stockBatches.isNotEmpty()

            val stats = machines.map { machine ->
                val machineSales = salesByMachine[machine.id].orEmpty()
                var todayRev = 0.0; var todayCount = 0
                var yesterdayRev = 0.0; var yesterdayCount = 0
                var thisWeekRev = 0.0; var thisWeekCount = 0
                var lastWeekRev = 0.0; var lastWeekCount = 0
                for (sale in machineSales) {
                    val price = sale.itemPrice ?: 0.0
                    if (sale.createdAt >= startOfToday) { todayRev += price; todayCount += 1 }
                    else if (sale.createdAt >= startOfYesterday) { yesterdayRev += price; yesterdayCount += 1 }
                    if (sale.createdAt >= startOfThisWeek) { thisWeekRev += price; thisWeekCount += 1 }
                    else if (sale.createdAt >= startOfLastWeek) { lastWeekRev += price; lastWeekCount += 1 }
                }

                val machineTrays = traysByMachine[machine.id].orEmpty()
                val totalTrays = machineTrays.size
                val emptyTrays = machineTrays.count { it.isEmpty }
                val lowTrays = machineTrays.count { it.isBelowMinStock && !it.isEmpty }
                val totalCapacity = machineTrays.sumOf { it.capacity }
                val totalStock = machineTrays.sumOf { it.currentStock }
                val stockPercent = if (totalCapacity > 0) totalStock.toDouble() / totalCapacity else 1.0

                // Per-product deficit accumulation (matches iOS logic)
                data class Accum(
                    var productName: String,
                    var imagePath: String?,
                    var totalDeficit: Int,
                    var worstSeverity: StockSeverity,
                    var isDiscontinued: Boolean,
                    var hasEmptyTray: Boolean,
                )
                val deficitsByProduct = mutableMapOf<String, Accum>()
                val unassigned = mutableListOf<Accum>()

                for (tray in machineTrays) {
                    val sev = when {
                        tray.isEmpty -> StockSeverity.Critical
                        tray.isBelowMinStock -> StockSeverity.Low
                        tray.isBelowFillThreshold -> StockSeverity.FillBelow
                        else -> null
                    } ?: continue
                    val pid = tray.productId
                    if (pid != null) {
                        val existing = deficitsByProduct[pid]
                        if (existing != null) {
                            existing.totalDeficit += tray.deficit
                            if (sev < existing.worstSeverity) existing.worstSeverity = sev
                            if (tray.isEmpty) existing.hasEmptyTray = true
                        } else {
                            deficitsByProduct[pid] = Accum(
                                productName = tray.productName,
                                imagePath = tray.products?.imagePath,
                                totalDeficit = tray.deficit,
                                worstSeverity = sev,
                                isDiscontinued = tray.isDiscontinued,
                                hasEmptyTray = tray.isEmpty,
                            )
                        }
                    } else {
                        unassigned.add(
                            Accum(
                                productName = tray.productName,
                                imagePath = null,
                                totalDeficit = tray.deficit,
                                worstSeverity = sev,
                                isDiscontinued = false,
                                hasEmptyTray = tray.isEmpty,
                            )
                        )
                    }
                }

                fun warehouseAvail(pid: String?, hasEmpty: Boolean): WarehouseAvailability {
                    if (!hasWarehouses) return WarehouseAvailability.Unknown
                    if (pid == null) return WarehouseAvailability.Unknown
                    if (warehouseStockMap.containsKey(pid)) return WarehouseAvailability.InStock
                    return if (hasEmpty) WarehouseAvailability.NeedsSwap else WarehouseAvailability.NoStock
                }

                val productDeficits = deficitsByProduct.map { (pid, accum) ->
                    TrayDeficit(
                        productName = accum.productName,
                        imagePath = accum.imagePath,
                        deficit = accum.totalDeficit,
                        severity = accum.worstSeverity,
                        isDiscontinued = accum.isDiscontinued,
                        warehouseAvailability = warehouseAvail(pid, accum.hasEmptyTray),
                    )
                }
                val unassignedDeficits = unassigned.map { accum ->
                    TrayDeficit(
                        productName = accum.productName,
                        imagePath = null,
                        deficit = accum.totalDeficit,
                        severity = accum.worstSeverity,
                        isDiscontinued = false,
                        warehouseAvailability = WarehouseAvailability.Unknown,
                    )
                }

                val allDeficits = (productDeficits + unassignedDeficits).sortedWith(
                    compareBy<TrayDeficit> { if (it.warehouseAvailability == WarehouseAvailability.NeedsSwap) 0 else 1 }
                        .thenBy { it.severity }
                        .thenByDescending { it.deficit }
                )

                val swapNeededCount = deficitsByProduct.count { (pid, accum) ->
                    hasWarehouses && !warehouseStockMap.containsKey(pid) && accum.hasEmptyTray
                }
                val noStockCount = deficitsByProduct.count { (pid, accum) ->
                    hasWarehouses && !warehouseStockMap.containsKey(pid) && !accum.hasEmptyTray
                }

                MachineStats(
                    machine = machine,
                    todayRevenue = todayRev,
                    todaySalesCount = todayCount,
                    yesterdayRevenue = yesterdayRev,
                    yesterdaySalesCount = yesterdayCount,
                    thisWeekRevenue = thisWeekRev,
                    thisWeekSalesCount = thisWeekCount,
                    lastWeekRevenue = lastWeekRev,
                    lastWeekSalesCount = lastWeekCount,
                    paxcounterCount = machine.embedded?.let { latestPax[it] },
                    totalTrays = totalTrays,
                    lowTrays = lowTrays,
                    emptyTrays = emptyTrays,
                    stockPercent = stockPercent,
                    swapNeededCount = swapNeededCount,
                    noStockCount = noStockCount,
                    trayDeficits = allDeficits,
                )
            }.sortedBy { it.sortPriority }

            stats
        }
    }

    suspend fun fetchMachine(machineId: String): VendingMachine? = withContext(io) {
        clientProvider.require().from("vendingMachine").select(
            Columns.raw("id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")
        ) {
            filter { eq("id", machineId) }
            limit(1)
        }.decodeSingleOrNull<VendingMachine>()
    }

    suspend fun fetchSalesForMachine(machineId: String, limit: Long = 50): List<Sale> = withContext(io) {
        clientProvider.require().from("sales").select(
            Columns.raw("id, created_at, item_price, item_number, machine_id, embedded_id, channel, product_id, products(name, image_path)")
        ) {
            filter { eq("machine_id", machineId) }
            order("created_at", Order.DESCENDING)
            limit(limit)
        }.decodeList<Sale>()
    }
}
