package xyz.vmflow.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.json.Json
import xyz.vmflow.models.PersistedTourState
import xyz.vmflow.models.RefillMachine
import xyz.vmflow.models.RefillStep
import xyz.vmflow.models.RefillTray
import xyz.vmflow.models.TourLogEntry
import xyz.vmflow.models.Tray
import xyz.vmflow.models.VendingMachineWithEmbedded

/**
 * Port of the tour half of
 * `management-frontend/app/lib/__tests__/slotChange.test.ts`
 * (`rebuildPackNeeds`, `fillPlan`, `computeLeftovers`) plus the Android
 * tour glue in [SlotChange]. Same fixtures and numbers as the web tests, so
 * the three clients can't drift apart.
 */
class SlotChangeTest {

    private fun item(
        id: String,
        tray: String,
        from: String?,
        to: String?,
        fromCap: Int,
        toCap: Int
    ) = SlotChangeItem(
        id = id,
        trayId = tray,
        itemNumber = tray.drop(1).toInt(),
        fromProductId = from,
        toProductId = to,
        fromCapacity = fromCap,
        toCapacity = toCap
    )

    private fun done(removed: Int, filled: Int) = ItemOutcome(RebuildAction.DONE, removed, filled)

    // ── tour: packing ────────────────────────────────────────────────────

    @Test
    fun `packs the new slots minus what moves over from changed slots`() {
        // Doppelbelegung: schorle -> cola (10)
        val items = listOf(item("i12", "t12", "schorle", "cola", 10, 10))
        assertEquals(mapOf("cola" to 10), SlotChange.rebuildPackNeeds(items, mapOf("t12" to 8)))
    }

    @Test
    fun `a neighbour swap needs nothing from the warehouse when stock covers it`() {
        val items = listOf(
            item("i16", "t16", "balisto", "duplo", 12, 12),
            item("i17", "t17", "duplo", "balisto", 14, 14)
        )
        val stock = mapOf("t16" to 10, "t17" to 12)
        // duplo needs 12, 12 come out of slot 17 -> 0; balisto needs 14, 10 come out of 16 -> 4
        assertEquals(mapOf("duplo" to 0, "balisto" to 4), SlotChange.rebuildPackNeeds(items, stock))
    }

    @Test
    fun `a smaller spiral for the same product needs nothing extra`() {
        val items = listOf(item("i16", "t16", "pringles", "pringles", 8, 6))
        assertEquals(mapOf("pringles" to 1), SlotChange.rebuildPackNeeds(items, mapOf("t16" to 5)))
        assertEquals(mapOf("pringles" to 0), SlotChange.rebuildPackNeeds(items, mapOf("t16" to 8)))
    }

    @Test
    fun `emptying a slot packs nothing`() {
        val items = listOf(item("i14", "t14", "tictac", null, 15, 15))
        assertEquals(emptyMap<String, Int>(), SlotChange.rebuildPackNeeds(items, mapOf("t14" to 14)))
    }

    // ── tour: at the machine ─────────────────────────────────────────────

    @Test
    fun `fills moved stock first, then van stock`() {
        val items = listOf(
            item("i16", "t16", "balisto", "duplo", 12, 12),
            item("i17", "t17", "duplo", "balisto", 14, 14)
        )
        // a duplo sold since packing: 11 come out of 17
        val removed = mapOf("i16" to 10, "i17" to 11)
        val plan = SlotChange.fillPlan(items, removed, mapOf("balisto" to 4, "duplo" to 0))
        assertEquals(FillSuggestion(moved = 11, van = 0, total = 11), plan["i16"])
        assertEquals(FillSuggestion(moved = 10, van = 4, total = 14), plan["i17"])
    }

    @Test
    fun `an emptied slot gets no fill`() {
        val items = listOf(item("i14", "t14", "tictac", null, 15, 15))
        val plan = SlotChange.fillPlan(items, mapOf("i14" to 14), emptyMap())
        assertEquals(FillSuggestion(0, 0, 0), plan["i14"])
    }

