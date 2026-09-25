import Foundation
import Supabase

@MainActor
final class DealsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var deals: [Deal] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var fromCache = false
    @Published var searchText = ""
    /// Validity first so "can I buy this today?" is answered before anything
    /// else — upcoming offers were too easy to mistake for current ones.
    @Published var groupBy: GroupMode = .validity
    @Published var listMode: ListMode = .active

    // Settings
    @Published var dealsEnabled = false
    @Published var dealsZipCode = ""
    @Published var settingsLoading = false

    /// Per-user archive/pin state keyed by `${retailer}::${offer_id}`.
    /// Only deals the user has interacted with have an entry here.
    @Published var userStates: [String: DealUserState] = [:]

    /// Keys (`${retailer}::${offer_id}`) of offers that are NEW for the current
    /// user — first seen after their baseline and not yet seen, pinned or
    /// archived. Computed server-side by the get_new_deal_keys RPC.
    @Published var newDealKeys: Set<String> = []

    /// EK summaries for products referenced by the current deal set (product id → summary).
    @Published var ekSummaries: [UUID: ProductPurchaseSummary] = [:]
    private let purchaseVM = PurchasePricesViewModel()

    enum GroupMode: String, CaseIterable {
        case validity = "Validity"
        case retailer = "Retailer"
        case product = "Product"

        var label: String {
            switch self {
            case .validity: return String(localized: "Validity")
            case .retailer: return String(localized: "Retailer")
            case .product: return String(localized: "Product")
            }
        }
    }

    enum ListMode: String, CaseIterable {
        case active = "Active"
        case archived = "Archived"

        var label: String {
            switch self {
            case .active: return String(localized: "Active")
            case .archived: return String(localized: "Archived")
            }
        }
    }

    struct DealUserState {
        let archivedAt: String?
        let pinnedAt: String?
        var archived: Bool { archivedAt != nil }
        var pinned: Bool { pinnedAt != nil }
    }

    private var client: SupabaseClient { SupabaseService.shared.client }

    // MARK: - Computed

    /// Collapse raw deal_cache rows into one entry per (retailer, offer_id).
    /// Picks the highest-confidence row as the "primary" and aggregates the
    /// full set of matched products / keyword groups for the detail sheet.
    ///
    /// Result is sorted by `key` ascending so the order is deterministic across
    /// recomputes — Swift `Dictionary` iteration order is unspecified, so
    /// without an explicit sort items would shuffle every time `userStates`
    /// changes (e.g. after archive/pin), making downstream stable-sort ties
    /// resolve differently and visibly reorder the list.
    var dedupedDeals: [DedupedDeal] {
        let validDeals = deals.filter { $0.isValid && $0.offerId != nil }

        // Group raw rows by stable key.
        var groups: [String: [Deal]] = [:]
        for d in validDeals {
            guard let offerId = d.offerId else { continue }
            let key = Self.stateKey(retailer: d.retailer, offerId: offerId)
            groups[key, default: []].append(d)
        }

        let result: [DedupedDeal] = groups.compactMap { (key, rows) -> DedupedDeal? in
            let sorted = rows.sorted { $0.confidence > $1.confidence }
            guard let primary = sorted.first, let offerId = primary.offerId else { return nil }

            // Collect distinct matched products, picking the highest confidence per product.
            var productMap: [UUID: DedupedDeal.MatchedProduct] = [:]
            var keywordMap: [UUID: DealKeywordMatch] = [:]
            for r in sorted {
                if let p = r.products, let pid = r.productId, let name = p.name {
                    let candidate = DedupedDeal.MatchedProduct(
                        id: pid,
                        name: name,
                        imagePath: p.imagePath,
                        sellprice: p.sellprice,
                        confidence: r.confidence
                    )
                    if let existing = productMap[pid], existing.confidence >= candidate.confidence {
                        // keep existing (higher or equal confidence)
                    } else {
                        productMap[pid] = candidate
                    }
                }
                if let kw = r.dealKeywords, let kid = kw.id, keywordMap[kid] == nil {
                    keywordMap[kid] = kw
                }
            }

            let state = userStates[key]
            return DedupedDeal(
                key: key,
                retailer: primary.retailer,
                offerId: offerId,
                primary: primary,
                matchedProducts: productMap.values.sorted { $0.confidence > $1.confidence },
                matchedKeywords: Array(keywordMap.values),
                archived: state?.archived ?? false,
                pinned: state?.pinned ?? false,
                pinnedAt: state?.pinnedAt
            )
        }

        return result.sorted { $0.key < $1.key }
    }

    /// Non-archived deals with pinned ones floated to the top (most recent
    /// pin first), then sorted by discount desc. Matches the web behaviour.
    /// `key` ascending breaks ties so equal-discount or equal-pinnedAt deals
    /// don't shuffle when an unrelated archive/pin mutates `userStates`.
    var activeDeals: [DedupedDeal] {
        dedupedDeals
            .filter { !$0.archived }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                if a.pinned, b.pinned {
                    let pa = a.pinnedAt ?? ""
                    let pb = b.pinnedAt ?? ""
                    if pa != pb { return pa > pb }
                    return a.key < b.key
                }
                let da = a.discountPct ?? -1
                let db = b.discountPct ?? -1
                if da != db { return da > db }
                return a.key < b.key
            }
    }

    var archivedDeals: [DedupedDeal] {
        dedupedDeals
            .filter { $0.archived }
            .sorted { a, b in
                let da = a.discountPct ?? -1
                let db = b.discountPct ?? -1
                if da != db { return da > db }
                return a.key < b.key
            }
    }

    var archivedCount: Int { archivedDeals.count }

    // MARK: - EK comparison + suppression

    /// All catalog product ids an offer references (name matches + keyword-group products).
    private func dealProductIds(_ d: DedupedDeal) -> [UUID] {
        var ids = Set<UUID>()
        for p in d.matchedProducts { ids.insert(p.id) }
        for kw in d.matchedKeywords { for lp in kw.linkedProducts { if let id = lp.id { ids.insert(id) } } }
        return Array(ids)
    }

    // Walks the raw `deals` rows (covers the same products as `dealProductIds`,
    // just from the other shape) — intentional, don't "unify" the two.
    func fetchEkSummaries() async {
        var ids = Set<UUID>()
        for d in deals {
            if let pid = d.productId { ids.insert(pid) }
            for lp in d.dealKeywords?.linkedProducts ?? [] { if let id = lp.id { ids.insert(id) } }
        }
        ekSummaries = await purchaseVM.fetchSummaries(productIds: Array(ids))
    }

    private static let verdictRank: [DealVerdict: Int] = [
        .goodBest: 5, .good: 4, .similar: 3, .worse: 2, .noEk: 1, .implausible: 0,
    ]

    /// Per-deal EK result: card-suppression flag + best verdict (with its delta)
    /// for the pill, plus `usualEkGross` — the usual EK to surface on the card.
    /// When several products match one offer, that's the EK of the *cheapest*
    /// matched product (lowest üblicher/newest gross across all matched products
    /// with EK data), independent of the verdict ranking.
    func dealEk(_ d: DedupedDeal) -> (suppressed: Bool, bestVerdict: DealVerdict?, bestDeltaPct: Double?, usualEkGross: Double?) {
        let dealGross = d.primary.dealPrice
        let summaries = dealProductIds(d).map { ekSummaries[$0] }
        let comparisons = summaries.map {
            PurchaseComparison.classifyDeal(dealGross: dealGross, summary: $0)
        }
        let verdicts = comparisons.map { $0.verdict }
        let suppressed = PurchaseComparison.isCardSuppressed(verdicts)
        let ranked = comparisons
            .filter { $0.verdict != .noEk }
            .sorted { (Self.verdictRank[$0.verdict] ?? 0) > (Self.verdictRank[$1.verdict] ?? 0) }
        let usualEkGross = summaries
            .compactMap { ($0?.ekCount ?? 0) > 0 ? $0?.newestGross : nil }
            .min()
        return (suppressed, ranked.first?.verdict, ranked.first?.deltaPct, usualEkGross)
    }

    var visibleActiveDeals: [DedupedDeal] { activeDeals.filter { !dealEk($0).suppressed } }
    var suppressedActiveDeals: [DedupedDeal] { activeDeals.filter { dealEk($0).suppressed } }

    /// A deal is "new" if the RPC flagged it AND the user hasn't pinned or
    /// archived it yet, so the NEU badge clears optimistically on pin/archive.
    func isNew(_ deal: DedupedDeal) -> Bool {
        newDealKeys.contains(deal.key) && !deal.archived && !deal.pinned
    }

    var filteredDeals: [DedupedDeal] {
        let source = listMode == .archived ? archivedDeals : visibleActiveDeals
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        return source.filter { d in
            if d.dealTitle.lowercased().contains(query) { return true }
            if d.retailer.lowercased().contains(query) { return true }
            if d.matchedProducts.contains(where: { $0.name.lowercased().contains(query) }) { return true }
            if d.matchedKeywords.contains(where: { ($0.label ?? "").lowercased().contains(query) }) { return true }
            return false
        }
    }

    /// Pinned deals always form their own top-of-list group, independent of
    /// the retailer/product toggle. The rest stay grouped by the user's
    /// chosen dimension below. In Archived view the pinned group is omitted
    /// (the user is explicitly reviewing archived items).
    struct DealGroup: Identifiable {
        enum Kind { case plain, pinned, validNow, upcoming, expired }

        let id: String
        let label: String
        var sublabel: String? = nil
        let kind: Kind
        let deals: [DedupedDeal]

        var pinned: Bool { kind == .pinned }
    }

    /// Stable sort: valid today first (keeping the incoming order, i.e.
    /// discount desc), then upcoming by start day, then expired.
    private func sortedByValidity(_ list: [DedupedDeal]) -> [DedupedDeal] {
        list.enumerated().sorted { a, b in
            let pa = a.element.primary, pb = b.element.primary
            if pa.validityRank != pb.validityRank { return pa.validityRank < pb.validityRank }
            if pa.validityStatus == .upcoming, let fa = pa.validFromDate, let fb = pb.validFromDate, fa != fb {
                return fa < fb
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// "Valid now", then one section per upcoming start day, then expired.
    private func validityGroups(_ list: [DedupedDeal]) -> [DealGroup] {
        let sorted = sortedByValidity(list)
        var result: [DealGroup] = []

        let now = sorted.filter { $0.primary.isValidToday }
        if !now.isEmpty {
            result.append(DealGroup(id: "__valid_now__", label: String(localized: "Valid now"),
                                    kind: .validNow, deals: now))
        }

        var upcomingOrder: [Date] = []
        var upcomingByDay: [Date: [DedupedDeal]] = [:]
        for deal in sorted where deal.primary.validityStatus == .upcoming {
            guard let from = deal.primary.validFromDate else { continue }
            if upcomingByDay[from] == nil { upcomingOrder.append(from) }
            upcomingByDay[from, default: []].append(deal)
        }
        for day in upcomingOrder {
            let deals = upcomingByDay[day] ?? []
            result.append(DealGroup(
                id: "__from_\(day.timeIntervalSince1970)__",
                label: deals.first?.primary.validFromLabel ?? Deal.shortDay(day),
                sublabel: deals.first?.primary.startsInLabel,
                kind: .upcoming,
                deals: deals
            ))
        }

        let expired = sorted.filter { $0.primary.validityStatus == .expired }
        if !expired.isEmpty {
            result.append(DealGroup(id: "__expired__", label: String(localized: "Expired"),
                                    kind: .expired, deals: expired))
        }
        return result
    }

    var groupedDeals: [DealGroup] {
        var result: [DealGroup] = []
        let source = filteredDeals
        let isActive = listMode == .active

        let pinnedDeals = sortedByValidity(isActive ? source.filter { $0.pinned } : [])
        let rest = sortedByValidity(isActive ? source.filter { !$0.pinned } : source)

        if !pinnedDeals.isEmpty {
            result.append(DealGroup(
                id: "__pinned__",
                label: String(localized: "Pinned"),
                kind: .pinned,
                deals: pinnedDeals
            ))
        }

        let grouped: [String: [DedupedDeal]]
        switch groupBy {
        case .validity:
            return result + validityGroups(rest)
        case .retailer:
            grouped = Dictionary(grouping: rest) { $0.retailer }
        case .product:
            grouped = Dictionary(grouping: rest) { deal in
                deal.matchedProducts.first?.name ?? deal.matchedKeywords.first?.label ?? "—"
            }
        }

        for (key, deals) in grouped.sorted(by: { $0.key < $1.key }) {
            result.append(DealGroup(
                id: key,
                label: key,
                kind: .plain,
                deals: deals
            ))
        }

        return result
    }

    var totalDeals: Int { filteredDeals.count }

    var uniqueRetailers: Int {
        Set(filteredDeals.map(\.retailer)).count
    }

    var avgDiscount: Int {
        let discounts = filteredDeals.compactMap(\.discountPct)
        guard !discounts.isEmpty else { return 0 }
        return Int(discounts.reduce(0, +) / Double(discounts.count))
    }

    // MARK: - Load All

    func loadAll() async {
        await loadSettings()
        if dealsEnabled {
            await fetchUserStates()
            await fetchDeals()
            await fetchNewDealKeys()
            await fetchEkSummaries()
        }
    }

    // MARK: - Settings

    func loadSettings() async {
        settingsLoading = true
        defer { settingsLoading = false }

        do {
            let response: [CompanyDealSettings] = try await client
                .from("companies")
                .select("deals_enabled, deals_zip_code")
                .limit(1)
                .execute()
                .value

            if let settings = response.first {
                dealsEnabled = settings.dealsEnabled ?? false
                dealsZipCode = settings.dealsZipCode ?? ""
            }
        } catch is CancellationError {
            // SwiftUI routine — ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveSettings() async {
        settingsLoading = true
        defer { settingsLoading = false }

        do {
            let params = CompanyDealUpdate(
                dealsEnabled: dealsEnabled,
                dealsZipCode: dealsZipCode.isEmpty ? "" : dealsZipCode
            )
            try await client
                .from("companies")
                .update(params)
                .not("id", operator: .is, value: "null")
                .execute()
        } catch is CancellationError {
            // ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Fetch Deals

    func fetchDeals(forceRefresh: Bool = false) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let body = DealSearchBody(forceRefresh: forceRefresh, minConfidence: 0.5)
            let response: DealSearchResponse = try await client.functions.invoke(
                "deal-search",
                options: .init(body: body)
            )

            deals = response.deals
            fromCache = response.fromCache
        } catch is CancellationError {
            // ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - New deals

    /// Fetch the set of new/unhandled offer keys for the current user via the
    /// get_new_deal_keys RPC (returns rows of {retailer, offer_id}).
    func fetchNewDealKeys() async {
        do {
            let rows: [NewDealKeyRow] = try await client
                .rpc("get_new_deal_keys")
                .execute()
                .value
            newDealKeys = Set(rows.map { Self.stateKey(retailer: $0.retailer, offerId: $0.offerId) })
        } catch is CancellationError {
            // ignore
        } catch {
            // Non-fatal — backends without the migration shouldn't break the list.
            print("[DealsVM] fetchNewDealKeys failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Seen tracking

    /// Seeing a new offer in the list is enough to clear it. Rows report
    /// themselves on appear; keys are batched into one mark_deals_seen call.
    /// `newDealKeys` is deliberately left alone so the NEU badge stays visible
    /// until the next fetchNewDealKeys (pull-to-refresh / next visit) — the
    /// server-side count (dashboard banner) drops immediately.
    private var seenQueue: [String: DealSeenKey] = [:]
    private var seenSent: Set<String> = []
    private var seenFlushTask: Task<Void, Never>?

    func markSeen(_ deal: DedupedDeal) {
        guard newDealKeys.contains(deal.key), !seenSent.contains(deal.key) else { return }
        seenSent.insert(deal.key)
        seenQueue[deal.key] = DealSeenKey(retailer: deal.retailer, offerId: deal.offerId)
        guard seenFlushTask == nil else { return }
        seenFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.flushSeen()
        }
    }

    func flushSeen() async {
        seenFlushTask?.cancel()
        seenFlushTask = nil
        guard !seenQueue.isEmpty else { return }
        let batch = seenQueue
        seenQueue = [:]
        do {
            try await client
                .rpc("mark_deals_seen", params: MarkDealsSeenParams(pKeys: Array(batch.values)))
                .execute()
        } catch {
            // Non-fatal — allow a retry the next time the row appears.
            print("[DealsVM] mark_deals_seen failed: \(error.localizedDescription)")
            for key in batch.keys { seenSent.remove(key) }
        }
    }

    // MARK: - User state (archive / pin)

    private static func stateKey(retailer: String, offerId: String) -> String {
        "\(retailer)::\(offerId)"
    }

    private func fetchCompanyId() async throws -> UUID {
        let userId = try await client.auth.session.user.id

        struct OrgMember: Decodable {
            let companyId: UUID
            enum CodingKeys: String, CodingKey { case companyId = "company_id" }
        }

        let members: [OrgMember] = try await client
            .from("organization_members")
            .select("company_id")
            .eq("user_id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value

        guard let companyId = members.first?.companyId else {
            throw NSError(domain: "DealsVM", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Could not determine company"
            ])
        }
        return companyId
    }

    func fetchUserStates() async {
        do {
            let companyId = try await fetchCompanyId()
            let userId = try await client.auth.session.user.id

            let rows: [DealUserStateRow] = try await client
                .from("deal_user_state")
                .select("retailer, offer_id, archived_at, pinned_at")
                .eq("company_id", value: companyId.uuidString)
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value

            var map: [String: DealUserState] = [:]
            for row in rows {
                map[Self.stateKey(retailer: row.retailer, offerId: row.offerId)] = DealUserState(
                    archivedAt: row.archivedAt,
                    pinnedAt: row.pinnedAt
                )
            }
            userStates = map
        } catch is CancellationError {
            // ignore
        } catch {
            // Non-fatal — users without the migration applied yet (or RLS issues)
            // shouldn't break the deals list. Log to console for diagnostics.
            print("[DealsVM] fetchUserStates failed: \(error.localizedDescription)")
        }
    }

    /// Target state to write for (retailer, offer_id). Full row semantics —
    /// the caller specifies the final values of archived_at and pinned_at.
    /// Upsert writes the whole row, so one field never accidentally clobbers
    /// the other.
    private func applyUserState(
        retailer: String,
        offerId: String,
        archivedAt: String?,
        pinnedAt: String?
    ) async {
        let key = Self.stateKey(retailer: retailer, offerId: offerId)
        let prev = userStates[key] ?? DealUserState(archivedAt: nil, pinnedAt: nil)
        let next = DealUserState(archivedAt: archivedAt, pinnedAt: pinnedAt)
        userStates[key] = next  // optimistic

        do {
            let companyId = try await fetchCompanyId()
            let userId = try await client.auth.session.user.id

            let payload = DealUserStateUpsert(
                userId: userId,
                companyId: companyId,
                retailer: retailer,
                offerId: offerId,
                archivedAt: archivedAt,
                pinnedAt: pinnedAt
            )

            try await client
                .from("deal_user_state")
                .upsert(payload, onConflict: "user_id,company_id,retailer,offer_id")
                .execute()
        } catch is CancellationError {
            // ignore
        } catch {
            print("[DealsVM] applyUserState failed: \(error.localizedDescription)")
            userStates[key] = prev  // roll back
            self.error = error.localizedDescription
        }
    }

    /// Current persisted archivedAt string (if any), so we can round-trip
    /// it through an upsert without fabricating a new timestamp when we're
    /// actually just toggling the pin.
    private func currentArchivedAt(for deal: DedupedDeal) -> String? {
        let key = Self.stateKey(retailer: deal.retailer, offerId: deal.offerId)
        return userStates[key]?.archivedAt
    }

    private func currentPinnedAt(for deal: DedupedDeal) -> String? {
        let key = Self.stateKey(retailer: deal.retailer, offerId: deal.offerId)
        return userStates[key]?.pinnedAt
    }

    func archive(_ deal: DedupedDeal) async {
        let now = ISO8601DateFormatter().string(from: Date())
        await applyUserState(
            retailer: deal.retailer,
            offerId: deal.offerId,
            archivedAt: now,
            pinnedAt: currentPinnedAt(for: deal)
        )
    }

    func unarchive(_ deal: DedupedDeal) async {
        await applyUserState(
            retailer: deal.retailer,
            offerId: deal.offerId,
            archivedAt: nil,
            pinnedAt: currentPinnedAt(for: deal)
        )
    }

    func pin(_ deal: DedupedDeal) async {
        let now = ISO8601DateFormatter().string(from: Date())
        await applyUserState(
            retailer: deal.retailer,
            offerId: deal.offerId,
            archivedAt: currentArchivedAt(for: deal),
            pinnedAt: now
        )
    }

    func unpin(_ deal: DedupedDeal) async {
        await applyUserState(
            retailer: deal.retailer,
            offerId: deal.offerId,
            archivedAt: currentArchivedAt(for: deal),
            pinnedAt: nil
        )
    }
}

// MARK: - Helper Types

private struct CompanyDealSettings: Codable {
    let dealsEnabled: Bool?
    let dealsZipCode: String?

    enum CodingKeys: String, CodingKey {
        case dealsEnabled = "deals_enabled"
        case dealsZipCode = "deals_zip_code"
    }
}

private struct CompanyDealUpdate: Codable {
    let dealsEnabled: Bool
    let dealsZipCode: String

    enum CodingKeys: String, CodingKey {
        case dealsEnabled = "deals_enabled"
        case dealsZipCode = "deals_zip_code"
    }
}

private struct DealSearchBody: Codable {
    let forceRefresh: Bool
    let minConfidence: Double
}

private struct NewDealKeyRow: Decodable {
    let retailer: String
    let offerId: String

    enum CodingKeys: String, CodingKey {
        case retailer
        case offerId = "offer_id"
    }
}

private struct DealSeenKey: Encodable {
    let retailer: String
    let offerId: String

    enum CodingKeys: String, CodingKey {
        case retailer
        case offerId = "offer_id"
    }
}

private struct MarkDealsSeenParams: Encodable {
    let pKeys: [DealSeenKey]

    enum CodingKeys: String, CodingKey {
        case pKeys = "p_keys"
    }
}

private struct DealUserStateUpsert: Codable {
    let userId: UUID
    let companyId: UUID
    let retailer: String
    let offerId: String
    let archivedAt: String?
    let pinnedAt: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case companyId = "company_id"
        case retailer
        case offerId = "offer_id"
        case archivedAt = "archived_at"
        case pinnedAt = "pinned_at"
    }
}
