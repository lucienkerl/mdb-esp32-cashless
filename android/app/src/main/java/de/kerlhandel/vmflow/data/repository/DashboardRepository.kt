package de.kerlhandel.vmflow.data.repository

import de.kerlhandel.vmflow.data.model.DailySales
import de.kerlhandel.vmflow.data.model.Sale
import de.kerlhandel.vmflow.data.model.SaleWithMachine
import de.kerlhandel.vmflow.data.model.Tray
import de.kerlhandel.vmflow.data.model.VendingMachine
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.IoDispatcher
import de.kerlhandel.vmflow.util.WeekBoundaries
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.datetime.LocalDate
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.toLocalDateTime
import javax.inject.Inject
import javax.inject.Singleton

data class DashboardKpis(
    val todayRevenue: Double,
    val todaySalesCount: Int,
    val yesterdayRevenue: Double,
    val weekRevenue: Double,
    val weekSalesCount: Int,
    val monthRevenue: Double,
    val machinesOnline: Int,
    val machinesTotal: Int,
    val stockCriticalCount: Int,
    val stockLowCount: Int,
    val dailySales: List<DailySales>,
    val recentSales: List<SaleWithMachine>,
)

@Singleton
class DashboardRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @IoDispatcher private val ioDispatcher: CoroutineDispatcher,
) {
    suspend fun loadDashboard(): DashboardKpis = withContext(ioDispatcher) {
        coroutineScope {
            val client = clientProvider.require()
            val monthStart = WeekBoundaries.startOfMonth()
            val startOfToday = WeekBoundaries.startOfToday()
            val startOfYesterday = WeekBoundaries.startOfYesterday()
            val startOfWeek = WeekBoundaries.startOfThisWeek()
            val thirtyDaysAgo: LocalDate = WeekBoundaries.pastDays(30).first()
            val tz = TimeZone.currentSystemDefault()

            // --- Parallel fetches ---

            val salesDeferred = async {
                client.from("sales").select(
                    columns = Columns.raw(
                        "id, created_at, item_price, item_number, machine_id, embedded_id, channel"
                    )
                ) {
                    filter { gte("created_at", monthStart.toString()) }
                    order("created_at", Order.DESCENDING)
                }.decodeList<Sale>()
            }

            val machinesDeferred = async {
                client.from("vendingMachine").select(
                    columns = Columns.raw(
                        "id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)"
                    )
                ).decodeList<VendingMachine>()
            }

            val traysDeferred = async {
                client.from("machine_trays").select(
                    columns = Columns.raw(
                        "id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)"
                    )
                ).decodeList<Tray>()
            }

            val chartSalesDeferred = async {
                val startInstant = thirtyDaysAgo.atStartOfDayIn(tz)
                client.from("sales").select(
                    columns = Columns.raw(
                        "id, created_at, item_price, item_number, machine_id, embedded_id, channel"
                    )
                ) {
                    filter { gte("created_at", startInstant.toString()) }
                    order("created_at", Order.ASCENDING)
                }.decodeList<Sale>()
            }

            val recentSalesDeferred = async {
                client.from("sales").select(
                    columns = Columns.raw(
                        "id, created_at, item_price, item_number, machine_id, embedded_id, channel, product_id, products(name, image_path)"
                    )
                ) {
                    order("created_at", Order.DESCENDING)
                    limit(20)
                }.decodeList<Sale>()
            }

            val sales = salesDeferred.await()
            val machines = machinesDeferred.await()
            val trays = traysDeferred.await()
            val chartSales = chartSalesDeferred.await()
            val recentSales = recentSalesDeferred.await()

            // --- KPIs ---
            var todayRev = 0.0; var todayCount = 0
            var yesterdayRev = 0.0
            var weekRev = 0.0; var weekCount = 0
            var monthRev = 0.0
            for (sale in sales) {
                val price = sale.itemPrice ?: 0.0
                monthRev += price
                if (sale.createdAt >= startOfWeek) { weekRev += price; weekCount += 1 }
                if (sale.createdAt >= startOfToday) { todayRev += price; todayCount += 1 }
                else if (sale.createdAt >= startOfYesterday && sale.createdAt < startOfToday) yesterdayRev += price
            }

            // --- Machine stock health ---
            val traysByMachine = trays.groupBy { it.machineId }
            var criticalCount = 0; var lowCount = 0
            for (machine in machines) {
                val machineTrays = traysByMachine[machine.id].orEmpty()
                val hasEmpty = machineTrays.any { it.isEmpty }
                val hasLow = machineTrays.any { it.isBelowMinStock }
                when {
                    hasEmpty -> criticalCount++
                    hasLow -> lowCount++
                }
            }

            // --- 30-day chart (pre-fill all days with 0) ---
            val dailyMap = linkedMapOf<LocalDate, Pair<Double, Int>>()
            for (day in WeekBoundaries.pastDays(30)) dailyMap[day] = 0.0 to 0
            for (sale in chartSales) {
                val localDate = sale.createdAt.toLocalDateTime(tz).date
                val existing = dailyMap[localDate] ?: (0.0 to 0)
                dailyMap[localDate] = (existing.first + (sale.itemPrice ?: 0.0)) to (existing.second + 1)
            }
            val dailySales = dailyMap.entries.sortedBy { it.key }
                .map { (date, rc) -> DailySales(date, rc.first, rc.second) }

            // --- Recent sales with machine + product lookup ---
            val machineNames = machines.associate { it.id to it.displayName }
            val recentEnriched = recentSales.map { sale ->
                val productName = sale.products?.name
                val productImage = sale.products?.imagePath
                val fallback = if (productName == null && sale.machineId != null && sale.itemNumber != null) {
                    trays.firstOrNull { it.machineId == sale.machineId && it.itemNumber == sale.itemNumber }
                } else null
                SaleWithMachine(
                    sale = sale,
                    machineName = sale.machineId?.let { machineNames[it] },
                    productName = productName ?: fallback?.products?.name,
                    productImagePath = productImage ?: fallback?.products?.imagePath,
                )
            }

            DashboardKpis(
                todayRevenue = todayRev,
                todaySalesCount = todayCount,
                yesterdayRevenue = yesterdayRev,
                weekRevenue = weekRev,
                weekSalesCount = weekCount,
                monthRevenue = monthRev,
                machinesOnline = machines.count { it.isOnline },
                machinesTotal = machines.size,
                stockCriticalCount = criticalCount,
                stockLowCount = lowCount,
                dailySales = dailySales,
                recentSales = recentEnriched,
            )
        }
    }
}