    @Test
    fun `leftovers split into van goods and goods from the machine`() {
        val items = listOf(
            item("i12", "t12", "schorle", "cola", 10, 10),
            item("i13", "t13", "redbull", "redbull", 8, 6)
        )
        val outcome = mapOf("i12" to done(7, 7), "i13" to done(8, 6))
        val left = SlotChange.computeLeftovers(items, outcome, mapOf("cola" to 10))
        assertEquals(Leftover(van = 3, machine = 0), left["cola"])
        assertEquals(Leftover(van = 0, machine = 7), left["schorle"])
        assertEquals(Leftover(van = 0, machine = 2), left["redbull"])
    }

    @Test
    fun `a skipped slot returns everything packed for it`() {
        val items = listOf(item("i12", "t12", "schorle", "cola", 10, 10))
        val left = SlotChange.computeLeftovers(
            items,
            mapOf("i12" to ItemOutcome(RebuildAction.SKIP, 0, 0)),
            mapOf("cola" to 10)
        )
        assertEquals(Leftover(van = 10, machine = 0), left["cola"])
        assertFalse(left.containsKey("schorle"))
    }

    @Test
    fun `a swap where everything moves leaves nothing over`() {
        val items = listOf(
            item("i16", "t16", "balisto", "duplo", 12, 12),
            item("i17", "t17", "duplo", "balisto", 14, 14)
        )
        val outcome = mapOf("i16" to done(10, 11), "i17" to done(11, 14))
        val left = SlotChange.computeLeftovers(items, outcome, mapOf("balisto" to 4))
        assertTrue(left.isEmpty())
    }

    @Test
    fun `price change is flagged only when the new product costs something else`() {
        val base = item("i12", "t12", "schorle", "cola", 10, 10)
        assertTrue(base.copy(fromPrice = 1.8, toPrice = 2.0).hasPriceChange)
        assertFalse(base.copy(fromPrice = 2.5, toPrice = 2.5).hasPriceChange)
        assertFalse(base.copy(toProductId = null, fromPrice = 1.0, toPrice = null).hasPriceChange)
    }

    // ── tour glue ────────────────────────────────────────────────────────

    @Test
    fun `rebuild gets first claim on limited warehouse stock, in tour order`() {
        val committed = SlotChange.commitRebuild(
            needsByMachine = listOf(
                "m1" to mapOf("cola" to 10, "duplo" to 0),
                "m2" to mapOf("cola" to 6)
            ),
            warehouseStock = mapOf("cola" to 12),
            stockLoaded = true
        )
        assertEquals(mapOf("m1" to mapOf("cola" to 10), "m2" to mapOf("cola" to 2)), committed)
        assertEquals(
            mapOf("cola" to 0, "water" to 5),
            SlotChange.stockAfterRebuild(mapOf("cola" to 12, "water" to 5), committed)
        )
    }

    @Test
    fun `without loaded stock the rebuild is not capped`() {
        val committed = SlotChange.commitRebuild(
            needsByMachine = listOf("m1" to mapOf("cola" to 10)),
            warehouseStock = emptyMap(),
            stockLoaded = false
        )
        assertEquals(mapOf("m1" to mapOf("cola" to 10)), committed)
    }

    @Test
    fun `the driver can pack fewer rebuild units, never more than the need`() {
        val committed = SlotChange.commitRebuild(
            needsByMachine = listOf(
                "m1" to mapOf("cola" to 10),
                "m2" to mapOf("cola" to 6)
            ),
            warehouseStock = mapOf("cola" to 30),
            stockLoaded = true,
            // half a spiral in m1, an overshoot in m2 is capped at the need
            custom = mapOf("m1" to mapOf("cola" to 5), "m2" to mapOf("cola" to 99))
        )
        assertEquals(mapOf("m1" to mapOf("cola" to 5), "m2" to mapOf("cola" to 6)), committed)

        val zero = SlotChange.commitRebuild(
            needsByMachine = listOf("m1" to mapOf("cola" to 10)),
            warehouseStock = emptyMap(),
            stockLoaded = false,
            custom = mapOf("m1" to mapOf("cola" to 0))
        )
        assertEquals(emptyMap<String, Map<String, Int>>(), zero)
    }

