package xyz.vmflow.data

import kotlinx.datetime.LocalDate
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.vmflow.models.Deal
import xyz.vmflow.models.DealProduct
import xyz.vmflow.models.DealSearchResponse
import xyz.vmflow.models.ProductPurchaseSummary

class DealsLogicTest {

    // Fri 25.09.2026
    private val today = LocalDate(2026, 9, 25)

    private fun deal(
        offerId: String,
        retailer: String = "REWE",
        from: String? = null,
        until: String? = null,
        discount: Double? = null,
        productId: String? = null,
        productName: String? = null,
        confidence: Double = 0.9,
        price: Double? = 0.99,
    ) = Deal(
        id = "$offerId-$productId",
        productId = productId,
        retailer = retailer,
        dealTitle = "Deal $offerId",
        dealPrice = price,
        discountPct = discount,
        validFrom = from,
        validUntil = until,
        confidence = confidence,
        offerId = offerId,
        products = productName?.let { DealProduct(id = productId, name = it) },
    )

    // ── Validity ──

    @Test
    fun `a deal starting on a later day is upcoming with the day distance`() {
        val v = DealValidityLogic.validity("2026-09-28", "2026-10-03", today)
        assertEquals(DealValidityStatus.UPCOMING, v.status)
        assertEquals(3, v.startsInDays)
        assertFalse(v.isValidToday)
    }

    @Test
    fun `a deal starting today is valid today`() {
        val v = DealValidityLogic.validity("2026-09-25", "2026-10-03", today)
        assertEquals(DealValidityStatus.ACTIVE, v.status)
        assertTrue(v.isValidToday)
    }

    @Test
    fun `upcoming is detected without an end date`() {
        assertEquals(DealValidityStatus.UPCOMING, DealValidityLogic.validity("2026-09-26", null, today).status)
    }

    @Test
    fun `last day and the day before count as expiring, past end date as expired`() {
        assertEquals(0, DealValidityLogic.validity(null, "2026-09-25", today).daysLeft)
        assertEquals(DealValidityStatus.EXPIRING, DealValidityLogic.validity(null, "2026-09-27", today).status)
        assertEquals(DealValidityStatus.ACTIVE, DealValidityLogic.validity(null, "2026-09-28", today).status)
        assertEquals(DealValidityStatus.EXPIRED, DealValidityLogic.validity(null, "2026-09-24", today).status)
    }

    @Test
    fun `open-ended and unparseable dates are active`() {
        assertEquals(DealValidityStatus.ACTIVE, DealValidityLogic.validity(null, null, today).status)
        assertEquals(DealValidityStatus.ACTIVE, DealValidityLogic.validity("soon", "", today).status)
        assertNull(DealValidityLogic.parseDay("2026-9"))
    }

    // ── Dedupe ──

    @Test
    fun `rows of one offer collapse into one card with the best row as primary`() {
        val rows = listOf(
            deal("o1", productId = "p1", productName = "Monster Ultra", confidence = 0.7, until = "2026-10-01"),
            deal("o1", productId = "p2", productName = "Monster Mango", confidence = 0.95, until = "2026-10-01"),
            deal("o1", productId = "p1", productName = "Monster Ultra", confidence = 0.8, until = "2026-10-01"),
            deal("o2", until = "2026-09-20"), // expired → dropped
        )
        val out = DealsLogic.dedupe(rows, emptyMap(), today)
        assertEquals(1, out.size)
        assertEquals("REWE::o1", out[0].key)
        assertEquals(0.95, out[0].primary.confidence, 0.0)
        assertEquals(listOf("p2" to 0.95, "p1" to 0.8), out[0].matchedProducts.map { it.id to it.confidence })
    }

    @Test
    fun `user state marks pinned and archived, active list floats pinned first`() {
        val rows = listOf(
            deal("a", discount = 10.0),
            deal("b", discount = 40.0),
            deal("c", discount = 20.0),
            deal("d", discount = 50.0),
        )
        val states = mapOf(
            "REWE::c" to DealUserState(archivedAt = null, pinnedAt = "2026-09-24T10:00:00Z"),
            "REWE::d" to DealUserState(archivedAt = "2026-09-24T10:00:00Z", pinnedAt = null),
        )
        val deduped = DealsLogic.dedupe(rows, states, today)
        assertEquals(listOf("c", "b", "a"), DealsLogic.activeDeals(deduped).map { it.offerId })
        assertEquals(listOf("d"), DealsLogic.archivedDeals(deduped).map { it.offerId })
    }

    // ── Grouping ──

