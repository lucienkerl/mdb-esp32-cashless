package de.kerlhandel.vmflow.data.model

import kotlinx.serialization.Serializable

/** Step of the refill wizard. Indices match iOS. */
enum class RefillStep(val index: Int) {
    Review(0), Packing(1), Refill(2), Summary(3),
}

/** A machine that needs refilling, with its trays and packing state. */
@Serializable
data class RefillMachine(
    val machine: VendingMachine,
    val trays: List<RefillTray>,
    val isPacked: Boolean = false,
    val isRefilled: Boolean = false,
    val isSkipped: Boolean = false,
) {
    val id: String get() = machine.id
    val totalDeficit: Int get() = trays.sumOf { it.deficit }
    val traysNeedingRefill: Int get() = trays.count { it.deficit > 0 }
    val totalCurrentStock: Int get() = trays.sumOf { it.tray.currentStock }
    val totalCapacity: Int get() = trays.sumOf { it.tray.capacity }
    val stockPercent: Int get() = if (totalCapacity > 0) ((totalCurrentStock.toDouble() / totalCapacity) * 100).toInt() else 0
    val stockHealth: StockHealth
        get() = when {
            trays.any { it.tray.isEmpty } -> StockHealth.Critical
            trays.any { it.tray.isBelowMinStock } -> StockHealth.Low
            else -> StockHealth.Ok
        }
}

@Serializable
data class RefillTray(
    val tray: Tray,
    val fillAmount: Int,
    /** Whether this tray is included in the currently active refill tour. */
    val isInTour: Boolean = true,
) {
    val id: String get() = tray.id
    val deficit: Int get() = tray.deficit
    val targetStock: Int get() = tray.currentStock + fillAmount
}

data class PackingItem(
    val productId: String,
    val productName: String,
    val imagePath: String?,
    val sellprice: Double?,
    val quantity: Int,
)

data class CombinedPackingItem(
    val productId: String,
    val productName: String,
    val imagePath: String?,
    val sellprice: Double?,
    val totalQuantity: Int,
    val machineNeeds: List<MachineNeed>,
) {
    fun formattedSellprice(): String? = sellprice?.let { String.format("%.2f €", it) }
}

data class MachineNeed(
    val machineId: String,
    val machineName: String,
    val quantity: Int,
    val capacity: Int,
)

@Serializable
data class TourLogEntry(
    val machineId: String,
    val machineName: String,
    val traysRefilled: Int,
    val totalAdded: Int,
    val skipped: Boolean,
)

enum class ReplacementReason { Discontinued, Expired, NoStock, Unassigned }

data class ReplacementSuggestion(
    val trayId: String,
    val machineId: String,
    val machineName: String,
    val slotNumber: Int,
    val currentProductId: String? = null,
    val currentProductName: String,
    val currentProductImage: String?,
    val currentStock: Int,
    val reason: ReplacementReason,
    val replacementProductId: String? = null,
    val isSkipped: Boolean = false,
)