    @Test
    fun `the rebuild stepper is capped by the stock the other machines leave`() {
        val committed = mapOf("m1" to mapOf("cola" to 10), "m2" to mapOf("cola" to 2))
        assertEquals(10, SlotChange.maxRebuildQuantity(10, "m1", "cola", committed, mapOf("cola" to 12), true))
        assertEquals(2, SlotChange.maxRebuildQuantity(6, "m2", "cola", committed, mapOf("cola" to 12), true))
        assertEquals(0, SlotChange.maxRebuildQuantity(6, "m2", "mate", committed, emptyMap(), true))
        assertEquals(6, SlotChange.maxRebuildQuantity(6, "m2", "cola", committed, emptyMap(), false))
    }

    @Test
    fun `one deduction per machine and product, normal plus rebuild`() {
        // web useRefillWizard.rebuild.test: 8 cola for the refill + 10 for the rebuild = one deduction of 18
        val merged = SlotChange.mergeDeductions(
            normal = listOf(PackedDeduction("m1", "cola", 8), PackedDeduction("m2", "water", 3)),
            rebuildPacked = mapOf("m1" to mapOf("cola" to 10, "duplo" to 4))
        )
        assertEquals(
            listOf(
                PackedDeduction("m1", "cola", 18),
                PackedDeduction("m2", "water", 3),
                PackedDeduction("m1", "duplo", 4)
            ),
            merged
        )
    }

    @Test
    fun `rebuild cards default to the live stock and follow the fill plan`() {
        val items = listOf(
            item("i16", "t16", "balisto", "duplo", 12, 12),
            item("i17", "t17", "duplo", "balisto", 14, 14)
        )
        val slots = SlotChange.startRebuild(items, mapOf("t16" to 10, "t17" to 11), mapOf("balisto" to 4))
        assertEquals(listOf(10, 11), slots.map { it.removed })
        assertEquals(listOf(11, 14), slots.map { it.filled })

        // A typed fill survives a recompute; a skipped slot stops giving stock.
        val typed = slots.map { if (it.item.id == "i16") it.copy(filled = 9, filledTouched = true) else it }
        val skipped = typed.map { if (it.item.id == "i16") it.copy(action = RebuildAction.SKIP) else it }
        val again = SlotChange.recomputeFill(skipped, mapOf("balisto" to 4))
        assertEquals(9, again.first { it.item.id == "i16" }.filled)
        // i17 no longer gets the 10 balisto out of slot 16, only the van's 4
        assertEquals(4, again.first { it.item.id == "i17" }.filled)
    }

    @Test
    fun `leftover panel counts undecided slots as rebuilt`() {
        val items = listOf(item("i12", "t12", "schorle", "cola", 10, 10))
        val slots = SlotChange.startRebuild(items, mapOf("t12" to 8), mapOf("cola" to 10))
        val left = SlotChange.leftovers(slots, mapOf("cola" to 10))
        assertEquals(listOf(Triple("schorle", 0, 8)), left.map { Triple(it.productId, it.van, it.machine) })

        val skipped = SlotChange.leftovers(slots.map { it.copy(action = RebuildAction.SKIP) }, mapOf("cola" to 10))
        assertEquals(listOf(Triple("cola", 10, 0)), skipped.map { Triple(it.productId, it.van, it.machine) })
    }

