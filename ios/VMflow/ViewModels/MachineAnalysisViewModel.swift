import Foundation
import Supabase

// ─────────────────────────────────────────────────────────────────────────────
// Product-centric machine performance analysis — ported 1:1 from the web's
// `useMachineAnalysis.ts` (management-frontend/app/composables). Performance is
// a property of the PRODUCT, not the slot: sales are aggregated across every
// slot a product occupies (server-side, via `get_machine_product_kpis`), and
// its tenure survives being moved between trays (`machine_product_offerings`).
//
// The slot grid layout math (row/column/width) mirrors
// `ios/VMflow/Views/Refill/MachineLayoutGrid.swift` exactly:
//   row    = max(0, floor(item_number / 10) - 1)
//   column = item_number % 10
//   width  = gap to the next occupied slot in the row.
// ─────────────────────────────────────────────────────────────────────────────

enum SlotTier: String, Equatable {
    case empty, testing, dead, weak, ok, strong

    /// Sort priority for "products to review" — worst first.
    var severity: Int {
        switch self {
        case .dead: return 0
        case .weak: return 1
        case .testing: return 2
        case .ok: return 3
        case .strong: return 4
        case .empty: return 5
        }
    }
}

struct Suggestion: Identifiable, Equatable {
    enum Kind: Equatable { case bestseller, newcomer }
    let productId: UUID
    let name: String
    let imagePath: String?
    let kind: Kind
    /// Fleet-wide avg daily units (0 for newcomers).
    let velocity: Double
    var id: UUID { productId }
}

/// Aggregated performance of one product within a single machine.
struct ProductAnalysis: Identifiable, Equatable {
    let productId: UUID
    let name: String
    let imagePath: String?
    /// item_numbers of the slots this product currently occupies.
    let slots: [Int]
    /// tray ids of those slots (for applying swaps).
    let trayIds: [UUID]
    let unitsSold: Int
    let revenueEur: Double
    let totalCapacity: Int
    let totalStock: Int
    let sellThroughPct: Double
    let avgDailyUnits: Double
    let daysUntilEmpty: Int?
    /// Days since the product was first offered in this machine (survives slot moves).
    let tenureDays: Int?
    let tier: SlotTier
    let suggestions: [Suggestion]
    var id: UUID { productId }
}

/// A single cell in the rendered machine layout grid, coloured by its
/// product's tier.
struct AnalysisGridSlot: Identifiable, Equatable {
    let trayId: UUID
    let itemNumber: Int
    let row: Int
    let column: Int
    let width: Int
    let productId: UUID?
    let productName: String?
    let imagePath: String?
    let tier: SlotTier
    let sellThroughPct: Double
    var id: UUID { trayId }
}

/// AI-generated recommendation from the `machine-insights` edge function.
struct MachineInsightRecommendation: Decodable, Identifiable, Equatable {
    let type: String
    let priority: String
    let title: String
    let detail: String
    let itemNumber: Int?
    var id: String { title }

    enum CodingKeys: String, CodingKey {
        case type, priority, title, detail
        case itemNumber = "item_number"
    }
}

struct MachineInsights: Decodable, Equatable {
    let recommendations: [MachineInsightRecommendation]
    let summary: String
    let generatedAt: String?
    let cached: Bool?

    enum CodingKeys: String, CodingKey {
        case recommendations, summary, cached
        case generatedAt = "generated_at"
    }
}

// MARK: - Pure helpers (grid layout, scoring, suggestions)

private let columnsPerRow = 10

/// Map a flat item_number to its (row, column) grid position — matches
/// `MachineLayoutGrid.swift`'s layout math exactly.
func slotRowCol(_ itemNumber: Int) -> (row: Int, column: Int) {
    (row: max(0, itemNumber / 10 - 1), column: ((itemNumber % 10) + 10) % 10)
}

/// Physical width (in columns) of each slot: from its own column to the next
/// occupied slot in the same row; the last slot in a row stretches to the row
/// end. Gaps in the item_number sequence widen the preceding slot.
func computeSlotWidths(_ items: [Int]) -> [Int: Int] {
    var byRow: [Int: [Int]] = [:]
    for item in items {
        let (row, _) = slotRowCol(item)
        byRow[row, default: []].append(item)
    }
    var widths: [Int: Int] = [:]
    for rowItems in byRow.values {
        let sorted = rowItems.sorted()
        for (i, item) in sorted.enumerated() {
            let (_, column) = slotRowCol(item)
            let next = i + 1 < sorted.count ? sorted[i + 1] : nil
            let width = next.map { $0 - item } ?? (columnsPerRow - column)
            widths[item] = max(1, min(columnsPerRow - column, width))
        }
    }
    return widths
}

