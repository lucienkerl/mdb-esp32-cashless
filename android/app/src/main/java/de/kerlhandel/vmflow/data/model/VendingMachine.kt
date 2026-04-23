package de.kerlhandel.vmflow.data.model

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** IoT device record — maps to the `embeddeds` table. */
@Serializable
data class Embedded(
    val id: String,
    val status: String? = null,
    @SerialName("status_at") val statusAt: Instant? = null,
    val subdomain: Int? = null,
    @SerialName("mac_address") val macAddress: String? = null,
    @SerialName("firmware_version") val firmwareVersion: String? = null,
) {
    val isOnline: Boolean get() = status?.lowercase() == "online"
}

/** Vending machine record — maps to the `vendingMachine` table. */
@Serializable
data class VendingMachine(
    val id: String,
    val name: String? = null,
    @SerialName("location_lat") val locationLat: Double? = null,
    @SerialName("location_lon") val locationLon: Double? = null,
    val embedded: String? = null,
    @SerialName("country_code") val countryCode: String? = null,
    val embeddeds: Embedded? = null,
) {
    val displayName: String get() = name?.takeIf { it.isNotBlank() } ?: "Unnamed Machine"
    val isOnline: Boolean get() = embeddeds?.isOnline == true
}

enum class StockHealth { Ok, Low, Critical }
enum class StockSeverity {
    Critical, Low, FillBelow;
    // Natural ordering: Critical < Low < FillBelow
}

enum class WarehouseAvailability {
    InStock,    // product exists in warehouse
    NoStock,    // not in warehouse, tray still has stock (dim label)
    NeedsSwap,  // not in warehouse AND tray empty
    Unknown,    // no warehouse data
}

data class TrayDeficit(
    val productName: String,
    val imagePath: String? = null,
    val deficit: Int,
    val severity: StockSeverity,
    val isDiscontinued: Boolean,
    val warehouseAvailability: WarehouseAvailability,
)

/** Enriched machine data with aggregated stats for display (pure UI state). */
data class MachineStats(
    val machine: VendingMachine,
    val todayRevenue: Double = 0.0,
    val todaySalesCount: Int = 0,
    val yesterdayRevenue: Double = 0.0,
    val yesterdaySalesCount: Int = 0,
    val thisWeekRevenue: Double = 0.0,
    val thisWeekSalesCount: Int = 0,
    val lastWeekRevenue: Double = 0.0,
    val lastWeekSalesCount: Int = 0,
    val paxcounterCount: Int? = null,
    val totalTrays: Int = 0,
    val lowTrays: Int = 0,
    val emptyTrays: Int = 0,
    val stockPercent: Double = 0.0,
    val swapNeededCount: Int = 0,
    val noStockCount: Int = 0,
    val trayDeficits: List<TrayDeficit> = emptyList(),
) {
    val id: String get() = machine.id

    val stockHealth: StockHealth
        get() = when {
            emptyTrays > 0 -> StockHealth.Critical
            lowTrays > 0 -> StockHealth.Low
            else -> StockHealth.Ok
        }

    /** Sort priority: critical first, then low (more low trays first), then ok. */
    val sortPriority: Int
        get() = when (stockHealth) {
            StockHealth.Critical -> 0
            StockHealth.Low -> 1000 - lowTrays
            StockHealth.Ok -> 2000
        }
}