    // ── persistence (resume) ─────────────────────────────────────────────

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `a resumed tour keeps the change note decisions and the rebuild units`() {
        val machine = RefillMachine(
            machine = VendingMachineWithEmbedded(id = "m1", name = "Foyer"),
            trays = listOf(RefillTray(tray = Tray(id = "t12", machineId = "m1", itemNumber = 12), fillAmount = 0)),
            isPacked = true,
            changeRequest = SlotChangeRequest(
                id = "r1",
                machineId = "m1",
                items = listOf(
                    item("i12", "t12", "schorle", "cola", 10, 10).copy(
                        toProduct = SlotChangeProductRef(name = "Cola", imagePath = "cola.png"),
                        toPrice = 2.0
                    ),
                    item("i13", "t13", "redbull", null, 8, 8).copy(accepted = false)
                )
            ),
            rebuildPacked = mapOf("cola" to 10)
        )
        val state = PersistedTourState(
            step = RefillStep.REFILL,
            machines = listOf(machine),
            currentMachineIndex = 0,
            selectedWarehouseId = "w1",
            tourId = "tour-1",
            tourLog = listOf(TourLogEntry("m0", "Lobby", 2, 9, skipped = false, slotsRebuilt = 1)),
            savedAt = "2026-10-08T12:00:00Z"
        )
        val restored = json.decodeFromString<PersistedTourState>(json.encodeToString(state))
        assertEquals(state, restored)
        assertEquals(setOf("t12"), restored.machines.single().rebuildTrayIds)
    }

    @Test
    fun `a tour saved before change notes existed still decodes`() {
        val old = """{"step":"REFILL","machines":[{"machine":{"id":"m1"},"trays":[]}],""" +
            """"currentMachineIndex":0,"selectedWarehouseId":null,"tourId":"t","savedAt":"x",""" +
            """"tourLog":[{"machineId":"m1","machineName":"A","traysRefilled":1,"totalAdded":2,"skipped":false}]}"""
        val restored = json.decodeFromString<PersistedTourState>(old)
        assertEquals(null, restored.machines.single().changeRequest)
        assertEquals(emptyMap<String, Int>(), restored.machines.single().rebuildPacked)
        assertEquals(0, restored.tourLog.single().slotsRebuilt)
    }

    @Test
    fun `change items decode from the PostgREST shape with the product joins`() {
        val row = """{"id":"i1","request_id":"r1","tray_id":"t1","item_number":12,""" +
            """"from_product_id":"p1","to_product_id":null,"from_capacity":10,"to_capacity":8,""" +
            """"from_price":1.5,"to_price":null,"skip_count":2,""" +
            """"from_product":{"name":"Schorle","image_path":"s.png"},"to_product":null}"""
        val decoded = json.decodeFromString<SlotChangeItem>(row)
        assertEquals("Schorle", decoded.fromName)
        assertEquals(null, decoded.toProductId)
        assertTrue(decoded.accepted)
        assertTrue(decoded.capacityChanges)
        assertFalse(decoded.hasPriceChange)
    }

    // ─── age restriction (web `ageChanged`) ───

    @Test
    fun `age setting changes only when the restriction differs, null-aware`() {
        val base = item("i12", "t12", "schorle", "beer", 10, 10)
        assertTrue(base.copy(fromMinAge = null, toMinAge = 18).ageChanged)
        assertTrue(base.copy(fromMinAge = 16, toMinAge = 18).ageChanged)
        assertTrue(base.copy(fromMinAge = 18, toMinAge = null).ageChanged)
        assertFalse(base.copy(fromMinAge = null, toMinAge = null).ageChanged)
        assertFalse(base.copy(fromMinAge = 18, toMinAge = 18).ageChanged)
    }

    @Test
    fun `age snapshot decodes, and rows without it mean no restriction`() {
        val withAge = json.decodeFromString<SlotChangeItem>(
            """{"id":"i1","tray_id":"t1","item_number":12,"from_capacity":10,"to_capacity":10,""" +
                """"to_product_id":"p2","from_min_age":null,"to_min_age":18}"""
        )
        assertEquals(18, withAge.toMinAge)
        assertTrue(withAge.ageChanged)
        val old = json.decodeFromString<SlotChangeItem>(
            """{"id":"i1","tray_id":"t1","item_number":12,"from_capacity":10,"to_capacity":10}"""
        )
        assertFalse(old.ageChanged)
    }