struct ScoreOpts {
    var gracePeriodDays = 14
    var weakSellThrough = 15.0
    var strongSellThrough = 40.0
}

/// Classify a product's performance. A product offered for fewer than the
/// grace period that would otherwise score dead/weak is surfaced as "testing"
/// instead, so it isn't condemned before it has had a fair chance.
func scoreProduct(unitsSold: Int, sellThroughPct: Double, tenureDays: Int?, opts: ScoreOpts = ScoreOpts()) -> SlotTier {
    let base: SlotTier
    if unitsSold <= 0 {
        base = .dead
    } else if sellThroughPct < opts.weakSellThrough {
        base = .weak
    } else if sellThroughPct < opts.strongSellThrough {
        base = .ok
    } else {
        base = .strong
    }

    if (base == .dead || base == .weak), let tenureDays, tenureDays < opts.gracePeriodDays {
        return .testing
    }
    return base
}

/// Build the shared pool of replacement candidates for a machine: proven
/// fleet-wide bestsellers not yet in this machine, and never-sold newcomers
/// (test candidates). Discontinued products are assumed already excluded from
/// `products` by the caller (matches how `MachineDetailViewModel.loadProducts`
/// only fetches non-discontinued rows).
func buildSuggestionPool(
    products: [Product], velocity: [UUID: Double], productsInMachine: Set<UUID>,
    maxBestsellers: Int = 5, maxNewcomers: Int = 5
) -> (bestsellers: [Suggestion], newcomers: [Suggestion]) {
    let eligible = products.filter { !productsInMachine.contains($0.id) }

    let bestsellers = eligible
        .compactMap { p -> (Product, Double)? in
            guard let v = velocity[p.id], v > 0 else { return nil }
            return (p, v)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(maxBestsellers)
        .map { p, v in Suggestion(productId: p.id, name: p.name ?? String(localized: "Unknown"), imagePath: p.imagePath, kind: .bestseller, velocity: v) }

    let newcomers = eligible
        .filter { (velocity[$0.id] ?? 0) <= 0 }
        .sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
        .prefix(maxNewcomers)
        .map { p in Suggestion(productId: p.id, name: p.name ?? String(localized: "Unknown"), imagePath: p.imagePath, kind: .newcomer, velocity: 0) }

    return (Array(bestsellers), Array(newcomers))
}

/// Build the layout grid cells, colouring each slot by its product's tier.
func buildGridSlots(trays: [Tray], tierByProduct: [UUID: (tier: SlotTier, sellThroughPct: Double)]) -> [AnalysisGridSlot] {
    let widths = computeSlotWidths(trays.map(\.itemNumber))
    return trays.map { tray in
        let (row, column) = slotRowCol(tray.itemNumber)
        let info = tray.productId.flatMap { tierByProduct[$0] }
        return AnalysisGridSlot(
            trayId: tray.id, itemNumber: tray.itemNumber, row: row, column: column,
            width: widths[tray.itemNumber] ?? 1,
            productId: tray.productId, productName: tray.products?.name, imagePath: tray.products?.imagePath,
            tier: tray.productId != nil ? (info?.tier ?? .empty) : .empty,
            sellThroughPct: info?.sellThroughPct ?? 0
        )
    }
}

// MARK: - ViewModel

@MainActor
final class MachineAnalysisViewModel: ObservableObject {
    @Published var products: [ProductAnalysis] = []
    @Published var slots: [AnalysisGridSlot] = []
    @Published var rowCount = 0
    @Published var fillSuggestions: [Suggestion] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var days = 30
    /// Trays with a pending change on the machine's open change request.
    @Published var pendingTrayIds: Set<UUID> = []

    @Published var insights: MachineInsights?
    @Published var insightsLoading = false
    @Published var insightsError: String?

    private let client = SupabaseService.shared.client
    private var lastMachineId: UUID?

    /// Underperforming products, worst first — the "products to review" list.
    var weakProducts: [ProductAnalysis] {
        products
            .filter { $0.tier == .dead || $0.tier == .weak }
            .sorted {
                if $0.tier.severity != $1.tier.severity { return $0.tier.severity < $1.tier.severity }
                return $0.sellThroughPct < $1.sellThroughPct
            }
    }

    // MARK: - Analyze

    /// `trays` and `catalogue` are the machine's already-loaded trays and the
    /// (non-discontinued) product catalogue — both already live in
    /// `MachineDetailViewModel`, so this avoids re-fetching them.
    func analyze(machineId: UUID, trays: [Tray], catalogue: [Product], windowDays: Int? = nil) async {
        lastMachineId = machineId
        if let windowDays { days = windowDays }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let companyId = try await fetchCompanyId()

            struct KpiResponse: Decodable {
                let products: [KpiRow]
            }
            struct KpiRow: Decodable {
                let productId: UUID
                let productName: String?
                let unitsSold: Int
                let totalCapacity: Int?
                let totalStock: Int?
                let slots: [Int]?
                let offeredSince: Date?
                let revenueEur: Double

                enum CodingKeys: String, CodingKey {
                    case productId = "product_id", productName = "product_name"
                    case unitsSold = "units_sold", totalCapacity = "total_capacity"
                    case totalStock = "total_stock", slots
                    case offeredSince = "offered_since", revenueEur = "revenue_eur"
                }

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    productId = try c.decode(UUID.self, forKey: .productId)
                    productName = try c.decodeIfPresent(String.self, forKey: .productName)
                    unitsSold = try c.decodeIfPresent(Int.self, forKey: .unitsSold) ?? 0
                    totalCapacity = try c.decodeIfPresent(Int.self, forKey: .totalCapacity)
                    totalStock = try c.decodeIfPresent(Int.self, forKey: .totalStock)
                    slots = try c.decodeIfPresent([Int].self, forKey: .slots)
                    offeredSince = try c.decodeIfPresent(Date.self, forKey: .offeredSince)
                    // `revenue_eur` is a Postgres `numeric` — PostgREST may
                    // serialize it as either a JSON number or a string
                    // depending on version; accept both defensively.
                    if let d = (try? c.decodeIfPresent(Double.self, forKey: .revenueEur)) ?? nil {
                        revenueEur = d
                    } else if let s = (try? c.decodeIfPresent(String.self, forKey: .revenueEur)) ?? nil, let d = Double(s) {
                        revenueEur = d
                    } else {
                        revenueEur = 0
                    }
                }
            }

            struct VelocityRow: Decodable {
                let productId: UUID
                let avgDailyUnits: Double

                enum CodingKeys: String, CodingKey {
                    case productId = "product_id", avgDailyUnits = "avg_daily_units"
                }

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    productId = try c.decode(UUID.self, forKey: .productId)
                    if let d = (try? c.decodeIfPresent(Double.self, forKey: .avgDailyUnits)) ?? nil {
                        avgDailyUnits = d
                    } else if let s = (try? c.decodeIfPresent(String.self, forKey: .avgDailyUnits)) ?? nil, let d = Double(s) {
                        avgDailyUnits = d
                    } else {
                        avgDailyUnits = 0
                    }
                }
            }

            async let kpiTask: KpiResponse = client.rpc("get_machine_product_kpis", params: [
                "p_machine_id": AnyJSON.string(machineId.uuidString),
                "p_company_id": AnyJSON.string(companyId.uuidString),
                "p_days": AnyJSON.integer(self.days),
            ]).execute().value

            async let velocityTask: [VelocityRow] = client.rpc("get_product_sales_velocity", params: [
                "p_company_id": AnyJSON.string(companyId.uuidString),
                "p_days": AnyJSON.integer(self.days),
            ]).execute().value

            let (kpiResponse, velocityRows) = try await (kpiTask, velocityTask)

            var velocity: [UUID: Double] = [:]
            for row in velocityRows where row.avgDailyUnits > 0 {
                velocity[row.productId] = row.avgDailyUnits
            }

            let productsInMachine = Set(trays.compactMap(\.productId))
            let (bestsellers, newcomers) = buildSuggestionPool(
                products: catalogue, velocity: velocity, productsInMachine: productsInMachine
            )
            let sharedSuggestions = Array(bestsellers.prefix(3)) + Array(newcomers.prefix(2))
            fillSuggestions = sharedSuggestions

            var trayIdsByProduct: [UUID: [UUID]] = [:]
            for tray in trays {
                guard let pid = tray.productId else { continue }
                trayIdsByProduct[pid, default: []].append(tray.id)
            }
            let imageByProduct = Dictionary(uniqueKeysWithValues: catalogue.map { ($0.id, $0.imagePath) })

            let now = Date()
            let analyses: [ProductAnalysis] = kpiResponse.products.map { row in
                let capacity = row.totalCapacity ?? 0
                let stock = row.totalStock ?? 0
                let sellThrough = capacity > 0 && self.days > 0
                    ? min((Double(row.unitsSold) / (Double(capacity) * Double(self.days) / 7)) * 100, 100)
                    : 0
                let avgDaily = self.days > 0 ? Double(row.unitsSold) / Double(self.days) : 0
                let daysUntilEmpty: Int? = row.unitsSold > 0 && stock > 0
                    ? Int((Double(stock) / (Double(row.unitsSold) / Double(self.days))).rounded())
                    : (stock == 0 ? 0 : nil)
                let tenureDays = row.offeredSince.map { Int(now.timeIntervalSince($0) / 86_400) }

                let tier = scoreProduct(unitsSold: row.unitsSold, sellThroughPct: sellThrough, tenureDays: tenureDays)

                return ProductAnalysis(
                    productId: row.productId,
                    name: row.productName ?? String(localized: "Unknown"),
                    imagePath: imageByProduct[row.productId] ?? nil,
                    slots: row.slots ?? [],
                    trayIds: trayIdsByProduct[row.productId] ?? [],
                    unitsSold: row.unitsSold,
                    revenueEur: row.revenueEur,
                    totalCapacity: capacity,
                    totalStock: stock,
                    sellThroughPct: (sellThrough * 10).rounded() / 10,
                    avgDailyUnits: (avgDaily * 100).rounded() / 100,
                    daysUntilEmpty: daysUntilEmpty,
                    tenureDays: tenureDays,
                    tier: tier,
                    suggestions: (tier == .dead || tier == .weak)
                        ? sharedSuggestions.filter { $0.productId != row.productId }
                        : []
                )
            }

            var tierByProduct: [UUID: (tier: SlotTier, sellThroughPct: Double)] = [:]
            for a in analyses { tierByProduct[a.productId] = (a.tier, a.sellThroughPct) }

            products = analyses
            slots = buildGridSlots(trays: trays, tierByProduct: tierByProduct)
            let open = try? await SlotChangeService.fetchOpenRequest(machineId: machineId)
            pendingTrayIds = Set((open?.items ?? []).map(\.trayId))
            rowCount = slots.reduce(0) { max($0, $1.row + 1) }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Apply swap

    /// Put a replacement for a slot on the machine's change request. The slot
    /// is rebuilt on the next refill tour, where the old stock is counted —
    /// nothing changes on the machine (or in `machine_trays`) now. Pending
    /// slots of the request are kept; the slot keeps its planned capacity,
    /// else its current one. Mirrors the PWA's `useMachineAnalysis.applySwap`.
    func applySwap(trayId: UUID, productId: UUID) async -> Bool {
        guard let machineId = lastMachineId else { return false }
        do {
            pendingTrayIds = try await SlotChangeService.queueProducts(
                machineId: machineId,
                changes: [(trayId: trayId, productId: productId)]
            )
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - AI insights

    /// Fetches (or, with `forceRefresh`, regenerates) AI recommendations for
    /// this machine via the `machine-insights` edge function. Expensive in
    /// Claude tokens server-side, hence on-demand rather than automatic, and
    /// cached 6h server-side unless force-refreshed.
    func fetchInsights(machineId: UUID, forceRefresh: Bool, locale: String) async {
        insightsLoading = true
        insightsError = nil
        defer { insightsLoading = false }

        struct Body: Encodable {
            let machine_id: String
            let days: Int
            let force_refresh: Bool
            let locale: String
            let type: String
        }
        do {
            insights = try await client.functions.invoke(
                "machine-insights",
                options: .init(body: Body(
                    machine_id: machineId.uuidString, days: days,
                    force_refresh: forceRefresh, locale: locale, type: "machine"
                ))
            )
        } catch is CancellationError {
        } catch {
            insightsError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Fetches the current user's company_id from organization_members.
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
            throw NSError(domain: "MachineAnalysisVM", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not determine company")])
        }
        return companyId
    }
}