    @Test
    fun `validity grouping puts valid-now first then one section per start day`() {
        val rows = listOf(
            deal("later", from = "2026-10-01", until = "2026-10-07"),
            deal("now-a", from = "2026-09-21", until = "2026-09-26"),
            deal("mon-1", from = "2026-09-28", until = "2026-10-03"),
            deal("now-b"),
            deal("mon-2", from = "2026-09-28", until = "2026-10-03"),
        )
        val active = DealsLogic.dedupe(rows, emptyMap(), today) // sorted by key
        val groups = DealsLogic.group(active, DealGroupMode.VALIDITY, DealListMode.ACTIVE, today)
        assertEquals(
            listOf(
                DealGroup.Kind.VALID_NOW to listOf("now-a", "now-b"),
                DealGroup.Kind.UPCOMING to listOf("mon-1", "mon-2"),
                DealGroup.Kind.UPCOMING to listOf("later"),
            ),
            groups.map { g -> g.kind to g.deals.map { it.offerId } },
        )
        assertEquals(LocalDate(2026, 9, 28), groups[1].from)
        assertEquals(3, groups[1].startsInDays)
    }

    @Test
    fun `retailer grouping sorts valid-now before upcoming within a group and keeps pinned on top`() {
        val rows = listOf(
            deal("x-up", retailer = "Aldi", from = "2026-09-30"),
            deal("x-now", retailer = "Aldi"),
            deal("y", retailer = "Lidl"),
        )
        val states = mapOf("Lidl::y" to DealUserState(null, "2026-09-24T10:00:00Z"))
        val deduped = DealsLogic.dedupe(rows, states, today)
        val groups = DealsLogic.group(DealsLogic.activeDeals(deduped), DealGroupMode.RETAILER, DealListMode.ACTIVE, today)
        assertEquals(DealGroup.Kind.PINNED, groups[0].kind)
        assertEquals("Aldi", groups[1].label)
        assertEquals(listOf("x-now", "x-up"), groups[1].deals.map { it.offerId })
    }

    // ── EK ──

    private fun summary(newest: Double, min: Double, max: Double) = ProductPurchaseSummary(
        productId = "p1", ekCount = 2, newestNet = newest / 1.07, newestGross = newest,
        minGross = min, maxGross = max, effectiveTaxRate = 0.07,
    )

    @Test
    fun `classifyDeal matches the web and iOS verdicts`() {
        val s = summary(newest = 1.00, min = 0.90, max = 1.20)
        assertEquals(DealVerdict.GOOD_BEST, PurchaseComparison.classifyDeal(0.89, s).verdict)
        assertEquals(DealVerdict.GOOD, PurchaseComparison.classifyDeal(0.95, s).verdict)
        assertEquals(DealVerdict.SIMILAR, PurchaseComparison.classifyDeal(1.02, s).verdict)
        assertEquals(DealVerdict.WORSE, PurchaseComparison.classifyDeal(1.10, s).verdict)
        assertEquals(DealVerdict.IMPLAUSIBLE, PurchaseComparison.classifyDeal(1.30, s).verdict)
        assertEquals(DealVerdict.NO_EK, PurchaseComparison.classifyDeal(1.00, null).verdict)
    }

    @Test
    fun `a card is suppressed only when every matched product is implausible`() {
        val card = DealsLogic.dedupe(
            listOf(deal("o", productId = "p1", productName = "P", price = 1.50)),
            emptyMap(),
            today,
        ).single()
        val ek = DealsLogic.dealEk(card, mapOf("p1" to summary(1.00, 0.90, 1.20)))
        assertTrue(ek.suppressed)
        assertEquals(1.00, ek.usualEkGross!!, 0.0)
        assertFalse(DealsLogic.dealEk(card, emptyMap()).suppressed)
    }

    // ── Decoding ──

    @Test
    fun `decodes a deal-search response with keyword joins`() {
        val body = """
            {"deals":[{"id":"1","retailer":"REWE","deal_title":"Haribo","offer_id":"9",
              "valid_from":"2026-09-28","valid_until":"2026-10-03","confidence":0.8,
              "matched_by":"keyword_fuzzy","requires_app":false,"unknown_column":1,
              "deal_keywords":{"id":"k","label":"Haribo","terms":["haribo"],
                "deal_keyword_products":[{"products":{"id":"p","name":"Goldbären"}}]}}],
             "fromCache":true}
        """.trimIndent()
        val res = Json { ignoreUnknownKeys = true }.decodeFromString<DealSearchResponse>(body)
        assertTrue(res.fromCache)
        assertEquals("Goldbären", res.deals.single().dealKeywords!!.linkedProducts.single().name)
        assertEquals(
            DealValidityStatus.UPCOMING,
            DealValidityLogic.validity(res.deals.single(), today).status,
        )
    }
}