    @Test
    fun `rebuilt needs the age confirmation, not rebuilt does not`() {
        val slot = RebuildSlot(item = item("i12", "t12", "schorle", "beer", 10, 10).copy(toMinAge = 18), liveStock = 3, removed = 3)
        assertTrue(slot.needsAgeConfirmation)
        assertEquals(null, SlotChange.withAction(slot, RebuildAction.DONE).action)
        assertEquals(RebuildAction.SKIP, SlotChange.withAction(slot, RebuildAction.SKIP).action)
        assertFalse(SlotChange.ageSetPayload(SlotChange.withAction(slot, RebuildAction.SKIP)))

        val confirmed = SlotChange.withAgeSet(slot, true)
        val done = SlotChange.withAction(confirmed, RebuildAction.DONE)
        assertEquals(RebuildAction.DONE, done.action)
        assertTrue(SlotChange.ageSetPayload(done))

        // Unticking after "rebuilt" puts the slot back to undecided.
        val unticked = SlotChange.withAgeSet(done, false)
        assertEquals(null, unticked.action)
        assertFalse(SlotChange.ageSetPayload(unticked))
        // A skipped slot stays skipped when the tick changes.
        assertEquals(RebuildAction.SKIP, SlotChange.withAgeSet(slot.copy(action = RebuildAction.SKIP), false).action)
    }

    @Test
    fun `a slot without age change is rebuilt freely and sends age_set false`() {
        val slot = RebuildSlot(item = item("i12", "t12", "schorle", "cola", 10, 10), liveStock = 3, removed = 3)
        assertFalse(slot.needsAgeConfirmation)
        val done = SlotChange.withAction(slot, RebuildAction.DONE)
        assertEquals(RebuildAction.DONE, done.action)
        assertFalse(SlotChange.ageSetPayload(done))
    }

    @Test
    fun `rebuilt needs the price confirmation and unticking it takes the decision back`() {
        val slot = RebuildSlot(item = item("i12", "t12", "schorle", "cola", 10, 10).copy(fromPrice = 1.8, toPrice = 2.0), liveStock = 3, removed = 3)
        assertTrue(slot.needsPriceConfirmation)
        assertEquals(null, SlotChange.withAction(slot, RebuildAction.DONE).action)
        val done = SlotChange.withAction(SlotChange.withPriceSet(slot, true), RebuildAction.DONE)
        assertEquals(RebuildAction.DONE, done.action)
        assertEquals(null, SlotChange.withPriceSet(done, false).action)
        assertEquals(RebuildAction.SKIP, SlotChange.withPriceSet(slot.copy(action = RebuildAction.SKIP), false).action)
    }

    @Test
    fun `rebuild stock goes to the lines in the order they were ticked`() {
        val ticks = listOf(
            RebuildTick("m1", "cola", need = 8, seq = 2, index = 0),
            RebuildTick("m2", "cola", need = 8, seq = 1, index = 1)
        )
        val out = SlotChange.commitRebuildInTickOrder(ticks, mapOf("cola" to 10), true, emptyMap(), emptyMap())
        // m2 was ticked first and gets its 8; m1 only what is left.
        assertEquals(8, out["m2"]?.get("cola"))
        assertEquals(2, out["m1"]?.get("cola"))
        // Other machines' refills are taken; a custom amount is honoured.
        val withRefill = SlotChange.commitRebuildInTickOrder(
            ticks, mapOf("cola" to 10), true, mapOf("m2" to mapOf("cola" to 3)), mapOf("cola" to mapOf("m1" to 4))
        )
        assertEquals(3, withRefill["m2"]?.get("cola"))
        assertEquals(7, withRefill["m1"]?.get("cola"))
        // Without loaded stock nothing is restricted.
        val unloaded = SlotChange.commitRebuildInTickOrder(ticks, emptyMap(), false, emptyMap(), emptyMap())
        assertEquals(8, unloaded["m1"]?.get("cola"))
    }

