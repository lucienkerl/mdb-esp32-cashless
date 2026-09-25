package xyz.vmflow.ui.deals

import kotlinx.coroutines.runBlocking
import kotlinx.datetime.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.vmflow.data.DealGroup
import xyz.vmflow.data.DealListMode
import xyz.vmflow.data.DealStockTotals
import xyz.vmflow.data.DealUserState
import xyz.vmflow.data.DealsDataSource
import xyz.vmflow.models.Deal
import xyz.vmflow.models.DealSearchResponse
import xyz.vmflow.models.ProductPurchaseSummary

class DealsEngineTest {

    private val today = LocalDate(2026, 9, 25)

    private class FakeDeals(
        var enabled: Boolean = true,
        var response: DealSearchResponse = DealSearchResponse(),
        var states: Map<String, DealUserState> = emptyMap(),
        var failUpsert: Boolean = false,
        var failStates: Boolean = false,
    ) : DealsDataSource {
        val upserts = mutableListOf<List<String?>>()
        var lastForceRefresh: Boolean? = null

        override suspend fun fetchDealsEnabled() = enabled
        override suspend fun searchDeals(forceRefresh: Boolean): DealSearchResponse {
            lastForceRefresh = forceRefresh
            return response
        }
        override suspend fun fetchUserStates(): Map<String, DealUserState> {
            if (failStates) error("no deal_user_state table")
            return states
        }
        override suspend fun fetchNewDealKeys(): Set<String> = setOf("REWE::1")
        override suspend fun fetchPurchaseSummaries(productIds: List<String>): Map<String, ProductPurchaseSummary> = emptyMap()
        override suspend fun upsertUserState(retailer: String, offerId: String, archivedAt: String?, pinnedAt: String?) {
            if (failUpsert) error("network down")
            upserts += listOf(retailer, offerId, archivedAt, pinnedAt)
        }
        override suspend fun fetchStockTotals(productIds: List<String>): Map<String, DealStockTotals> =
            productIds.associateWith { DealStockTotals(warehouseQty = 3) }
    }

    private fun deal(offerId: String, from: String? = null) = Deal(
        id = offerId,
        retailer = "REWE",
        dealTitle = "Deal $offerId",
        validFrom = from,
        validUntil = "2026-10-10",
        offerId = offerId,
    )

    private fun engine(fake: FakeDeals) = DealsEngine(fake, today = { today }, now = { "2026-09-25T10:00:00Z" })

    @Test
    fun `loads deals, marks new ones and groups upcoming offers separately`() = runBlocking {
        val fake = FakeDeals(response = DealSearchResponse(deals = listOf(deal("1"), deal("2", from = "2026-09-28"))))
        val e = engine(fake)
        e.loadAll()
        val s = e.uiState.value
        assertTrue(s.dealsEnabled)
        assertEquals(false, fake.lastForceRefresh)
        assertTrue(s.isNew(s.deduped.first { it.offerId == "1" }))
        assertEquals(listOf(DealGroup.Kind.VALID_NOW, DealGroup.Kind.UPCOMING), s.groups.map { it.kind })
        assertEquals(1, s.upcomingCount)
    }

    @Test
    fun `disabled deal search never calls deal-search`() = runBlocking {
        val fake = FakeDeals(enabled = false)
        val e = engine(fake)
        e.loadAll()
        assertFalse(e.uiState.value.dealsEnabled)
        assertNull(fake.lastForceRefresh)
    }

    @Test
    fun `refresh forces a fresh provider fetch`() = runBlocking {
        val fake = FakeDeals()
        val e = engine(fake)
        e.loadAll()
        e.refresh()
        assertEquals(true, fake.lastForceRefresh)
        assertFalse(e.uiState.value.isRefreshing)
    }

    @Test
    fun `no-provider message is surfaced as its own state`() = runBlocking {
        val e = engine(FakeDeals(response = DealSearchResponse(message = "No deal-source providers enabled")))
        e.loadAll()
        assertTrue(e.uiState.value.noProviders)
    }

    @Test
    fun `a missing user-state table does not break the list`() = runBlocking {
        val e = engine(FakeDeals(response = DealSearchResponse(deals = listOf(deal("1"))), failStates = true))
        e.loadAll()
        assertEquals(1, e.uiState.value.filteredDeals.size)
        assertNull(e.uiState.value.error)
    }

    @Test
    fun `archive keeps the pin, moves the deal to the archived list and clears NEW`() = runBlocking {
        val fake = FakeDeals(
            response = DealSearchResponse(deals = listOf(deal("1"))),
            states = mapOf("REWE::1" to DealUserState(archivedAt = null, pinnedAt = "2026-09-20T08:00:00Z")),
        )
        val e = engine(fake)
        e.loadAll()
        e.archive(e.uiState.value.deduped.single())
        assertEquals(listOf("REWE", "1", "2026-09-25T10:00:00Z", "2026-09-20T08:00:00Z"), fake.upserts.single())
        val s = e.uiState.value
        assertTrue(s.visibleActiveDeals.isEmpty())
        assertEquals(1, s.archivedCount)
        assertFalse(s.isNew(s.deduped.single()))
        e.setListMode(DealListMode.ARCHIVED)
        assertEquals(1, e.uiState.value.filteredDeals.size)
    }

    @Test
    fun `a failed pin is rolled back and reported`() = runBlocking {
        val fake = FakeDeals(response = DealSearchResponse(deals = listOf(deal("1"))), failUpsert = true)
        val e = engine(fake)
        e.loadAll()
        e.pin(e.uiState.value.deduped.single())
        val s = e.uiState.value
        assertFalse(s.deduped.single().pinned)
        assertEquals("network down", s.error)
    }

    @Test
    fun `stock is loaded once per product`() = runBlocking {
        val e = engine(FakeDeals())
        e.loadStock(listOf("p1", "p2"))
        assertEquals(3, e.uiState.value.stock["p1"]?.warehouseQty)
        assertEquals(2, e.uiState.value.stock.size)
    }
}
