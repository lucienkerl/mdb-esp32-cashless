package xyz.vmflow.ui.refill

import xyz.vmflow.data.RefillTourLogic

/**
 * Everything one machine gets of one product on the packing list: the refill
 * of its slots and the units for its slot rebuilds, under one tick ("in the
 * box") and one amount ("3 refill + 5 rebuild · slot 57"). Ported from iOS
 * `PackLine`.
 *
 * @property refill units for the refill (0 when the product is not refilled
 *   here or the warehouse has nothing left for it).
 * @property refillNeed what the slots holding the product lack.
 * @property refillCapacity summed capacity of the product's slots, so the
 *   refiller can weigh "needs 2 / 15" before packing.
 * @property refillSlots the product's slots, each with its need — shown one
 *   by one when the product sits in several slots.
 * @property hasRefill the refill can be packed (it has stock or is already ticked).
 * @property rebuild units for slot rebuilds.
 * @property rebuildNeed what the rebuilt slots need from the warehouse.
 * @property slots the slots that get the product in a rebuild.
 * @property maxQuantity most units the line can pack (slot room and warehouse stock).
 */
data class PackLine(
    val machineId: String,
    val productId: String,
    val refill: Int,
    val refillNeed: Int,
    val refillCapacity: Int = 0,
    val refillSlots: List<PackSlotNeed> = emptyList(),
    val hasRefill: Boolean,
    val rebuild: Int,
    val rebuildNeed: Int,
    val slots: List<Int>,
    val ticked: Boolean,
    val maxQuantity: Int
) {
    val total: Int get() = refill + rebuild
    val need: Int get() = refillNeed + rebuildNeed
    val shortfall: Int get() = maxOf(0, need - total)

    /** Nothing to pack: the warehouse has nothing left for this line. */
    val isUnavailable: Boolean get() = !hasRefill && rebuildNeed == 0
}

/** One slot's share of a pack line's refill: what it lacks of its capacity. */
data class PackSlotNeed(val itemNumber: Int, val need: Int, val capacity: Int)

/** The product's slots (rebuilt ones left out), by slot number, with their need. */
fun RefillUiState.refillSlotNeeds(machineId: String, productId: String): List<PackSlotNeed> {
    val machine = machines.find { it.machine.id == machineId } ?: return emptyList()
    val group = RefillTourLogic.refillGroups(machine).firstOrNull { it.productId == productId } ?: return emptyList()
    return group.trays
        .map { PackSlotNeed(it.itemNumber, maxOf(0, it.capacity - it.currentStock), it.capacity) }
        .sortedBy { it.itemNumber }
}

/** What the machine's slots holding the product lack (the refill need). */
fun RefillUiState.refillNeed(machineId: String, productId: String): Int {
    val machine = machines.find { it.machine.id == machineId } ?: return 0
    return RefillTourLogic.refillGroups(machine).firstOrNull { it.productId == productId }?.deficit ?: 0
}

private fun RefillUiState.isRefillPacked(machineId: String, productId: String): Boolean =
    packedItems[machineId]?.contains(productId) == true

private fun RefillUiState.isRefillOutOfStock(machineId: String, productId: String): Boolean =
    RefillTourLogic.isOutOfStockForMachine(
        machines = machines,
        machineId = machineId,
        productId = productId,
        packedItems = packedItems,
        customQuantities = customQuantities,
        warehouseStock = packingStock,
        stockLoaded = stockLoaded
    )

/** Refill units the OTHER machines' ticked lines hold of a product. */
private fun RefillUiState.otherRefills(machineId: String, productId: String): Int =
    machines
        .filter { it.machine.id != machineId && packedItems[it.machine.id]?.contains(productId) == true }
        .sumOf { RefillTourLogic.packingQuantity(it, productId, customQuantities) }

/** The refill part of a line can be packed. */
fun RefillUiState.hasRefillLine(machineId: String, productId: String): Boolean =
    refillNeed(machineId, productId) > 0 &&
        (isRefillPacked(machineId, productId) || !isRefillOutOfStock(machineId, productId))

/** Ticked = every part of the line (refill, rebuild) lies in the box. */
fun RefillUiState.isLineTicked(machineId: String, productId: String): Boolean {
    val refill = hasRefillLine(machineId, productId)
    val rebuild = rebuildNeed(machineId, productId) > 0
    if (!refill && !rebuild) return false
    return (!refill || isRefillPacked(machineId, productId)) &&
        (!rebuild || isRebuildTaken(machineId, productId))
}

/**
 * Most rebuild units a machine can pack of a product: what its slots need,
 * within the stock the other machines' lines (refill and rebuild) leave.
 */
fun RefillUiState.maxRebuildQuantity(machineId: String, productId: String): Int {
    val need = rebuildNeed(machineId, productId)
    if (!stockLoaded) return need
    val others = rebuildCommitted.filterKeys { it != machineId }.values.sumOf { it[productId] ?: 0 }
    val available = (warehouseStock[productId] ?: 0) - others - otherRefills(machineId, productId)
    return minOf(need, available).coerceAtLeast(0)
}

/**
 * Rebuild units of a line: what is committed once ticked, otherwise what
 * would be packed (the dialled amount within what the warehouse can cover).
 */