    @Test
    fun `a slot is filled at most with moved and packed units`() {
        val slots = listOf(
            RebuildSlot(item = item("i12", "t12", "schorle", "cola", 10, 8), liveStock = 0, removed = 0),
            RebuildSlot(item = item("i13", "t13", "cola", "mate", 10, 10), liveStock = 5, removed = 5)
        )
        // 5 cola come out of slot 13, 2 were packed: at most 7 of the 8.
        assertEquals(7, SlotChange.maxRebuildFilled(slots, "i12", mapOf("cola" to 2)))
        // Never more than the new spiral.
        assertEquals(8, SlotChange.maxRebuildFilled(slots, "i12", mapOf("cola" to 10)))
        // Slot 13 skipped today: its cola stays put, and slot 12 learns why.
        val skipped = slots.map { if (it.item.id == "i13") it.copy(action = RebuildAction.SKIP) else it }
        assertEquals(2, SlotChange.maxRebuildFilled(skipped, "i12", mapOf("cola" to 2)))
        assertEquals(listOf(13), SlotChange.skippedSourceSlots(skipped, "i12"))
        assertEquals(emptyList<Int>(), SlotChange.skippedSourceSlots(slots, "i12"))
    }

    @Test
    fun `a withdrawn change note rebuilds nothing`() {
        val slots = listOf(
            RebuildSlot(item = item("i12", "t12", "schorle", "cola", 10, 10), liveStock = 3, removed = 3, filled = 8, action = RebuildAction.DONE)
        )
        val out = SlotChange.withdrawn(slots).single()
        assertEquals(RebuildAction.SKIP, out.action)
        assertEquals(0, out.removed)
        assertEquals(0, out.filled)
    }

    // ─── queueReplacement (useMachineAnalysis.applySwap merge) ───

    private fun pendingItem(trayId: String, toProductId: String?, toCapacity: Int) = SlotChangeItem(
        id = "i-$trayId", trayId = trayId, itemNumber = 10, fromProductId = "a", toProductId = toProductId,
        fromCapacity = 8, toCapacity = toCapacity, fromPrice = null, toPrice = null, skipCount = 0,
        fromProduct = null, toProduct = null
    )

    @Test
    fun `queueReplacement keeps other pending items and adds the slot with its tray capacity`() {
        val plan = SlotChange.queueReplacement(listOf(pendingItem("t1", "x", 6)), "t2", "y", 9)
        assertEquals(listOf(PlannedChange("t1", "x", 6), PlannedChange("t2", "y", 9)), plan)
    }

    @Test
    fun `queueReplacement replaces the product of a pending slot but keeps its planned capacity`() {
        val plan = SlotChange.queueReplacement(listOf(pendingItem("t1", "x", 6)), "t1", "y", 9)
        assertEquals(listOf(PlannedChange("t1", "y", 6)), plan)
    }

    @Test
    fun `queueReplacement without an open request plans just that slot`() {
        assertEquals(listOf(PlannedChange("t3", "z", 12)), SlotChange.queueReplacement(emptyList(), "t3", "z", 12))
    }

    // ── tour end: leftovers booked at the warehouse ──────────────────────

    @Test
    fun `tour leftovers add up per product across machines, earliest best-before wins`() {
        val byMachine = linkedMapOf(
            "m1" to listOf(
                TourLeftover("schorle", "Schorle", "s.png", van = 0, machine = 8, suggestedExpiry = "2027-03-01"),
                TourLeftover("cola", "Cola", null, van = 2, machine = 0)
            ),
            "m2" to listOf(
                TourLeftover("schorle", null, null, van = 1, machine = 4, suggestedExpiry = "2027-01-15"),
                TourLeftover("water", "Wasser", null, van = 0, machine = 0)
            )
        )
        val out = SlotChange.aggregateTourLeftovers(byMachine)
        assertEquals(listOf("schorle", "cola"), out.map { it.productId })
        assertEquals(TourLeftover("schorle", "Schorle", "s.png", van = 1, machine = 12, suggestedExpiry = "2027-01-15"), out[0])
        assertEquals(TourLeftover("cola", "Cola", null, van = 2, machine = 0), out[1])
    }

