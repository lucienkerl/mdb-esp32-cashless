package xyz.vmflow.data

import xyz.vmflow.models.Tray
import xyz.vmflow.models.VendingMachineWithEmbedded
import xyz.vmflow.models.WarehouseStockBatch

/**
 * Reason a tray surfaced in the pre-tour review step. Mirrors iOS
 * `ReplacementReason` (`RefillWizardViewModel.swift` L163-168).
 */
enum class ReplacementReason { DISCONTINUED, EXPIRED, NO_STOCK, UNASSIGNED }

/**
 * A tray that should be reviewed before packing — its product is
 * discontinued and sold out, expired, out of warehouse stock, or not
 * assigned at all. Mirrors iOS `ReplacementSuggestion`
 * (`RefillWizardViewModel.swift` L172-187).
 */
data class ReplacementSuggestion(
    val trayId: String,
    val machineId: String,
    val machineName: String,
    val slotNumber: Int,
    val currentProductId: String?,
    val currentProductName: String?,
    val currentProductImage: String?,
    val currentStock: Int,
    val reason: ReplacementReason,
    val replacementProductId: String? = null,
    val isSkipped: Boolean = false,
    /**
     * Set once this slot's replacement has been queued into the machine's
     * slot change request (`save_slot_change_request`, see
     * `RefillViewModel.applyReplacementsAndContinue`). The review never
     * writes `machine_trays` itself: the slot is rebuilt at the machine
     * during the tour, through the change note. Lets a retry after a partial
     * failure resume rather than restart. Never true for a freshly detected
     * suggestion; only ever set locally, never persisted.
     */
    val isApplied: Boolean = false,
)

/**
 * Pure detection logic for the refill wizard's review step: which slots
 * need a replacement product before the driver sets off, and why. Ported
 * 1:1 from `ios/VMflow/ViewModels/RefillWizardViewModel.swift` L1258-1351
 * (the suggestion-detection block inside `loadData`), with one deliberate
 * divergence: [buildReplacementSuggestions]'s result order is deterministic
 * (machine name, then slot number) rather than falling out of Supabase
 * fetch order — a list that reorders itself between recompositions is
 * unusable in a Compose UI.
 *
 * Nothing here touches coroutines, Supabase, Android, or a clock — `today`
 * arrives as a parameter into [expiredProductIds] so this stays pure and
 * unit-testable, same split as `RefillTourLogic.kt` / `WarehouseIntakeLogic.kt`.
 */
object RefillReviewLogic {

    /**
     * Products whose warehouse stock has fully expired. A product counts as
     * expired only when **every** batch with `quantity > 0` carries an
     * expiration date **and** every one of those dates is strictly before
     * [today]. A single batch with no date, or a future (or today's) date,
     * excludes the product from the set — it still has sellable stock.
     * Batches with `quantity == 0` are ignored entirely (mirrors the iOS
     * caller's `.gt("quantity", 0)` fetch filter), so a stale, dateless,
     * zero-quantity row can never block an otherwise-expired product.
     *
     * Date comparison is lexicographic string comparison on `YYYY-MM-DD`,
     * exactly as iOS does it (`RefillWizardViewModel.swift` L1296-1304) —
     * this only works because the format is fixed-width and
     * most-significant-first.
     */
    fun expiredProductIds(batches: List<WarehouseStockBatch>, today: String): Set<String> {
        return batches
            .filter { it.quantity > 0 }
            .groupBy { it.productId }
            .filterValues { productBatches ->
                productBatches.all { batch ->
                    val expirationDate = batch.expirationDate
                    !expirationDate.isNullOrEmpty() && expirationDate < today
                }
            }
            .keys
    }

    /**
     * Scans every machine's trays for replacement candidates. Reason
     * priority, first match wins (`RefillWizardViewModel.swift` L1316-1334):
     *   1. Product discontinued **and** tray stock is 0 -> [ReplacementReason.DISCONTINUED].
     *      A discontinued product with remaining stock produces no
     *      suggestion at all — the driver sells it out first.
     *   2. Product id is in [expiredProductIds] -> [ReplacementReason.EXPIRED],
     *      regardless of tray stock (even a full tray).
     *   3. Tray stock is 0 **and** the product has no warehouse stock
     *      ([stockedProductIds]) -> [ReplacementReason.NO_STOCK]. Suppressed
     *      entirely when [stockLoaded] is false — see its doc.
     *   4. Tray has no product assigned -> [ReplacementReason.UNASSIGNED].
     * Each tray yields at most one suggestion (the `if`/`else if` chain
     * below can only ever pick one reason). Result order is deterministic
     * (machine name, then slot number) — see class doc for why that departs
     * from iOS.
     *
     * `stockLoaded == false` means only rules 1, 2 and 4 apply — they don't
     * depend on warehouse stock. An empty [stockedProductIds] is otherwise
     * ambiguous: it means both "the warehouse stock query failed" and "the
     * warehouse genuinely stocks nothing", and treating the former as the
     * latter would fire rule 3 for every empty slot in the fleet on one
     * transient failure. Mirrors the `stockLoaded` parameter on
     * `RefillTourLogic`'s capping functions (`maxPackingQuantity`,
     * `isOutOfStockForMachine`), same "empty means unknown, not zero"
     * distinction.
     */
    fun buildReplacementSuggestions(
        machines: List<VendingMachineWithEmbedded>,
        traysByMachine: Map<String, List<Tray>>,
        stockedProductIds: Set<String>,
        expiredProductIds: Set<String>,
        stockLoaded: Boolean,
    ): List<ReplacementSuggestion> {
        val suggestions = mutableListOf<ReplacementSuggestion>()

        for (machine in machines) {
            val trays = traysByMachine[machine.id] ?: emptyList()
            for (tray in trays) {
                val productId = tray.productId
                val reason: ReplacementReason? = if (productId != null) {
                    val isDiscontinued = tray.products?.discontinued == true
                    when {
                        isDiscontinued && tray.currentStock == 0 -> ReplacementReason.DISCONTINUED
                        expiredProductIds.contains(productId) -> ReplacementReason.EXPIRED
                        stockLoaded && tray.currentStock == 0 && !stockedProductIds.contains(productId) ->
                            ReplacementReason.NO_STOCK
                        else -> null
                    }
                } else {
                    ReplacementReason.UNASSIGNED
                }

                if (reason != null) {
                    suggestions.add(
                        ReplacementSuggestion(
                            trayId = tray.id,
                            machineId = machine.id,
                            machineName = machine.displayName,
                            slotNumber = tray.itemNumber,
                            currentProductId = tray.productId,
                            currentProductName = tray.products?.name,
                            currentProductImage = tray.products?.imagePath,
                            currentStock = tray.currentStock,
                            reason = reason,
                            // An empty slot (e.g. emptied by a slot change)
                            // must not hold up the review: it starts as
                            // "stays unassigned", assigning stays possible.
                            isSkipped = reason == ReplacementReason.UNASSIGNED,
                        )
                    )
                }
            }
        }

        // trayId is the final tiebreaker so this is a TOTAL order. Machine
        // names are not unique in the schema, and two same-named machines
        // each contributing the same slot number would otherwise tie — and a
        // stable sort resolves ties by input order, which is the fetch order
        // this deterministic sort exists to stop depending on.
        return suggestions.sortedWith(
            compareBy({ it.machineName }, { it.slotNumber }, { it.trayId })
        )
    }
}