fun RefillUiState.rebuildDisplayQuantity(machineId: String, productId: String): Int {
    if (isRebuildTaken(machineId, productId)) return rebuildCommitted[machineId]?.get(productId) ?: 0
    val need = rebuildNeed(machineId, productId)
    val wanted = minOf(rebuildCustomQuantities[machineId]?.get(productId) ?: need, need)
    return minOf(wanted, maxRebuildQuantity(machineId, productId))
}

/**
 * Refill units of a line. An unticked line also leaves room for its own
 * rebuild units, which claim the stock first once ticked.
 */
private fun RefillUiState.lineRefillQuantity(machineId: String, productId: String): Int {
    val qty = RefillTourLogic.displayQuantity(
        machines = machines,
        machineId = machineId,
        productId = productId,
        packedItems = packedItems,
        customQuantities = customQuantities,
        warehouseStock = packingStock,
        stockLoaded = stockLoaded
    )
    if (isRefillPacked(machineId, productId) || isRebuildTaken(machineId, productId) || !stockLoaded) return qty
    // `qty` is already within the slots' room; only the stock left over
    // (after the other machines and every ticked rebuild) shrinks by the
    // line's own rebuild units.
    val available = (packingStock[productId] ?: 0) - otherRefills(machineId, productId) -
        rebuildDisplayQuantity(machineId, productId)
    return minOf(qty, available).coerceAtLeast(0)
}

/**
 * Most units a line can pack: the room in its slots (refill) plus what the
 * rebuilt slots need, within the stock the other machines leave.
 */
private fun RefillUiState.lineMaxQuantity(machineId: String, productId: String, rebuildNeed: Int, hasRefill: Boolean): Int {
    var room = 0
    if (hasRefill) {
        val machine = machines.find { it.machine.id == machineId }
        if (machine != null) {
            val rebuildTrays = machine.rebuildTrayIds
            room = machine.trays
                .filter { it.tray.productId == productId && it.tray.id !in rebuildTrays }
                .sumOf { maxOf(0, it.tray.capacity - it.tray.currentStock) }
        }
    }
    if (!stockLoaded) return rebuildNeed + room
    val stock = warehouseStock[productId] ?: 0
    val otherRebuilds = rebuildCommitted.filterKeys { it != machineId }.values.sumOf { it[productId] ?: 0 }
    return minOf(rebuildNeed + room, stock - otherRefills(machineId, productId) - otherRebuilds).coerceAtLeast(0)
}

/** One machine's line of a product. */
fun RefillUiState.packLine(machineId: String, productId: String): PackLine {
    val rebuildNeed = rebuildNeed(machineId, productId)
    val hasRefill = hasRefillLine(machineId, productId)
    val machine = machines.find { it.machine.id == machineId }
    val refillSlots = refillSlotNeeds(machineId, productId)
    return PackLine(
        machineId = machineId,
        productId = productId,
        refill = if (hasRefill) lineRefillQuantity(machineId, productId) else 0,
        refillNeed = refillNeed(machineId, productId),
        refillCapacity = refillSlots.sumOf { it.capacity },
        refillSlots = refillSlots,
        hasRefill = hasRefill,
        rebuild = if (rebuildNeed > 0) rebuildDisplayQuantity(machineId, productId) else 0,
        rebuildNeed = rebuildNeed,
        slots = if (rebuildNeed > 0) {
            machine?.acceptedChangeItems.orEmpty()
                .filter { it.toProductId == productId }
                .map { it.itemNumber }
                .sorted()
        } else {
            emptyList()
        },
        ticked = isLineTicked(machineId, productId),
        maxQuantity = lineMaxQuantity(machineId, productId, rebuildNeed, hasRefill)
    )
}

/** Products a machine gets a refill or rebuild units of, refilled ones first. */
fun RefillUiState.lineProductIds(machineId: String): List<String> {
    val machine = machines.find { it.machine.id == machineId } ?: return emptyList()
    val ids = LinkedHashSet<String>()
    RefillTourLogic.refillGroups(machine).filter { it.deficit > 0 }.forEach { ids += it.productId }
    machine.acceptedChangeItems.mapNotNull { it.toProductId }.forEach { pid ->
        if (rebuildNeed(machineId, pid) > 0) ids += pid
    }
    return ids.toList()
}

/** Every line of one machine that can be packed. */
fun RefillUiState.packLines(machineId: String): List<PackLine> =
    lineProductIds(machineId).map { packLine(machineId, it) }.filter { !it.isUnavailable }

/** Units ticked into the box vs. all units on the packing list. */
val RefillUiState.packBox: Pair<Int, Int>
    get() {
        var packed = 0
        var total = 0
        for (machine in machines) {
            for (line in packLines(machine.machine.id)) {
                total += line.total
                if (line.ticked) packed += line.total
            }
        }
        return packed to total
    }

/** Lines with units that are not ticked — they stay in the warehouse when the tour starts. */
val RefillUiState.openPackLines: List<PackLine>
    get() = machines.flatMap { machine ->
        packLines(machine.machine.id).filter { !it.ticked && it.total > 0 }
    }

/** Machines with at least one line in the box. */
val RefillUiState.readyMachineCount: Int
    get() = machines.count { machine -> packLines(machine.machine.id).any { it.ticked } }