    @Test
    fun `the return payload takes the counted quantities and skips products counted to zero`() {
        val aggregated = listOf(
            TourLeftover("schorle", van = 1, machine = 12, suggestedExpiry = "2027-01-15"),
            TourLeftover("cola", van = 2, machine = 0),
            TourLeftover("mate", van = 3, machine = 1, suggestedExpiry = "2027-02-01")
        )
        val payload = SlotChange.tourReturnPayload(
            aggregated = aggregated,
            vanQty = mapOf("schorle" to 0, "cola" to 0),
            machineQty = mapOf("schorle" to 10, "cola" to 0),
            destinations = mapOf("mate" to LeftoverDestination.WASTE),
            expiry = emptyMap(),
            batchNumber = "Rückgabe aus Automat"
        )
        assertEquals(
            listOf(
                SlotChangeLeftoverPayload("schorle", 0, 10, LeftoverDestination.WAREHOUSE, "2027-01-15", "Rückgabe aus Automat"),
                // Written off: no best-before date travels with it.
                SlotChangeLeftoverPayload("mate", 3, 1, LeftoverDestination.WASTE, null, "Rückgabe aus Automat")
            ),
            payload
        )
    }

    @Test
    fun `a best-before date set by the refiller wins, a blank one means none`() {
        val aggregated = listOf(
            TourLeftover("a", machine = 2, suggestedExpiry = "2027-01-15"),
            TourLeftover("b", machine = 2, suggestedExpiry = "2027-01-15"),
            TourLeftover("c", van = 2, machine = 0, suggestedExpiry = "2027-01-15")
        )
        val payload = SlotChange.tourReturnPayload(
            aggregated, emptyMap(), emptyMap(), emptyMap(),
            expiry = mapOf("a" to "2026-12-24", "b" to ""),
            batchNumber = null
        )
        assertEquals(listOf("2026-12-24", null, null), payload.map { it.expirationDate })
    }

    @Test
    fun `a skipped machine leaves every packed rebuild unit in the van`() {
        val slots = SlotChange.startRebuild(
            listOf(item("i12", "t12", "schorle", "cola", 10, 10), item("i13", "t13", "cola", "mate", 8, 8)),
            mapOf("t12" to 6, "t13" to 3),
            packed = mapOf("cola" to 4, "mate" to 8)
        ).map { it.copy(action = RebuildAction.SKIP) }
        val left = SlotChange.leftovers(slots, mapOf("cola" to 4, "mate" to 8))
        assertEquals(mapOf("cola" to (4 to 0), "mate" to (8 to 0)), left.associate { it.productId to (it.van to it.machine) })
    }

    @Test
    fun `a resumed tour keeps its leftovers and whether they were booked`() {
        val state = PersistedTourState(
            step = RefillStep.SUMMARY,
            machines = emptyList(),
            currentMachineIndex = 0,
            selectedWarehouseId = "w1",
            tourId = "tour-1",
            tourLog = emptyList(),
            savedAt = "2026-10-10T12:00:00Z",
            tourLeftovers = mapOf("m1" to listOf(TourLeftover("cola", "Cola", null, van = 2, machine = 3, suggestedExpiry = "2027-01-01"))),
            leftoversReturned = true
        )
        assertEquals(state, json.decodeFromString<PersistedTourState>(json.encodeToString(state)))

        val old = """{"step":"SUMMARY","machines":[],"currentMachineIndex":0,"selectedWarehouseId":null,""" +
            """"tourId":"t","savedAt":"x","tourLog":[]}"""
        val restored = json.decodeFromString<PersistedTourState>(old)
        assertEquals(emptyMap<String, List<TourLeftover>>(), restored.tourLeftovers)
        assertFalse(restored.leftoversReturned)
    }

    // ── history: rebuilt slots in the stock_refill_tour row ──────────────

    @Test
    fun `rebuilt lines list every slot quit as rebuilt with something filled in`() {
        val cola = SlotChangeProductRef(name = "Bacardi Limon")
        val slots = listOf(
            RebuildSlot(item("i14", "t14", "schorle", "cola", 10, 8).copy(toProduct = cola), liveStock = 0, removed = 0, filled = 8, action = RebuildAction.DONE),
            RebuildSlot(item("i12", "t12", "schorle", "cola", 10, 5).copy(toProduct = cola), liveStock = 0, removed = 0, filled = 5, action = RebuildAction.DONE),
            RebuildSlot(item("i13", "t13", "x", "cola", 10, 5), liveStock = 0, removed = 0, filled = 5, action = RebuildAction.SKIP),
            RebuildSlot(item("i15", "t15", "x", "cola", 10, 5), liveStock = 0, removed = 0, filled = 0, action = RebuildAction.DONE),
            RebuildSlot(item("i16", "t16", "x", null, 10, 5), liveStock = 0, removed = 3, filled = 0, action = RebuildAction.DONE)
        )
        assertEquals(
            listOf(
                RebuiltSlotLine("cola", "Bacardi Limon", 5, 12),
                RebuiltSlotLine("cola", "Bacardi Limon", 8, 14)
            ),
            SlotChange.rebuiltLines(slots)
        )
    }

    // ── pack step: rebuild units in the normal packing list ──────────────

    @Test
    fun `rebuild pack rows sum the machines in scope and leave out what only moves`() {
        val items = listOf(
            item("i12", "t12", "schorle", "cola", 10, 10).copy(toProduct = SlotChangeProductRef("Cola", "cola.png")),
            item("i13", "t13", "cola", "mate", 8, 8).copy(toProduct = SlotChangeProductRef("Mate"))
        )
        val rows = SlotChange.rebuildPackRows(
            needsByMachine = listOf(
                "m1" to mapOf("cola" to 4, "mate" to 8, "duplo" to 0),
                "m2" to mapOf("cola" to 6)
            ),
            committed = mapOf("m1" to mapOf("cola" to 4, "mate" to 5), "m2" to mapOf("cola" to 6)),
            items = items
        )
        assertEquals(
            listOf(
                RebuildPackRow("cola", "Cola", "cola.png", need = 10, committed = 10),
                RebuildPackRow("mate", "Mate", null, need = 8, committed = 5)
            ),
            rows
        )
    }

    @Test
    fun `rebuild-only lines slot into the warehouse walk without moving the normal ones`() {
        data class Line(val id: String, val name: String?, val qty: Int)
        val normal = listOf(Line("a", "Apfel", 3), Line("c", "Cola", 9), Line("x", "Xtra", 1))
        val rebuild = listOf(Line("b", "Bier", 2), Line("z", "Zitrone", 5))
        val pickOrder = mapOf("a" to 0, "b" to 1, "c" to 2, "x" to 3)
        val sorted = SlotChange.sortForPacking(
            normal + rebuild, pickOrder, { it.id }, { it.name }, { it.qty }, nullsLast(naturalOrder())
        )
        // `z` has no warehouse position: after every positioned line.
        assertEquals(listOf("a", "b", "c", "x", "z"), sorted.map { it.id })

        // Without a walk order: quantity first, like the packing list itself.
        val byQty = SlotChange.sortForPacking(
            normal + rebuild, emptyMap(), { it.id }, { it.name }, { it.qty }, nullsLast(naturalOrder())
        )
        assertEquals(listOf("c", "z", "a", "b", "x"), byQty.map { it.id })
    }
}
