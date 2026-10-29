import Foundation
import Supabase

// MARK: - Refill Data Structures

/// A machine that needs refilling, with its trays and deficit info.
struct RefillMachine: Identifiable, Equatable, Codable {
    let machine: VendingMachine
    var trays: [RefillTray]
    var isPacked: Bool = false
    var isRefilled: Bool = false
    var isSkipped: Bool = false
    /// Tour health, fixed when the tour list is built (warehouse-aware, see
    /// `RefillWizardViewModel.buildRefillMachines`). Optional so tours saved
    /// by older builds (without the key) still decode.
    var health: StockHealth? = nil
    /// Refillable products that are sold out or low — the tie-breaker of the
    /// tour order. Optional for the same reason as `health`.
    var urgentProductCount: Int? = nil
    /// Open slot change request of the machine, shown as a change note
    /// ("Änderungsvermerk"). While packing it holds every pending slot; once
    /// the tour started only the slots the refiller accepted. Optional so
    /// tours saved by older builds still decode.
    var changeRequest: SlotChangeRequest? = nil

    var id: UUID { machine.id }

    /// Total items needed across all trays.
    var totalDeficit: Int {
        trays.reduce(0) { $0 + $1.deficit }
    }

    /// Number of trays that need refilling.
    var traysNeedingRefill: Int {
        trays.filter { $0.deficit > 0 }.count
    }

    /// Total current stock across all trays.
    var totalCurrentStock: Int {
        trays.reduce(0) { $0 + $1.tray.currentStock }
    }

    /// Total capacity across all trays.
    var totalCapacity: Int {
        trays.reduce(0) { $0 + $1.tray.capacity }
    }

    /// Overall stock percentage.
    var stockPercent: Int {
        guard totalCapacity > 0 else { return 0 }
        return Int((Double(totalCurrentStock) / Double(totalCapacity) * 100).rounded())
    }

    /// Tour health: critical if a refillable product group is sold out, low
    /// if one is low, else fill (mirrors the PWA's `initTour`). Tours saved
    /// before `health` existed fall back to the product groups alone.
    var stockHealth: StockHealth {
        if let health { return health }
        let groups = MachineStockHealth.groupTraysByProduct(trays.map(\.tray)).filter(\.needsRefill)
        if groups.contains(where: { $0.state == .critical }) { return .critical }
        if groups.contains(where: { $0.state == .low }) { return .low }
        return groups.isEmpty ? .ok : .fill
    }

    /// Products needed with quantities (aggregated for packing).
    var productsNeeded: [PackingItem] {
        var items: [UUID: PackingItem] = [:]
        for tray in trays where tray.deficit > 0 {
            if let productId = tray.tray.productId {
                if var existing = items[productId] {
                    existing.quantity += tray.deficit
                    items[productId] = existing
                } else {
                    items[productId] = PackingItem(
                        productId: productId,
                        productName: tray.tray.productName,
                        imagePath: tray.tray.products?.imagePath,
                        sellprice: tray.tray.products?.sellprice,
                        quantity: tray.deficit
                    )
                }
            }
        }
        return Array(items.values).sorted { $0.productName < $1.productName }
    }
}

/// A tray within the refill flow, tracking how much to add.
struct RefillTray: Identifiable, Equatable, Codable {
    let tray: Tray
    var fillAmount: Int  // How many items to add (user can adjust)
    /// Whether this tray is included in the currently active refill tour.
    /// Set in `startTour()` based on which products were packed:
    /// - Product-less trays: always `true` (user refills them manually)
    /// - Product trays: `true` only when the product was packed for this machine
    /// The RefillStepView filters by this flag, so reducing `fillAmount` to 0
    /// does not hide a tray that the user packed.
    var isInTour: Bool = true

    var id: UUID { tray.id }

    var deficit: Int { tray.deficit }
    var targetStock: Int { tray.currentStock + fillAmount }

    private enum CodingKeys: String, CodingKey {
        case tray, fillAmount, isInTour
    }

    init(tray: Tray, fillAmount: Int, isInTour: Bool = true) {
        self.tray = tray
        self.fillAmount = fillAmount
        self.isInTour = isInTour
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tray = try container.decode(Tray.self, forKey: .tray)
        self.fillAmount = try container.decode(Int.self, forKey: .fillAmount)
        // Default to `true` so previously saved tour state (without this field)
        // decodes cleanly — all saved trays were part of the tour they belonged to.
        self.isInTour = try container.decodeIfPresent(Bool.self, forKey: .isInTour) ?? true
    }
}

/// An item to pack from the warehouse.
struct PackingItem: Identifiable, Equatable {
    let productId: UUID
    let productName: String
    let imagePath: String?
    let sellprice: Double?
    var quantity: Int

    var id: UUID { productId }
}

// MARK: - Combined Packing Structures

/// A product grouped across all machines that need it.
struct CombinedPackingItem: Identifiable, Equatable {
    let productId: UUID
    let productName: String
    let imagePath: String?
    let sellprice: Double?
    let totalQuantity: Int
    let machineNeeds: [MachineNeed]

    var id: UUID { productId }

    /// Formatted EUR price for display, or `nil` when no price is set.
    var formattedSellprice: String? {
        guard let price = sellprice else { return nil }
        return String(format: "%.2f \u{20AC}", price)
    }
}

/// One machine's need for a specific product.
struct MachineNeed: Identifiable, Equatable {
    let machineId: UUID
    let machineName: String
    let quantity: Int
    let capacity: Int

    var id: UUID { machineId }
}

// MARK: - Tour Log

/// Per-machine result entry for the tour log.
struct TourLogEntry: Equatable, Codable {
    let machineId: UUID
    let machineName: String
    let traysRefilled: Int
    let totalAdded: Int
    let skipped: Bool
    /// Slots switched to their new product at this stop (slot change
    /// request). Optional so tour logs saved by older builds still decode.
    var slotsRebuilt: Int? = nil
}

// MARK: - Product Replacement

enum ReplacementReason: String, Codable {
    case discontinued
    case expired
    case noStock  // Product has zero warehouse stock AND tray is empty
    case unassigned  // Tray has no product assigned yet
}

/// A tray that should be reviewed before packing — product is discontinued,
/// expired, out of stock, or not assigned at all.
struct ReplacementSuggestion: Identifiable, Equatable, Codable {
    let trayId: UUID
    let machineId: UUID
    let machineName: String
    let slotNumber: Int
    /// `nil` when the tray has no product assigned (reason: `.unassigned`).
    let currentProductId: UUID?
    let currentProductName: String
    let currentProductImage: String?
    let currentStock: Int
    let reason: ReplacementReason
    var replacementProductId: UUID?
    var isSkipped: Bool = false

    var id: UUID { trayId }
}

/// A product taken out of a machine within the company's cool-down
/// (`companies.product_removal_cooldown_days`, default 30) and not back in it
/// since. The replacement picker marks it and sorts it last, so a slow seller
/// with warehouse stock left does not walk straight back into the machine it
/// was just taken out of. Read from `get_recent_product_removals` — Android
/// reads the same RPC (`RecentRemovals.kt`).
struct RecentRemoval: Decodable, Equatable {
    let machineId: UUID
    let productId: UUID
    let removedAt: Date
    /// Start of the offering that ended; `nil` only for one that predates the
    /// offering history.
    let offeredSince: Date?
    /// Whole days between `offeredSince` and `removedAt`, at least 1.
    let daysOffered: Int?
    /// Sales of the product in this machine during that offering.
    let unitsSold: Int
    /// Removed before removals were recorded: the date is the slot change
    /// that took it out, else its last sale.
    let estimated: Bool

    enum CodingKeys: String, CodingKey {
        case machineId = "machine_id"
        case productId = "product_id"
        case removedAt = "removed_at"
        case offeredSince = "offered_since"
        case daysOffered = "days_offered"
        case unitsSold = "units_sold"
        case estimated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineId = try c.decode(UUID.self, forKey: .machineId)
        productId = try c.decode(UUID.self, forKey: .productId)
        removedAt = try c.decode(Date.self, forKey: .removedAt)
        offeredSince = try c.decodeIfPresent(Date.self, forKey: .offeredSince)
        daysOffered = try c.decodeIfPresent(Int.self, forKey: .daysOffered)
        unitsSold = try c.decodeIfPresent(Int.self, forKey: .unitsSold) ?? 0
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
    }
}

// MARK: - Slot Rebuild (change note)

/// One slot of the change note, as handled at the machine.
struct RebuildSlot: Identifiable, Equatable {
    let item: SlotChangeRequestItem
    /// Stock in the slot right now (sales since packing already deducted).
    var liveStock: Int
    /// Units of the old product taken out (editable, defaults to `liveStock`).
    var removed: Int
    var removedTouched: Bool = false
    /// Units of the new product put in (editable, defaults to the fill plan).
    var filled: Int
    var filledTouched: Bool = false
    /// Fill plan split of the suggestion.
    var moved: Int = 0
    var fromVan: Int = 0
    /// `nil` until the refiller marks the slot rebuilt / not rebuilt.
    var action: SlotChangeAction? = nil
    var priceSet: Bool = false
    /// The refiller confirmed the machine's age setting was changed. A slot
    /// whose age restriction changes (`item.changesAge`) can only be marked
    /// rebuilt once this is ticked.
    var ageSet: Bool = false

    /// "Rebuilt" is blocked until the age setting is confirmed.
    var needsAgeConfirmation: Bool { item.changesAge && !ageSet }

    var id: UUID { item.id }
}

/// Where leftover goods of a rebuild go.
enum LeftoverDestination: String, Codable {
    case warehouse
    case waste
}

/// Goods left over at the current machine, per product.
struct RebuildLeftover: Identifiable, Equatable {
    let productId: UUID
    let name: String?
    let imagePath: String?
    /// Packed for the rebuild but not used.
    let van: Int
    /// Taken out of the machine and not put into another slot.
    let machine: Int

    var id: UUID { productId }
    var total: Int { van + machine }
}

/// A product packed only for slot rebuilds (packing step): its own violet row
/// in the normal packing list, in warehouse order.
struct RebuildPackRow: Identifiable, Equatable {
    let productId: UUID
    let name: String?
    let imagePath: String?
    /// What the accepted slots need from the warehouse.
    let need: Int
    /// What the warehouse covers (≤ need when it runs short) — committed and
    /// deducted at tour start whether or not the row is ticked.
    let packed: Int
    /// Machines (in scope) whose rebuild needs the product.
    let machineIds: [UUID]

    var id: UUID { productId }
}

/// What one machine's accepted slots need of a product from the warehouse
/// (packing step, one rebuild stepper each).
struct RebuildMachineNeed: Identifiable, Equatable {
    let machineId: UUID
    let need: Int

    var id: UUID { machineId }
}

/// One row of the packing list.
enum PackRow: Identifiable, Equatable {
    /// A normal refill product; `rebuild` = rebuild units committed for it
    /// on top (violet "+N rebuild" badge), 0 for none.
    case product(CombinedPackingItem, rebuild: Int)
    /// A product needed only for slot rebuilds.
    case rebuild(RebuildPackRow)

    var id: UUID {
        switch self {
        case .product(let item, _): return item.productId
        case .rebuild(let row): return row.productId
        }
    }
}

// MARK: - Refill Steps

enum RefillStep: Int, CaseIterable {
    case review = 0
    case packing = 1
    case refill = 2
    case summary = 3

    var title: String {
        switch self {
        case .review: return String(localized: "Review")
        case .packing: return String(localized: "Pack")
        case .refill: return String(localized: "Refill")
        case .summary: return String(localized: "Summary")
        }
    }

    var icon: String {
        switch self {
        case .review: return "exclamationmark.triangle"
        case .packing: return "archivebox"
        case .refill: return "arrow.clockwise"
        case .summary: return "checkmark.circle"
        }
    }
}

// MARK: - Pack Chip Filter

/// Filter chip selection in the Pack step. `.all` shows the full
/// product-centric combined list (today's behavior); `.machine(id)` filters
/// the list to just the products needed for that one machine. In-memory
/// only — not persisted in `PersistedTourState` because the Pack step
/// itself is never persisted.
enum ChipFilter: Equatable, Hashable {
    case all
    case machine(UUID)
}

// MARK: - ViewModel

/// Multi-step refill wizard: packing -> refill per machine -> summary.
@MainActor
final class RefillWizardViewModel: ObservableObject {
    // MARK: - Published State

    @Published var currentStep: RefillStep = .review
    @Published var machines: [RefillMachine] = []
    /// Unfiltered tray list per machine, keyed by machine id. `machines[*].trays`
    /// only contains trays that need refill action (deficit > 0 + below threshold);
    /// the review picker needs every tray in the machine to render the
    /// "already in slot N" badge for products that are stocked elsewhere in
    /// the same machine. Populated alongside `machines` in `loadData()` and
    /// `refreshDuringPacking()`.
    @Published var allTraysByMachine: [UUID: [Tray]] = [:]
    @Published var replacements: [ReplacementSuggestion] = []
    /// All active (non-discontinued) products for the replacement picker.
    @Published var availableProducts: [Product] = []
    /// Product categories used to label/group products in the replacement
    /// picker. Loaded alongside `availableProducts` in `loadData()`.
    @Published var productCategories: [ProductCategory] = []
    /// machine id → product id → removal: products taken out of a machine
    /// within the cool-down, marked and sorted last in the replacement
    /// picker. Empty when the lookup fails — advice, never a blocker.
    @Published var recentRemovals: [UUID: [UUID: RecentRemoval]] = [:]
    /// Set after review step completes, so re-loading data doesn't re-trigger review.
    private var reviewCompleted = false
    @Published var warehouses: [Warehouse] = []
    @Published var selectedWarehouseId: UUID?
    @Published var warehouseStock: [WarehouseProductStock] = []
    /// product_id → 0-based index in the warehouse's physical pick order
    /// (depth-first through position groups). Empty when no positions are
    /// defined for the selected warehouse, in which case pack lists fall back
    /// to a quantity-based sort.
    @Published var warehouseProductOrder: [UUID: Int] = [:]
    @Published var currentMachineIndex: Int = 0
    /// Active filter chip in the Pack step. Resets to `.all` whenever
    /// `loadData()` runs (fresh start). Snap-back to `.all` if the active
    /// machine vanishes from `chipOrder` (defensive — shouldn't happen mid-tour).
    @Published var activeChip: ChipFilter = .all
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var error: String?

    /// Packed state: machineId → Set of productIds that have been packed for that machine.
    @Published var packedItems: [UUID: Set<UUID>] = [:]

    /// Custom packing quantities: machineId → (productId → quantity).
    /// If not set, defaults to the tray deficit.
    @Published var customQuantities: [UUID: [UUID: Int]] = [:]

    /// Per-machine results recorded during the refill step.
    @Published var tourLog: [TourLogEntry] = []

    /// Tray IDs whose `currentStock` changed due to a sale AFTER the tour
    /// started. `refreshDuringRefill()` populates this; the RefillStepView
    /// renders a small "sold-during-tour" badge on flagged trays so the
    /// user notices the delta before confirming.
    @Published var staleStockTrayIds: Set<UUID> = []

    // MARK: Slot change requests ("Änderungsvermerk")
    //
    // A machine's open change request rides along in
    // `RefillMachine.changeRequest`. The refiller accepts (default) or declines
    // each slot while packing; accepted slots leave the normal refill and their
    // units join the normal packing list (violet). At the machine they are
    // rebuilt and quit via `apply_slot_change`, before the normal refill of
    // the other slots; the leftovers are booked at the end of the tour.
    // Declined / skipped slots stay open server-side for a later tour.
    // Mirrors the PWA's `useRefillWizard.ts`.

    /// Open requests (pending slots only) by machine id, as last fetched.
    @Published var changeRequests: [UUID: SlotChangeRequest] = [:]
    /// Item id → accepted. Missing = accepted.
    @Published var rebuildDecisions: [UUID: Bool] = [:]
    /// Machine id → product id → units packed (deducted) for rebuilds.
    @Published var rebuildPacked: [UUID: [UUID: Int]] = [:]
    /// Packing step: machine id → product id → rebuild units the refiller
    /// dialled in (e.g. only half a spiral of a new product). Missing = the
    /// full need.
    @Published var rebuildCustomQuantities: [UUID: [UUID: Int]] = [:]
    /// Rebuild cards of the machine in `currentRebuildMachineId`.
    @Published var currentRebuild: [RebuildSlot] = []
    @Published private(set) var currentRebuildMachineId: UUID?
    /// Packing step: machine id → products whose rebuild-only row was ticked
    /// as packed. Like a normal product, only ticked units are booked.
    @Published var rebuildPackTicks: [UUID: Set<UUID>] = [:]

    // MARK: Tour leftovers (booked at the end of the tour)
    //
    // At the machine `apply_slot_change` only switches the slots. What is
    // left over (packed but unused, taken out of the machine) rides along and
    // is booked on the summary step, back at the warehouse, via
    // `return_slot_change_leftovers` — once for the whole tour.

    /// Machine id → that machine's leftovers. Overwritten per machine.
    @Published var tourLeftovers: [UUID: [TourLeftover]] = [:]
    /// The tour's leftovers have been booked.
    @Published var tourLeftoversReturned = false
    /// Summary step: counted quantities per product (missing = computed).
    @Published var leftoverVanQty: [UUID: Int] = [:]
    @Published var leftoverMachineQty: [UUID: Int] = [:]
    /// Product id → destination of its leftovers (missing = warehouse).
    @Published var leftoverDestinations: [UUID: LeftoverDestination] = [:]
    /// Product id → best-before date ("yyyy-MM-dd") for goods taken out of
    /// the machines.
    @Published var leftoverExpiry: [UUID: String] = [:]
    /// Best-before suggestions were loaded for this tour.
    private var expirySuggestionsLoaded = false
    /// Short confirmation after review-step replacements were queued into
    /// change requests (shown on the packing step).
    @Published var replacementNotice: String?
    /// Machine whose rebuild cards are being loaded (guards double loads).
    private var preparingRebuildFor: UUID?

    // MARK: Notes for the next tour
    //
    // Open `machine_tour_notes`, shown at the top of the packing step of
    // every tour until the refiller ticks them off
    // (`complete_machine_tour_notes`). Only the packing step reads them, so
    // they are not part of the persisted tour state. Mirrors the PWA's
    // `useRefillWizard.ts`.

    /// Open notes shown on the packing step (oldest first).
    @Published var tourNotes: [MachineTourNote] = []
    /// Last failure ticking a note off, shown under the notes card.
    @Published var tourNoteError: String?

    /// Raw data of the last load, kept so the tour list can be rebuilt when
    /// the refiller accepts or declines a slot of a change note.
    private var lastAllMachines: [VendingMachine] = []
    private var lastAllTrays: [Tray] = []
    private var lastWarehouseProductIds: Set<UUID> = []
    private var lastHasWarehouses = false

    /// Unique tour identifier, used to group activity log entries.
    private(set) var tourId: String = ""

    /// Whether we found a saved tour that can be resumed.
    @Published var hasSavedTour: Bool = false

    /// Guards the wizard's one-time entry decision (resume-vs-load).
    ///
    /// SwiftUI ties `.task` to appear/disappear, and `TabView` fires those on
    /// every tab switch — so `RefillWizardView.task` re-runs each time the user
    /// returns to the Refill tab. Without this gate, a return mid-tour re-runs
    /// `checkForSavedTour()` and re-offers "Resume Tour?", and resuming
    /// overwrites the live tray stock with the saved tour-start snapshot while
    /// leaving the "sold during tour" badges set (the reported icon-present /
    /// stock-reverted-to-Anfangsbestand desync). Set once on first entry;
    /// cleared only by `reset()` so a brand-new tour reloads fresh.
    private(set) var didRunInitialLoad = false

    private let client = SupabaseService.shared.client

    // MARK: - Persistence

    /// Today's date as "YYYY-MM-DD" for expiry comparisons.
    private static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static let storageKey = "refill-tour-state"
    /// Max age of persisted state: 24 hours (matches web).
    private static let maxAgeSeconds: TimeInterval = 24 * 60 * 60

    /// Codable snapshot of tour state for persistence.
    private struct PersistedTourState: Codable {
        let currentStep: String // "packing" | "refill" | "summary"
        let machines: [RefillMachine]
        let currentMachineIndex: Int
        let selectedWarehouseId: UUID?
        let tourId: String
        let tourLog: [TourLogEntry]
        /// Units packed for slot rebuilds (machine → product → qty). The
        /// accepted slots themselves travel in `machines[*].changeRequest`.
        /// Optional so tours saved by older builds still decode.
        var rebuildPacked: [UUID: [UUID: Int]]? = nil
        /// Slot change leftovers waiting for the end of the tour, and whether
        /// they were booked. Optional for tours saved by older builds.
        var tourLeftovers: [UUID: [TourLeftover]]? = nil
        var tourLeftoversReturned: Bool? = nil
        let savedAt: Date
    }

    /// The saved tour still has slot change leftovers that were not booked.
    static var savedTourHasUnreturnedLeftovers: Bool {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(PersistedTourState.self, from: data),
              state.tourLeftoversReturned != true else { return false }
        return !SlotChange.aggregateTourLeftovers(state.tourLeftovers ?? [:], machineOrder: []).isEmpty
    }

    /// Lightweight static check: is there a valid saved tour?
    static var hasSavedTourState: Bool {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return false }
        guard let state = try? JSONDecoder().decode(PersistedTourState.self, from: data) else { return false }
        if Date().timeIntervalSince(state.savedAt) > maxAgeSeconds { return false }
        return state.currentStep == "refill" || state.currentStep == "summary"
    }

    /// Claim the wizard's one-time entry decision. Returns `true` exactly once
    /// per VM lifetime (until `reset()`); every later call — i.e. every tab
    /// re-selection that re-fires `.task` — returns `false` so the view skips
    /// the resume/load decision and leaves the in-memory tour untouched.
    func beginInitialLoadIfNeeded() -> Bool {
        guard !didRunInitialLoad else { return false }
        didRunInitialLoad = true
        return true
    }

    /// Check for a saved tour on launch.
    func checkForSavedTour() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else {
            hasSavedTour = false
            return
        }
        do {
            let state = try JSONDecoder().decode(PersistedTourState.self, from: data)
            // Check TTL
            if Date().timeIntervalSince(state.savedAt) > Self.maxAgeSeconds {
                Self.clearSavedTour()
                hasSavedTour = false
                return
            }
            // Only resume if in refill or summary step
            hasSavedTour = (state.currentStep == "refill" || state.currentStep == "summary")
        } catch {
            hasSavedTour = false
        }
    }

    /// Resume a previously saved tour. Returns true if successful.
    func resumeTour() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return false }
        do {
            let state = try JSONDecoder().decode(PersistedTourState.self, from: data)
            if Date().timeIntervalSince(state.savedAt) > Self.maxAgeSeconds {
                Self.clearSavedTour()
                return false
            }
            guard state.currentStep == "refill" || state.currentStep == "summary" else { return false }

            // Restore state
            machines = state.machines
            currentMachineIndex = state.currentMachineIndex
            selectedWarehouseId = state.selectedWarehouseId
            tourId = state.tourId
            tourLog = state.tourLog
            rebuildPacked = state.rebuildPacked ?? [:]
            tourLeftovers = state.tourLeftovers ?? [:]
            tourLeftoversReturned = state.tourLeftoversReturned ?? false
            // Rebuild cards are rebuilt from live stock when the machine is
            // shown again (`prepareRebuild`).
            resetCurrentRebuild()
            // The snapshot holds tour-start stock; "sold during tour" badges
            // are not persisted. Start clean and let the caller's live refresh
            // (RefillWizardView) re-flag any trays that actually dropped, so a
            // resumed tour never shows a badge against a stale baseline.
            staleStockTrayIds = []

            switch state.currentStep {
            case "refill": currentStep = .refill
            case "summary": currentStep = .summary
            default: return false
            }

            hasSavedTour = false
            return true
        } catch {
            print("[RefillWizard] Failed to restore tour: \(error)")
            return false
        }
    }

    /// Save current tour state to UserDefaults.
    private func saveTourState() {
        guard currentStep == .refill || currentStep == .summary else { return }

        let stepString: String
        switch currentStep {
        case .review, .packing: return // nothing to persist before tour starts
        case .refill: stepString = "refill"
        case .summary: stepString = "summary"
        }

        let state = PersistedTourState(
            currentStep: stepString,
            machines: machines,
            currentMachineIndex: currentMachineIndex,
            selectedWarehouseId: selectedWarehouseId,
            tourId: tourId,
            tourLog: tourLog,
            rebuildPacked: rebuildPacked,
            tourLeftovers: tourLeftovers,
            tourLeftoversReturned: tourLeftoversReturned,
            savedAt: Date()
        )

        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            print("[RefillWizard] Failed to save tour state: \(error)")
        }
    }

    /// Clear any saved tour state.
    static func clearSavedTour() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - Tour Summary (computed from tourLog)

    var machinesVisited: Int { tourLog.filter { !$0.skipped }.count }
    var traysRefilled: Int { tourLog.reduce(0) { $0 + $1.traysRefilled } }
    var totalItemsAdded: Int { tourLog.reduce(0) { $0 + $1.totalAdded } }
    var machinesSkipped: Int { tourLog.filter { $0.skipped }.count }
    /// Slots switched to their new product during the tour ("Fächer umgebaut").
    var slotsRebuilt: Int { tourLog.reduce(0) { $0 + ($1.slotsRebuilt ?? 0) } }

    /// Look up warehouse stock for a product.
    func warehouseStockFor(productId: UUID) -> WarehouseProductStock? {
        warehouseStock.first { $0.productId == productId }
    }

    /// Total quantity already committed (packed) for a product across ALL machines.
    /// Slot rebuilds (accepted change-note slots) are included: they get the
    /// first claim on warehouse stock, like in the PWA.
    func committedQuantity(productId: UUID) -> Int {
        var total = rebuildCommittedTotal(productId: productId)
        for machine in machines {
            guard packedItems[machine.id]?.contains(productId) == true else { continue }
            total += packingQuantity(machineId: machine.id, productId: productId)
        }
        return total
    }

    /// Remaining warehouse stock for a product after subtracting committed quantities.
    func remainingWarehouseStock(productId: UUID) -> Int {
        guard let stock = warehouseStockFor(productId: productId) else { return 0 }
        return max(0, stock.totalQuantity - committedQuantity(productId: productId))
    }

    /// Look up the category UUID of the product currently in the tray being
    /// replaced. Returns `nil` if (a) no `ReplacementSuggestion` exists for
    /// this tray, (b) the suggestion has no current product (unassigned
    /// slot), (c) the current product isn't in `availableProducts`, or
    /// (d) the product is uncategorized. The replacement picker uses this
    /// to highlight the matching category first.
    func currentCategoryId(forTrayId trayId: UUID) -> UUID? {
        guard let pid = replacements.first(where: { $0.trayId == trayId })?.currentProductId
        else { return nil }
        return availableProducts.first(where: { $0.id == pid })?.category
    }

    /// Whether a product is completely out of warehouse stock (nothing left to pack).
    func isOutOfWarehouseStock(productId: UUID) -> Bool {
        // If no warehouse is selected or no stock data loaded, don't restrict
        guard selectedWarehouseId != nil, !warehouseStock.isEmpty else { return false }
        return remainingWarehouseStock(productId: productId) <= 0
    }

    /// Whether a specific machine-product pair is out of remaining warehouse stock.
    /// Takes into account stock already committed by other machines.
    func isOutOfStockForMachine(machineId: UUID, productId: UUID) -> Bool {
        guard selectedWarehouseId != nil, !warehouseStock.isEmpty else { return false }
        let isPacked = isMachinePacked(machineId: machineId, productId: productId)
        if isPacked {
            // Already committed — it has its allocation
            return false
        }
        return remainingWarehouseStock(productId: productId) <= 0
    }

    // MARK: - Combined Packing List

    /// Products grouped across all machines, sorted by warehouse pick order
    /// when available (see `warehouseProductOrder`), else by total quantity
    /// descending.
    var combinedPackingList: [CombinedPackingItem] {
        var grouped: [UUID: (name: String, image: String?, sellprice: Double?, total: Int, needs: [MachineNeed])] = [:]

        for machine in machines {
            for tray in machine.trays where tray.deficit > 0 {
                guard let productId = tray.tray.productId else { continue }
                let need = MachineNeed(
                    machineId: machine.id,
                    machineName: machine.machine.displayName,
                    quantity: tray.deficit,
                    capacity: tray.tray.capacity
                )
                if var existing = grouped[productId] {
                    // Check if this machine already has an entry (multiple trays same product)
                    if let idx = existing.needs.firstIndex(where: { $0.machineId == machine.id }) {
                        let old = existing.needs[idx]
                        existing.needs[idx] = MachineNeed(
                            machineId: machine.id,
                            machineName: machine.machine.displayName,
                            quantity: old.quantity + tray.deficit,
                            capacity: old.capacity + tray.tray.capacity
                        )
                    } else {
                        existing.needs.append(need)
                    }
                    existing.total += tray.deficit
                    grouped[productId] = existing
                } else {
                    grouped[productId] = (
                        name: tray.tray.productName,
                        image: tray.tray.products?.imagePath,
                        sellprice: tray.tray.products?.sellprice,
                        total: tray.deficit,
                        needs: [need]
                    )
                }
            }
        }

        let items = grouped.map { (productId, data) in
            CombinedPackingItem(
                productId: productId,
                productName: data.name,
                imagePath: data.image,
                sellprice: data.sellprice,
                totalQuantity: data.total,
                machineNeeds: data.needs.sorted { $0.machineName < $1.machineName }
            )
        }

        // Sort by physical warehouse pick order so the user walks the
        // warehouse front-to-back only once. Matches the web's combinedPickList
        // sorting: positioned products first (in position order), then
        // unpositioned products alphabetically. Falls back to total-quantity
        // descending when no positions are defined for the warehouse.
        //
        // IMPORTANT: every tap on +/- in the Pack screen re-publishes state and
        // recomputes this list. `grouped` is a Swift Dictionary whose iteration
        // order is not guaranteed to be stable across instances, so the sort
        // comparator MUST produce a total order — no ties — or rows with equal
        // primary keys will swap positions between renders.
        let order = warehouseProductOrder
        return items.sorted {
            PackListOrder.isOrderedBefore(
                PackOrderKey(productId: $0.productId, name: $0.productName, quantity: $0.totalQuantity),
                PackOrderKey(productId: $1.productId, name: $1.productName, quantity: $1.totalQuantity),
                position: order
            )
        }
    }

    /// Products to display in the Pack step: `combinedPackingList` filtered
    /// so rows the user can't act on (no warehouse stock for the product,
    /// nothing packed yet) are hidden instead of rendered greyed out —
    /// they just waste screen space. Partially-packed products stay visible
    /// so the user can still uncheck or adjust their own commitments.
    var visibleCombinedPackingList: [CombinedPackingItem] {
        combinedPackingList.filter { item in
            let anyPacked = item.machineNeeds.contains { need in
                isMachinePacked(machineId: need.machineId, productId: item.productId)
            }
            if anyPacked { return true }
            return !isOutOfWarehouseStock(productId: item.productId)
        }
    }

    // MARK: - Chip Filter Helpers

    /// Chips displayed in the Pack step, in order: `.all` first, then every
    /// machine in `machines` order (matches the order surfaces in the rest of
    /// the wizard).
    var chipOrder: [ChipFilter] {
        [.all] + machines.map { .machine($0.id) }
    }

    /// Display name for a chip. `.all` uses the localized "All" label; a
    /// machine chip uses the machine's `displayName`.
    func chipName(_ chip: ChipFilter) -> String {
        switch chip {
        case .all:
            return String(localized: "All")
        case .machine(let id):
            return machines.first(where: { $0.id == id })?.machine.displayName ?? ""
        }
    }

    /// Potential box size for a chip — sum of `displayQuantity` over every
    /// `(machine, product)` pair that has a need AND is visible in the
    /// picklist. For `.all` the sum is across every machine; for
    /// `.machine(id)` only that one machine.
    ///
    /// Skips pairs that are out-of-warehouse-stock AND not yet packed —
    /// those don't render in the picklist, so they must not be counted
    /// in the chip badge either.
    ///
    /// Intentionally distinct from `totalItemsToPack` (which only sums
    /// across `packedMachines`). The chip shows "how big the box would be
    /// if fully packed", the bottom bar shows "how many items the tour
    /// will actually deliver".
    func chipItemCount(_ chip: ChipFilter) -> Int {
        let allMachineIds: [UUID]
        switch chip {
        case .all:
            allMachineIds = machines.map(\.id)
        case .machine(let id):
            allMachineIds = [id]
        }
        var total = 0
        for item in combinedPackingList {
            for need in item.machineNeeds where allMachineIds.contains(need.machineId) {
                let packed = isMachinePacked(machineId: need.machineId, productId: item.productId)
                let outOfStock = isOutOfStockForMachine(machineId: need.machineId, productId: item.productId)
                if outOfStock && !packed { continue }
                total += displayQuantity(machineId: need.machineId, productId: item.productId)
            }
        }
        return total
    }

    /// True when every needed `(machine, product)` pair for the chip is
    /// both checked AND packed at the full required quantity. For `.all`
    /// this requires every machine chip to be fully packed.
    func chipIsFullyPacked(_ chip: ChipFilter) -> Bool {
        switch chip {
        case .all:
            let machineChips = chipOrder.dropFirst()
            guard !machineChips.isEmpty else { return false }
            return machineChips.allSatisfy(chipIsFullyPacked)
        case .machine(let id):
            var hadAnyNeed = false
            for item in combinedPackingList {
                guard let need = item.machineNeeds.first(where: { $0.machineId == id }) else { continue }
                let packed = isMachinePacked(machineId: id, productId: item.productId)
                let outOfStock = isOutOfStockForMachine(machineId: id, productId: item.productId)
                // Out-of-stock-and-unpacked pairs aren't in the picklist;
                // the user has no way to act on them, so they must not
                // block the chip from reaching "done".
                if outOfStock && !packed { continue }
                hadAnyNeed = true
                guard packed else { return false }
                // "Fully packed" = packed at the highest quantity currently
                // possible. If the warehouse can't satisfy the full deficit,
                // packing at maxPackingQuantity still counts as done — the
                // user has done all they can for this product. Without this,
                // any warehouse-capped pack flips the chip into a misleading
                // "alert" state on first pack.
                let qty = displayQuantity(machineId: id, productId: item.productId)
                let maxQty = maxPackingQuantity(machineId: id, productId: item.productId)
                guard qty >= min(need.quantity, maxQty) else { return false }
            }
            // A machine on the list only for its change note has nothing to
            // pack here — its box counts as done.
            return hadAnyNeed || machines.first(where: { $0.id == id })?.changeRequest != nil
        }
    }

    /// Number of distinct products needed for a chip, filtered to what
    /// actually appears in the picklist (out-of-stock-and-unpacked pairs
    /// are excluded, matching `chipItemCount` and `chipIsFullyPacked`).
    /// - `.all`: count across all machines (sums per-machine needs, may double-count
    ///   a product needed in N machines — that's correct because the chip view
    ///   shows N machine-need rows for it).
    /// - `.machine(id)`: count just that machine's needs.
    func chipNeedsCount(_ chip: ChipFilter) -> Int {
        let allMachineIds: [UUID]
        switch chip {
        case .all:
            allMachineIds = machines.map(\.id)
        case .machine(let id):
            allMachineIds = [id]
        }
        var count = 0
        for item in combinedPackingList {
            for need in item.machineNeeds where allMachineIds.contains(need.machineId) {
                let packed = isMachinePacked(machineId: need.machineId, productId: item.productId)
                let outOfStock = isOutOfStockForMachine(machineId: need.machineId, productId: item.productId)
                if outOfStock && !packed { continue }
                count += 1
            }
        }
        return count
    }

    /// Number of (machine, product) pairs currently ticked for a chip.
    /// For `.all`, counts ticked pairs across all machines.
    /// For `.machine(id)`, counts ticked pairs scoped to that machine.
    func chipPackedCount(_ chip: ChipFilter) -> Int {
        let machineIds: [UUID]
        switch chip {
        case .all:        machineIds = machines.map(\.id)
        case .machine(let id): machineIds = [id]
        }
        var count = 0
        for item in combinedPackingList {
            for need in item.machineNeeds where machineIds.contains(need.machineId) {
                if isMachinePacked(machineId: need.machineId, productId: item.productId) {
                    count += 1
                }
            }
        }
        return count
    }

    /// Items to render in the Pack step's list, dispatched on `activeChip`.
    ///
    /// - `.all`: passes through `visibleCombinedPackingList` unchanged (today's
    ///   behavior — product cards with expandable per-machine sub-rows).
    /// - `.machine(id)`: filters and rewrites — each returned `CombinedPackingItem`
    ///   carries exactly one `MachineNeed` (the active machine's) and its
    ///   `totalQuantity` is that machine's deficit. The same "hide if out-of-
    ///   stock and nothing-packed-yet" rule as `visibleCombinedPackingList`
    ///   applies, scoped to this one machine.
    var visibleItemsForActiveChip: [CombinedPackingItem] {
        switch activeChip {
        case .all:
            return visibleCombinedPackingList
        case .machine(let id):
            return visibleItems(machineId: id)
        }
    }

    /// One machine's rows of the packing list (see `visibleItemsForActiveChip`).
    func visibleItems(machineId id: UUID) -> [CombinedPackingItem] {
        combinedPackingList.compactMap { item in
            guard let need = item.machineNeeds.first(where: { $0.machineId == id }) else { return nil }
            let packed = isMachinePacked(machineId: id, productId: item.productId)
            let outOfStock = isOutOfStockForMachine(machineId: id, productId: item.productId)
            if outOfStock && !packed { return nil }
            return CombinedPackingItem(
                productId: item.productId,
                productName: item.productName,
                imagePath: item.imagePath,
                sellprice: item.sellprice,
                totalQuantity: need.quantity,
                machineNeeds: [need]
            )
        }
    }

    /// The packing list of a chip, in warehouse pick order: the normal rows,
    /// each with the rebuild units committed for its product on top (violet
    /// badge), plus a violet row for every product packed only for slot
    /// rebuilds. A product whose rebuild needs nothing from the warehouse
    /// (its stock only moves within the machine) gets no row. In the `.all`
    /// view rebuild units are summed over the machines.
    func packRows(for chip: ChipFilter) -> [PackRow] {
        let normal: [CombinedPackingItem]
        let machineIds: [UUID]
        switch chip {
        case .all:
            normal = visibleCombinedPackingList
            machineIds = machines.map(\.id)
        case .machine(let id):
            normal = visibleItems(machineId: id)
            machineIds = [id]
        }

        // What is (or would be) packed: committed once ticked, else the dialled amount.
        var shown: [UUID: [UUID: Int]] = [:]
        for machineId in machineIds {
            for (pid, need) in rebuildNeeds(machineId: machineId) where need > 0 {
                shown[machineId, default: [:]][pid] = rebuildQuantity(machineId: machineId, productId: pid)
            }
        }
        let committed = SlotChange.rebuildByProduct(shown, machineIds: machineIds)
        var needs: [UUID: Int] = [:]
        var needMachines: [UUID: [UUID]] = [:]
        var info: [UUID: (name: String?, image: String?)] = [:]
        for machineId in machineIds {
            for (pid, need) in rebuildNeeds(machineId: machineId) where need > 0 {
                needs[pid, default: 0] += need
                needMachines[pid, default: []].append(machineId)
            }
            for item in acceptedRebuildItems(machineId: machineId) {
                guard let to = item.toProductId, info[to] == nil else { continue }
                info[to] = (name: item.toName, image: item.toImagePath)
            }
        }

        let listed = Set(normal.map(\.productId))
        var rebuildRows: [UUID: RebuildPackRow] = [:]
        for (pid, need) in needs where !listed.contains(pid) {
            rebuildRows[pid] = RebuildPackRow(
                productId: pid,
                name: info[pid]?.name,
                imagePath: info[pid]?.image,
                need: need,
                packed: committed[pid] ?? 0,
                machineIds: needMachines[pid] ?? []
            )
        }

        let entries = PackListOrder.merge(
            normal: normal.map { PackOrderKey(productId: $0.productId, name: $0.productName, quantity: $0.totalQuantity) },
            rebuildOnly: rebuildRows.values.map { PackOrderKey(productId: $0.productId, name: $0.name ?? "", quantity: $0.packed) },
            position: warehouseProductOrder
        )
        let normalById = Dictionary(normal.map { ($0.productId, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.compactMap { entry in
            switch entry {
            case .normal(let pid):
                guard let item = normalById[pid] else { return nil }
                return .product(item, rebuild: committed[pid] ?? 0)
            case .rebuildOnly(let pid):
                return rebuildRows[pid].map { .rebuild($0) }
            }
        }
    }

    /// The rebuild-only row is ticked as packed for every machine it covers.
    func isRebuildRowTicked(_ row: RebuildPackRow) -> Bool {
        !row.machineIds.isEmpty
            && row.machineIds.allSatisfy { rebuildPackTicks[$0]?.contains(row.productId) == true }
    }

    /// Tick / untick a rebuild-only row: only ticked units are taken along
    /// and booked out of the warehouse.
    func toggleRebuildRowTick(_ row: RebuildPackRow) {
        let tick = !isRebuildRowTicked(row)
        for machineId in row.machineIds {
            var set = rebuildPackTicks[machineId] ?? []
            if tick { set.insert(row.productId) } else { set.remove(row.productId) }
            rebuildPackTicks[machineId] = set
        }
    }

    /// Whether a specific product is packed for a specific machine.
    func isMachinePacked(machineId: UUID, productId: UUID) -> Bool {
        packedItems[machineId]?.contains(productId) ?? false
    }

    /// Whether a product is fully packed for ALL machines that need it.
    func isProductFullyPacked(_ item: CombinedPackingItem) -> Bool {
        item.machineNeeds.allSatisfy { need in
            packedItems[need.machineId]?.contains(item.productId) ?? false
        }
    }

    /// Get the packing quantity for a machine-product pair (custom or default deficit).
    /// This is the "truth" used for commitment math and warehouse deduction. For
    /// UI display that should reflect the warehouse cap, use `displayQuantity`.
    func packingQuantity(machineId: UUID, productId: UUID) -> Int {
        if let custom = customQuantities[machineId]?[productId] {
            return custom
        }
        // Default: sum of deficits for this product in this machine's trays
        guard let machine = machines.first(where: { $0.id == machineId }) else { return 0 }
        return machine.trays
            .filter { $0.tray.productId == productId && $0.deficit > 0 }
            .reduce(0) { $0 + $1.deficit }
    }

    /// Quantity to show in the Pack UI for a machine-product pair.
    ///
    /// - For PACKED machines: returns `packingQuantity` (the actual committed value).
    /// - For UNCHECKED machines: caps to `maxPackingQuantity` so the UI never
    ///   advertises more items than the warehouse could actually deliver.
    ///
    /// Matches the web's `effectiveDeficit` behaviour. Keeps `packingQuantity`
    /// (used by `committedQuantity` / `maxPackingQuantity` / warehouse deduction)
    /// untouched so the commitment math stays precise.
    func displayQuantity(machineId: UUID, productId: UUID) -> Int {
        let current = packingQuantity(machineId: machineId, productId: productId)
        if isMachinePacked(machineId: machineId, productId: productId) {
            return current
        }
        let cap = maxPackingQuantity(machineId: machineId, productId: productId)
        return Swift.min(current, cap)
    }

    /// Max packing quantity for a machine-product pair.
    /// Capped by both tray capacity and remaining warehouse stock.
    func maxPackingQuantity(machineId: UUID, productId: UUID) -> Int {
        guard let machine = machines.first(where: { $0.id == machineId }) else { return 0 }
        let trayMax = machine.trays
            .filter { $0.tray.productId == productId }
            .reduce(0) { $0 + max(0, $1.tray.capacity - $1.tray.currentStock) }

        // If warehouse stock is loaded, also cap by remaining stock
        guard selectedWarehouseId != nil, !warehouseStock.isEmpty else { return trayMax }
        guard let stock = warehouseStockFor(productId: productId) else { return 0 }

        // Available = total warehouse stock minus what OTHER machines have
        // committed and what every slot rebuild has (rebuilds go first).
        let otherCommitted = machines
            .filter { $0.id != machineId && packedItems[$0.id]?.contains(productId) == true }
            .reduce(0) { $0 + packingQuantity(machineId: $1.id, productId: productId) }
        let available = max(0, stock.totalQuantity - otherCommitted - rebuildCommittedTotal(productId: productId))

        return min(trayMax, available)
    }

    /// Set a custom packing quantity for a machine-product pair.
    func setPackingQuantity(machineId: UUID, productId: UUID, quantity: Int) {
        let maxQty = maxPackingQuantity(machineId: machineId, productId: productId)
        let clamped = max(0, min(maxQty, quantity))
        var machineMap = customQuantities[machineId] ?? [:]
        machineMap[productId] = clamped
        customQuantities[machineId] = machineMap
    }

    /// Toggle packed state for one machine-product pair.
    /// Skips if out of warehouse stock when trying to pack.
    func togglePackedForMachine(productId: UUID, machineId: UUID) {
        var set = packedItems[machineId] ?? Set()
        if set.contains(productId) {
            set.remove(productId)
            // Clear custom quantity so it recalculates on re-pack
            customQuantities[machineId]?[productId] = nil
        } else {
            // Don't allow packing if out of stock
            guard !isOutOfStockForMachine(machineId: machineId, productId: productId) else { return }
            set.insert(productId)
            // Packed first, so the product's rebuild units (taken along now)
            // claim their stock before the quantity is capped.
            packedItems[machineId] = set
            // Auto-cap the quantity to remaining warehouse stock
            pinPackingQuantity(machineId: machineId, productId: productId)
        }
        packedItems[machineId] = set
        syncMachinePackedState()
    }

    /// Toggle packed state for a product across ALL machines that need it.
    func togglePackedAll(productId: UUID) {
        guard let item = combinedPackingList.first(where: { $0.productId == productId }) else { return }
        let allPacked = isProductFullyPacked(item)

        if allPacked {
            // Unpack all
            for need in item.machineNeeds {
                var set = packedItems[need.machineId] ?? Set()
                set.remove(productId)
                packedItems[need.machineId] = set
                customQuantities[need.machineId]?[productId] = nil
            }
        } else {
            // Pack all (with stock-aware capping, in urgency order)
            for need in item.machineNeeds {
                guard !isOutOfStockForMachine(machineId: need.machineId, productId: productId) else { continue }
                var set = packedItems[need.machineId] ?? Set()
                set.insert(productId)
                packedItems[need.machineId] = set
                pinPackingQuantity(machineId: need.machineId, productId: productId)
            }
        }
        syncMachinePackedState()
    }

    /// Pack all products for all machines (stock-aware).
    func packEverything() {
        // Rebuild units first: they get the first claim on the stock.
        tickAllRebuildRows(machineIds: machines.map(\.id))
        for item in combinedPackingList {
            for need in item.machineNeeds {
                guard !isOutOfStockForMachine(machineId: need.machineId, productId: item.productId) else { continue }
                var set = packedItems[need.machineId] ?? Set()
                set.insert(item.productId)
                packedItems[need.machineId] = set
                pinPackingQuantity(machineId: need.machineId, productId: item.productId)
            }
        }
        syncMachinePackedState()
    }

    /// Pin the packing quantity as an explicit `customQuantities` entry.
    ///
    /// Called at the moment the user packs a product (toggle-all, per-machine
    /// toggle, or "pack everything"). Without this, `packingQuantity` falls
    /// back to the tray deficit, which silently drifts under realtime
    /// refreshes: a sale widens the deficit and the displayed "packed"
    /// number moves under the user's fingers. Worse, if the warehouse can
    /// only partially satisfy the new default, the user walks away with
    /// fewer physical items than the UI implied.
    ///
    /// `setPackingQuantity` already clamps the input by `maxPackingQuantity`
    /// (tray-capacity + warehouse-remaining), so passing the current default
    /// pins exactly what the user intended at pack time. Any subsequent
    /// deficit/warehouse drift shows up via the `underpacked` border/badge
    /// rather than as an invisible adjustment.
    private func pinPackingQuantity(machineId: UUID, productId: UUID) {
        let currentQty = packingQuantity(machineId: machineId, productId: productId)
        setPackingQuantity(machineId: machineId, productId: productId, quantity: currentQty)
    }

    /// Sync machine isPacked flag: a machine is packed when at least one product is checked.
    private func syncMachinePackedState() {
        for i in machines.indices {
            let machine = machines[i]
            let packedProductIds = packedItems[machine.id] ?? Set()
            let neededProductIds = Set(machine.trays.compactMap { $0.tray.productId }.filter { pid in
                machine.trays.contains { $0.tray.productId == pid && $0.deficit > 0 }
            })
            // An accepted change note puts the machine on the tour too — a
            // pure swap needs no units but still a visit.
            machines[i].isPacked = !neededProductIds.isDisjoint(with: packedProductIds)
                || hasAcceptedRebuild(machine)
        }
    }

    /// Machines selected for the tour (all products packed).
    var packedMachines: [RefillMachine] {
        machines.filter { $0.isPacked }
    }

    /// Machines still remaining in the refill tour (packed, not yet done).
    var remainingMachines: [RefillMachine] {
        machines.filter { $0.isPacked && !$0.isRefilled && !$0.isSkipped }
    }

    /// Current machine being refilled.
    var currentMachine: RefillMachine? {
        let refillable = remainingMachines
        guard currentMachineIndex < refillable.count else { return nil }
        return refillable[currentMachineIndex]
    }

    /// Jump to a specific machine in the remaining list.
    func selectMachine(_ machineId: UUID) {
        let refillable = remainingMachines
        if let idx = refillable.firstIndex(where: { $0.id == machineId }) {
            currentMachineIndex = idx
        }
    }

    /// Progress fraction through machines.
    var machineProgress: (current: Int, total: Int) {
        let refillable = machines.filter { $0.isPacked }
        let done = machines.filter { $0.isPacked && ($0.isRefilled || $0.isSkipped) }.count
        return (min(done + 1, refillable.count), refillable.count)
    }

    /// Total items to pack across all packed machines (respects custom quantities).
    var totalItemsToPack: Int {
        var total = 0
        for machine in packedMachines {
            let productIds = Set(machine.trays.compactMap { $0.tray.productId })
            for productId in productIds {
                total += packingQuantity(machineId: machine.id, productId: productId)
            }
            // Plus what the machine's accepted change-note slots need.
            total += (committedRebuild[machine.id] ?? [:]).values.reduce(0, +)
        }
        return total
    }

    // MARK: - Load Data

    /// Build the list of machines that need refilling from raw machine/tray data.
    /// Mirrors the PWA's `initTour` (`useRefillWizard.ts`).
    ///
    /// Stock is judged per **product**, not per slot: all slots of a product in
    /// a machine form one group with summed stock/capacity/thresholds
    /// (`MachineStockHealth.groupTraysByProduct`, mirrors the PWA's
    /// `stock-health.ts`).
    ///
    /// Filter logic:
    /// 1. A machine is included when at least one product group that needs a
    ///    refill (`groupNeedsRefill`, top-off included) is **refillable** —
    ///    a positive batch exists in any warehouse of the company, or the
    ///    company has no warehouse stock at all
    ///    (`MachineStockHealth.isProductRefillable`).
    /// 2. Tour health: critical if a refillable group is sold out, low if one
    ///    is low, else fill.
    /// 3. Trays included: **every slot** of each product group that needs a
    ///    refill — non-refillable products too (the packing step greys them
    ///    out) — including slots that are already full; the packed quantity
    ///    is later spread across them emptiest-first
    ///    (`MachineStockHealth.distributeAcrossSlots`).
    /// 4. Unassigned slots (no product) never ride along.
    /// 5. Order: critical, low, fill; then more sold-out + low refillable
    ///    products first.
    /// 6. Slot change requests: slots with an accepted change
    ///    (`acceptedTrayIds`) are left out — they get the rebuild instead of
    ///    a normal refill — and a machine with an open request is listed even
    ///    when it needs no refill (its change note must show).
    ///
    /// Static so both `loadData()` and `refreshDuringPacking()` share identical filtering.
    private static func buildRefillMachines(
        allMachines: [VendingMachine],
        allTrays: [Tray],
        warehouseProductIds: Set<UUID>,
        hasWarehouses: Bool,
        requests: [UUID: SlotChangeRequest] = [:],
        acceptedTrayIds: Set<UUID> = []
    ) -> [RefillMachine] {
        let traysByMachine = Dictionary(grouping: allTrays, by: { $0.machineId })
        var refillMachines: [RefillMachine] = []

        for machine in allMachines {
            let machineTrays = (traysByMachine[machine.id] ?? []).filter { !acceptedTrayIds.contains($0.id) }
            let request = requests[machine.id]
            let hasRequest = !(request?.items.isEmpty ?? true)
            let groups = MachineStockHealth.groupTraysByProduct(machineTrays).filter(\.needsRefill)

            var empty = 0, low = 0, fill = 0
            for group in groups where MachineStockHealth.isProductRefillable(
                productId: group.productId,
                warehouseProductIds: warehouseProductIds,
                hasWarehouses: hasWarehouses
            ) {
                switch group.state {
                case .critical: empty += 1
                case .low: low += 1
                default: fill += 1
                }
            }
            guard empty + low + fill > 0 || hasRequest else { continue }

            let trayIdsInGroups = Set(groups.flatMap { $0.trays.map(\.id) })
            let refillTrays: [RefillTray] = machineTrays
                .filter { trayIdsInGroups.contains($0.id) }
                .map { RefillTray(tray: $0, fillAmount: $0.deficit) }
            guard !refillTrays.isEmpty || hasRequest else { continue }

            var refillMachine = RefillMachine(machine: machine, trays: refillTrays)
            refillMachine.health = empty > 0 ? .critical : low > 0 ? .low : fill > 0 ? .fill : .ok
            refillMachine.urgentProductCount = empty + low
            refillMachine.changeRequest = hasRequest ? request : nil
            refillMachines.append(refillMachine)
        }

        func rank(_ health: StockHealth) -> Int {
            switch health {
            case .critical: return 0
            case .low: return 1
            case .fill: return 2
            case .ok: return 3
            }
        }
        // Stable sort: ties keep the fetch order, like the PWA.
        return refillMachines.enumerated().sorted { a, b in
            let ra = rank(a.element.stockHealth), rb = rank(b.element.stockHealth)
            if ra != rb { return ra < rb }
            let ua = a.element.urgentProductCount ?? 0, ub = b.element.urgentProductCount ?? 0
            if ua != ub { return ua > ub }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Company-wide warehouse availability for the tour selection: product
    /// ids with a positive batch in **any** warehouse, and whether any batch
    /// exists at all (same presence check as the machine list and the PWA's
    /// `buildWarehouseStockInfo`).
    private func fetchCompanyWarehouseAvailability() async throws -> (productIds: Set<UUID>, hasWarehouses: Bool) {
        struct BatchRow: Decodable {
            let productId: UUID?
            enum CodingKeys: String, CodingKey { case productId = "product_id" }
        }
        let rows: [BatchRow] = try await client
            .from("warehouse_stock_batches")
            .select("product_id, quantity")
            .gt("quantity", value: 0)
            .execute()
            .value
        return (Set(rows.compactMap(\.productId)), !rows.isEmpty)
    }

    /// Display health of a tour machine, mirroring the PWA's
    /// `effectiveStockHealth`: a machine is shown as `ok` (dimmed) when none
    /// of its listed products has stock in the **selected** warehouse. Uses
    /// the raw warehouse stock, not what is left after packing, so packing
    /// the last unit doesn't collapse the machine.
    func effectiveStockHealth(_ machine: RefillMachine) -> StockHealth {
        let health = machine.stockHealth
        guard health != .ok, selectedWarehouseId != nil else { return health }
        let productIds = Set(machine.trays.compactMap(\.tray.productId))
        let hasRefillable = productIds.contains { pid in
            (warehouseStockFor(productId: pid)?.totalQuantity ?? 0) > 0
        }
        return hasRefillable ? health : .ok
    }

    /// Re-fetch machines/trays and warehouse stock in response to realtime
    /// sale/tray changes, preserving the user's in-progress packing state.
    ///
    /// Only runs during the **packing** step — that's where the user can
    /// observe deficits and pick products. During review the user is handling
    /// product replacements (unrelated to stock levels). During refill and
    /// summary the tour is already in progress / done, so silently mutating
    /// `machines` would destroy the user's tray-level fill amounts and
    /// `confirmRefill()` already re-fetches fresh stock before writing.
    ///
    /// Preserves: `packedItems`, `customQuantities`, `selectedWarehouseId`,
    /// `currentStep`, `replacements`, `reviewCompleted`.
    /// `isPacked` flags are re-derived from `packedItems` via `syncMachinePackedState()`.
    func refreshDuringPacking() async {
        // Only refresh in packing step — other steps own state we must not trample.
        guard currentStep == .packing else { return }
        // Avoid colliding with an in-progress initial load or save.
        guard !isLoading, !isSaving else { return }

        do {
            let allMachines: [VendingMachine] = try await client
                .from("vendingMachine")
                .select("id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")
                .execute()
                .value

            let allTrays: [Tray] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
                .order("item_number", ascending: true)
                .execute()
                .value

            let availability = try await fetchCompanyWarehouseAvailability()
            // Change requests are kept from the last full load: a refresh
            // must not pull a newly planned slot into a list being packed.
            storeTourSource(allMachines: allMachines, allTrays: allTrays, availability: availability)
            rebuildTourList()

            // `packedItems` keyed by machineId still applies to machines that are
            // still in the list; orphan entries for machines that no longer need
            // refilling are harmless (nothing reads them). Re-derive isPacked
            // flags from the preserved packedItems.
            syncMachinePackedState()

            // Warehouse stock may also have changed (another tour picking,
            // intake, adjustment). Refresh so the pack-quantity caps stay accurate.
            if let warehouseId = selectedWarehouseId {
                await loadWarehouseStock(warehouseId: warehouseId)
            }
        } catch {
            // Silent failure — the user's current UI is still usable, they
            // will just see stale data until the next event.
            print("[RefillWizard] refreshDuringPacking failed: \(error)")
        }

        // Snap-back: if the active machine vanished from chipOrder, drop to .all.
        // Cannot happen in normal mid-tour flow, but cheap insurance against
        // rendering a dangling chip selection.
        if case .machine(let id) = activeChip, !machines.contains(where: { $0.id == id }) {
            activeChip = .all
        }
    }

    /// Refresh the **display-only** tray stock during the refill step.
    ///
    /// Triggered by realtime sale/tray events. Updates each `tray.currentStock`
    /// in place so the user sees live values on the machine card — but
    /// deliberately leaves the rest of the tour state frozen:
    ///
    /// - `fillAmount` stays untouched. The warehouse was FIFO-deducted for
    ///   exactly this amount in `startTour()`; mutating it here would
    ///   desynchronise the warehouse ledger from what the user physically
    ///   packed into their cart.
    /// - `isInTour` stays untouched. A tray that newly crossed its
    ///   threshold mid-tour cannot be inserted, because no warehouse items
    ///   were packed for it.
    /// - Machine composition, order, and `isPacked`/`isRefilled`/`isSkipped`
    ///   flags stay untouched.
    ///
    /// Trays whose `currentStock` actually decreased get added to
    /// `staleStockTrayIds` so the UI can render a "sold during tour"
    /// badge. An increase (another user refilled this tray) is silently
    /// accepted — `confirmRefill` already clamps to capacity.
    func refreshDuringRefill() async {
        guard currentStep == .refill else { return }
        guard !isSaving else { return }

        // Only fetch stock for trays that are actually part of this tour.
        // Plus the slots of the change note being rebuilt right now, so
        // "taken out" follows sales until the refiller types a number.
        let tourTrayIds: [String] = machines
            .filter { !$0.isRefilled && !$0.isSkipped }
            .flatMap { m in m.trays.filter { $0.isInTour }.map { $0.tray.id.uuidString } }
            + currentRebuild.map(\.item.trayId.uuidString)
        guard !tourTrayIds.isEmpty else { return }

        struct StockRow: Decodable {
            let id: UUID
            let currentStock: Int
            enum CodingKeys: String, CodingKey {
                case id
                case currentStock = "current_stock"
            }
        }

        do {
            let rows: [StockRow] = try await client
                .from("machine_trays")
                .select("id, current_stock")
                .in("id", values: tourTrayIds)
                .execute()
                .value

            let freshById: [UUID: Int] = Dictionary(
                uniqueKeysWithValues: rows.map { ($0.id, $0.currentStock) }
            )

            var didChange = false

            for i in currentRebuild.indices {
                guard let fresh = freshById[currentRebuild[i].item.trayId],
                      fresh != currentRebuild[i].liveStock else { continue }
                currentRebuild[i].liveStock = fresh
                if !currentRebuild[i].removedTouched {
                    currentRebuild[i].removed = fresh
                }
            }
            recomputeRebuildFill()

            for mi in machines.indices {
                // Skip machines the user has already confirmed or skipped.
                guard !machines[mi].isRefilled, !machines[mi].isSkipped else { continue }

                for ti in machines[mi].trays.indices {
                    let rt = machines[mi].trays[ti]
                    guard let fresh = freshById[rt.tray.id] else { continue }
                    guard fresh != rt.tray.currentStock else { continue }
                    didChange = true

                    // Only flag *decreases* — a decrease means a sale happened.
                    // An increase means a competing refill already topped the
                    // tray up; no user attention needed.
                    if fresh < rt.tray.currentStock {
                        staleStockTrayIds.insert(rt.tray.id)
                    }

                    // Rebuild Tray with fresh currentStock only; preserve every
                    // other field. Tray properties are `let`, so we construct
                    // a new instance.
                    let oldTray = rt.tray
                    let newTray = Tray(
                        id: oldTray.id,
                        machineId: oldTray.machineId,
                        itemNumber: oldTray.itemNumber,
                        productId: oldTray.productId,
                        capacity: oldTray.capacity,
                        currentStock: fresh,
                        minStock: oldTray.minStock,
                        fillWhenBelow: oldTray.fillWhenBelow,
                        products: oldTray.products
                    )
                    // Preserve fillAmount and isInTour — the user's choice
                    // is already committed against the warehouse.
                    machines[mi].trays[ti] = RefillTray(
                        tray: newTray,
                        fillAmount: rt.fillAmount,
                        isInTour: rt.isInTour
                    )
                }
            }

            // Persist the live stock into the tour snapshot. `saveTourState()`
            // otherwise only runs at start/confirm/skip, so a resume (real app
            // kill mid-tour) would restore tour-start stock and silently drop
            // any sales that happened since. Only write when something changed.
            if didChange {
                saveTourState()
            }
        } catch {
            print("[RefillWizard] refreshDuringRefill failed: \(error)")
        }
    }

    /// Dispatcher: invoked by the view on every realtime tick and routes to
    /// the step-appropriate refresh (each step-specific method also guards
    /// on `currentStep`, so this is belt-and-braces).
    func refreshFromRealtime() async {
        switch currentStep {
        case .packing:
            await refreshDuringPacking()
        case .refill:
            await refreshDuringRefill()
        case .review, .summary:
            break
        }
    }

    func loadData() async {
        isLoading = true
        error = nil

        do {
            // Fetch machines with embeddeds
            print("[RefillWizard] Fetching machines...")
            let allMachines: [VendingMachine] = try await client
                .from("vendingMachine")
                .select("id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")
                .execute()
                .value
            print("[RefillWizard] Fetched \(allMachines.count) machines")

            // Fetch all trays
            print("[RefillWizard] Fetching trays...")
            let allTrays: [Tray] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
                .order("item_number", ascending: true)
                .execute()
                .value
            print("[RefillWizard] Fetched \(allTrays.count) trays")

            let availability = try await fetchCompanyWarehouseAvailability()
            // Open slot change requests become change notes. A failing lookup
            // must never block a normal tour.
            self.changeRequests = await fetchOpenChangeRequests(machineIds: allMachines.map(\.id))
            // Notes from the last tour — same rule: never block the tour.
            await loadTourNotes()
            storeTourSource(allMachines: allMachines, allTrays: allTrays, availability: availability)
            rebuildTourList()
            let traysByMachine = allTraysByMachine

            // Fetch warehouses first (needed for stock-based detection)
            print("[RefillWizard] Fetching warehouses...")
            warehouses = try await client
                .from("warehouses")
                .select("id, name, address, notes, company_id")
                .execute()
                .value
            print("[RefillWizard] Fetched \(warehouses.count) warehouses")

            if let firstWarehouse = warehouses.first {
                selectedWarehouseId = firstWarehouse.id
                await loadWarehouseStock(warehouseId: firstWarehouse.id)
            }

            // Detect trays needing product replacement (only on first load, not after review)
            if !reviewCompleted {
                // Fetch available (active) products for the replacement picker
                let activeProducts: [Product] = try await client
                    .from("products")
                    .select("id, name, image_path, discontinued, sellprice, category")
                    .or("discontinued.is.null,discontinued.eq.false")
                    .order("name", ascending: true)
                    .execute()
                    .value
                self.availableProducts = activeProducts

                // Load categories for the replacement picker's grouping UI.
                // Mirrors ProductsViewModel.loadCategories() — explicit column
                // list and alphabetical order so the decoder is safe against
                // future schema additions.
                let cats: [ProductCategory] = try await client
                    .from("product_category")
                    .select("id, name, company")
                    .order("name", ascending: true)
                    .execute()
                    .value
                self.productCategories = cats

                // Build warehouse stock lookup for "no stock" detection
                let warehouseProductIds = Set(warehouseStock.filter { $0.totalQuantity > 0 }.map(\.productId))

                // Detect expired products: all warehouse batches for a product have expired
                var expiredProductIds: Set<UUID> = []
                if let wId = selectedWarehouseId {
                    let allBatches: [WarehouseStockBatch] = try await client
                        .from("warehouse_stock_batches")
                        .select("id, warehouse_id, product_id, quantity, batch_number, expiration_date")
                        .eq("warehouse_id", value: wId.uuidString)
                        .gt("quantity", value: 0)
                        .execute()
                        .value

                    let today = Self.todayDateString()
                    let batchesByProduct = Dictionary(grouping: allBatches, by: { $0.productId })
                    for (productId, batches) in batchesByProduct {
                        let allHaveExpiry = batches.allSatisfy { $0.expirationDate != nil && !$0.expirationDate!.isEmpty }
                        let allExpired = batches.allSatisfy { batch in
                            guard let expDate = batch.expirationDate, !expDate.isEmpty else { return false }
                            return expDate < today
                        }
                        if allHaveExpiry && allExpired {
                            expiredProductIds.insert(productId)
                        }
                    }
                }

                // Scan ALL trays for replacement candidates. Slots that
                // already have a pending change (a replacement queued earlier,
                // or a layout planned in the office) are handled by the
                // change note instead.
                var suggestions: [ReplacementSuggestion] = []
                var seenTrayIds: Set<UUID> = Set(changeRequests.values.flatMap { $0.items.map(\.trayId) })

                for machine in allMachines {
                    let machineTrays = traysByMachine[machine.id] ?? []
                    for tray in machineTrays {
                        guard !seenTrayIds.contains(tray.id) else { continue }

                        var reason: ReplacementReason?

                        if let productId = tray.productId {
                            // 1) Discontinued + empty → must replace
                            if tray.isDiscontinued && tray.currentStock == 0 {
                                reason = .discontinued
                            }
                            // 2) Expired product (all warehouse batches expired) → any stock level
                            else if expiredProductIds.contains(productId) {
                                reason = .expired
                            }
                            // 3) No warehouse stock + empty tray → can't refill, suggest replacement
                            else if tray.currentStock == 0 && !warehouseProductIds.contains(productId) {
                                reason = .noStock
                            }
                        } else {
                            // 4) Unassigned tray → user should pick a product
                            reason = .unassigned
                        }

                        if let reason {
                            seenTrayIds.insert(tray.id)
                            suggestions.append(ReplacementSuggestion(
                                trayId: tray.id,
                                machineId: machine.id,
                                machineName: machine.displayName,
                                slotNumber: tray.itemNumber,
                                currentProductId: tray.productId,
                                currentProductName: tray.productName,
                                currentProductImage: tray.products?.imagePath,
                                currentStock: tray.currentStock,
                                reason: reason
                            ))
                        }
                    }
                }

                self.replacements = suggestions
                print("[RefillWizard] Found \(suggestions.count) replacement suggestions")
                if !suggestions.isEmpty {
                    self.recentRemovals = await fetchRecentRemovals(
                        machineIds: Array(Set(suggestions.map(\.machineId)))
                    )
                }

                // If no replacements needed, skip review step
                if suggestions.isEmpty {
                    currentStep = .packing
                } else {
                    currentStep = .review
                }
            }

            activeChip = .all
        } catch {
            print("[RefillWizard] Error: \(error)")
            self.error = error.localizedDescription
            // Initial load failed and established no state — re-arm the entry
            // gate so returning to the tab retries the load instead of being
            // permanently skipped. (No tour is in memory to protect here.)
            didRunInitialLoad = false
        }

        isLoading = false
    }

    /// Products recently taken out of these machines, for the replacement
    /// picker (`get_recent_product_removals`). A failing lookup returns
    /// nothing rather than blocking the review.
    private func fetchRecentRemovals(machineIds: [UUID]) async -> [UUID: [UUID: RecentRemoval]] {
        struct Response: Decodable {
            let removals: [RecentRemoval]
        }
        do {
            let response: Response = try await client.rpc("get_recent_product_removals", params: [
                "p_machine_ids": AnyJSON.array(machineIds.map { AnyJSON.string($0.uuidString) }),
            ]).execute().value
            var result: [UUID: [UUID: RecentRemoval]] = [:]
            for removal in response.removals {
                if let known = result[removal.machineId]?[removal.productId],
                   known.removedAt >= removal.removedAt { continue }
                result[removal.machineId, default: [:]][removal.productId] = removal
            }
            return result
        } catch {
            print("[RefillWizard] get_recent_product_removals failed: \(error)")
            return [:]
        }
    }

    /// Load stock for a specific warehouse. Also loads the physical pick
    /// order (warehouse_product_positions traversed depth-first via
    /// warehouse_position_groups) so the packing step can sort items to match
    /// the warehouse layout.
    func loadWarehouseStock(warehouseId: UUID) async {
        // Fetch physical pick order in parallel with stock. A missing or
        // failing positions fetch must not break stock loading — warehouses
        // without configured positions simply fall back to quantity-based
        // sorting in combinedPackingList.
        async let orderedIdsTask: [UUID] = fetchOrderedProductIdsOrEmpty(warehouseId: warehouseId)

        do {
            let batches: [WarehouseStockBatch] = try await client
                .from("warehouse_stock_batches")
                .select("id, warehouse_id, product_id, quantity, batch_number, expiration_date")
                .eq("warehouse_id", value: warehouseId.uuidString)
                .gt("quantity", value: 0)
                .execute()
                .value

            // Aggregate by product
            var stockMap: [UUID: Int] = [:]
            for batch in batches {
                stockMap[batch.productId, default: 0] += batch.quantity
            }

            // Fetch product details
            let productIds = Array(stockMap.keys)
            if productIds.isEmpty {
                warehouseStock = []
            } else {
                let products: [Product] = try await client
                    .from("products")
                    .select("id, name, image_path, discontinued, sellprice")
                    .in("id", values: productIds.map { $0.uuidString })
                    .execute()
                    .value

                warehouseStock = products.compactMap { product in
                    guard let qty = stockMap[product.id] else { return nil }
                    return WarehouseProductStock(
                        productId: product.id,
                        productName: product.name ?? String(localized: "Unknown"),
                        totalQuantity: qty,
                        imagePath: product.imagePath
                    )
                }.sorted { $0.productName < $1.productName }
            }
        } catch {
            self.error = error.localizedDescription
        }

        // Always apply whatever pick order we got (possibly empty).
        let orderedIds = await orderedIdsTask
        var orderMap: [UUID: Int] = [:]
        orderMap.reserveCapacity(orderedIds.count)
        for (i, pid) in orderedIds.enumerated() {
            orderMap[pid] = i
        }
        warehouseProductOrder = orderMap
    }

    /// Wrapper that swallows errors from fetchOrderedProductIds so stock
    /// loading can run even when the positions fetch fails (e.g. for a
    /// warehouse that has never had its layout configured).
    private func fetchOrderedProductIdsOrEmpty(warehouseId: UUID) async -> [UUID] {
        do {
            return try await fetchOrderedProductIds(warehouseId: warehouseId)
        } catch {
            print("[RefillWizard] fetchOrderedProductIds failed: \(error)")
            return []
        }
    }

    /// Returns product ids in the warehouse's physical pick order:
    /// depth-first through position groups (sorted by `sort_order` at every
    /// level), with any ungrouped positioned products appended at the end.
    /// Mirrors the web's `fetchOrderedProductIds` so iOS produces the same
    /// pack ordering the web UI does.
    private func fetchOrderedProductIds(warehouseId: UUID) async throws -> [UUID] {
        async let groupsResult: [WarehousePositionGroup] = client
            .from("warehouse_position_groups")
            .select("id, parent_id, sort_order")
            .eq("warehouse_id", value: warehouseId.uuidString)
            .order("sort_order", ascending: true)
            .execute()
            .value

        async let positionsResult: [WarehouseProductPosition] = client
            .from("warehouse_product_positions")
            .select("product_id, sort_order, group_id")
            .eq("warehouse_id", value: warehouseId.uuidString)
            .order("sort_order", ascending: true)
            .execute()
            .value

        let groups = try await groupsResult
        let positions = try await positionsResult

        // Use a reference-type node so we can mutate children/productIds via
        // dictionary lookups without fighting Swift's value-type copy rules.
        final class Node {
            let id: UUID
            let parentId: UUID?
            let sortOrder: Int
            var children: [Node] = []
            var productIds: [UUID] = []
            init(_ g: WarehousePositionGroup) {
                self.id = g.id
                self.parentId = g.parentId
                self.sortOrder = g.sortOrder
            }
        }

        var nodeMap: [UUID: Node] = [:]
        nodeMap.reserveCapacity(groups.count)
        for g in groups {
            nodeMap[g.id] = Node(g)
        }

        // Link children to parents; nodes without a known parent are roots.
        var roots: [Node] = []
        for node in nodeMap.values {
            if let parentId = node.parentId, let parent = nodeMap[parentId] {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        }

        // Sort every level by sort_order.
        func sortChildren(_ node: Node) {
            node.children.sort { $0.sortOrder < $1.sortOrder }
            for child in node.children {
                sortChildren(child)
            }
        }
        roots.sort { $0.sortOrder < $1.sortOrder }
        for root in roots {
            sortChildren(root)
        }

        // Assign positions to their group (or to the ungrouped bucket).
        // `positions` is already ordered by sort_order from the DB query.
        var ungrouped: [UUID] = []
        for p in positions {
            if let groupId = p.groupId, let node = nodeMap[groupId] {
                node.productIds.append(p.productId)
            } else {
                ungrouped.append(p.productId)
            }
        }

        // Depth-first flatten: group products, then recurse into children.
        var result: [UUID] = []
        result.reserveCapacity(positions.count)
        func traverse(_ nodes: [Node]) {
            for node in nodes {
                result.append(contentsOf: node.productIds)
                traverse(node.children)
            }
        }
        traverse(roots)
        result.append(contentsOf: ungrouped)

        return result
    }

    // MARK: - Slot Change Requests (change note)

    /// Remember the raw data the tour list is built from, so accepting or
    /// declining a change-note slot can rebuild the list without a refetch.
    private func storeTourSource(
        allMachines: [VendingMachine],
        allTrays: [Tray],
        availability: (productIds: Set<UUID>, hasWarehouses: Bool)
    ) {
        lastAllMachines = allMachines
        lastAllTrays = allTrays
        lastWarehouseProductIds = availability.productIds
        lastHasWarehouses = availability.hasWarehouses
        allTraysByMachine = Dictionary(grouping: allTrays, by: { $0.machineId })
    }

    /// Rebuild `machines` from the stored source, the open change requests and
    /// the refiller's accept/decline decisions (packing step only).
    private func rebuildTourList() {
        machines = Self.buildRefillMachines(
            allMachines: lastAllMachines,
            allTrays: lastAllTrays,
            warehouseProductIds: lastWarehouseProductIds,
            hasWarehouses: lastHasWarehouses,
            requests: changeRequests,
            acceptedTrayIds: acceptedRebuildTrayIds()
        )
        syncMachinePackedState()
    }

    private func acceptedRebuildTrayIds() -> Set<UUID> {
        Set(changeRequests.values.flatMap(\.items).filter { isRebuildAccepted($0.id) }.map(\.trayId))
    }

    /// Whether a slot of a change note is accepted for this tour (default yes).
    func isRebuildAccepted(_ itemId: UUID) -> Bool {
        rebuildDecisions[itemId] != false
    }

    /// Whether the machine's change note has at least one accepted slot.
    func hasAcceptedRebuild(_ machine: RefillMachine) -> Bool {
        machine.changeRequest?.items.contains { isRebuildAccepted($0.id) } ?? false
    }

    /// Accepted change-note slots of a machine.
    func acceptedRebuildItems(machineId: UUID) -> [SlotChangeRequestItem] {
        guard let machine = machines.first(where: { $0.id == machineId }) else { return [] }
        return (machine.changeRequest?.items ?? []).filter { isRebuildAccepted($0.id) }
    }

    /// Machines whose change note is shown on the packing step.
    var machinesWithChangeNote: [RefillMachine] {
        machines.filter { !($0.changeRequest?.items.isEmpty ?? true) }
    }

    /// Accept or decline one slot of a machine's change note (packing step).
    /// A declined slot goes back into the normal refill and stays open
    /// server-side for a later tour.
    func toggleRebuildItem(machineId: UUID, itemId: UUID) {
        guard currentStep == .packing else { return }
        if isRebuildAccepted(itemId) {
            rebuildDecisions[itemId] = false
        } else {
            rebuildDecisions[itemId] = nil
        }
        rebuildTourList()
        reconcilePacking(machineId: machineId)
    }

    /// After a slot left or rejoined the normal refill, drop packed products
    /// the machine no longer needs and cap pinned quantities to the room left
    /// in its remaining slots.
    private func reconcilePacking(machineId: UUID) {
        guard let machine = machines.first(where: { $0.id == machineId }) else {
            packedItems[machineId] = nil
            customQuantities[machineId] = nil
            syncMachinePackedState()
            return
        }
        let needed = Set(machine.trays.filter { $0.deficit > 0 }.compactMap(\.tray.productId))
        var packed = packedItems[machineId] ?? []
        for pid in packed where !needed.contains(pid) {
            packed.remove(pid)
            customQuantities[machineId]?[pid] = nil
        }
        packedItems[machineId] = packed
        for (pid, qty) in customQuantities[machineId] ?? [:] {
            let room = machine.trays
                .filter { $0.tray.productId == pid }
                .reduce(0) { $0 + max(0, $1.tray.capacity - $1.tray.currentStock) }
            if qty > room { customQuantities[machineId]?[pid] = room }
        }
        syncMachinePackedState()
    }

    /// Units the accepted slots of a machine need for the rebuild. While
    /// packing it is computed from the stock known now (stock that moves
    /// within the machine needs no warehouse stock); once the tour started it
    /// is what was actually packed.
    func rebuildNeeds(machineId: UUID) -> [UUID: Int] {
        guard currentStep == .packing else { return rebuildPacked[machineId] ?? [:] }
        let items = acceptedRebuildItems(machineId: machineId)
        guard !items.isEmpty else { return [:] }
        let stock = Dictionary(
            (allTraysByMachine[machineId] ?? []).map { ($0.id, $0.currentStock) },
            uniquingKeysWith: { first, _ in first }
        )
        return SlotChange.rebuildPackNeeds(items.map(\.line), stockByTray: stock)
    }

    /// Machine id → product id → units committed for rebuilds. Rebuilds get
    /// the first claim on warehouse stock (an accepted change cannot be done
    /// without its units), machines in tour order. Without warehouse stock
    /// data nothing is restricted, like the normal packing. After the tour
    /// started this is what was packed.
    var committedRebuild: [UUID: [UUID: Int]] {
        guard currentStep == .packing else { return rebuildPacked }
        let restrict = selectedWarehouseId != nil && !warehouseStock.isEmpty
        var remaining: [UUID: Int] = [:]
        for stock in warehouseStock { remaining[stock.productId] = stock.totalQuantity }
        var out: [UUID: [UUID: Int]] = [:]
        for machine in machines {
            var machineMap: [UUID: Int] = [:]
            let custom = rebuildCustomQuantities[machine.id] ?? [:]
            for (pid, need) in rebuildNeeds(machineId: machine.id)
            where need > 0 && isRebuildTaken(machineId: machine.id, productId: pid) {
                let wanted = min(custom[pid] ?? need, need)
                let qty: Int
                if restrict {
                    let available = remaining[pid] ?? 0
                    qty = min(wanted, available)
                    remaining[pid] = available - qty
                } else {
                    qty = wanted
                }
                if qty > 0 { machineMap[pid] = qty }
            }
            if !machineMap.isEmpty { out[machine.id] = machineMap }
        }
        return out
    }

    /// Units of a product committed to slot rebuilds across all machines.
    func rebuildCommittedTotal(productId: UUID) -> Int {
        committedRebuild.values.reduce(0) { $0 + ($1[productId] ?? 0) }
    }

    /// The refiller takes a machine's rebuild units of a product along: the
    /// rebuild-only row is ticked, or the product is packed for that machine
    /// anyway. Unticked units are not booked, like a normal product.
    func isRebuildTaken(machineId: UUID, productId: UUID) -> Bool {
        rebuildPackTicks[machineId]?.contains(productId) == true
            || isMachinePacked(machineId: machineId, productId: productId)
    }

    /// Rebuild units shown for a product of one machine (packing step): what
    /// is committed once ticked, otherwise what would be packed (the dialled
    /// amount within what the warehouse can cover).
    func rebuildQuantity(machineId: UUID, productId: UUID) -> Int {
        if isRebuildTaken(machineId: machineId, productId: productId) {
            return committedRebuild[machineId]?[productId] ?? 0
        }
        let need = rebuildNeeds(machineId: machineId)[productId] ?? 0
        let wanted = min(rebuildCustomQuantities[machineId]?[productId] ?? need, need)
        return min(wanted, maxRebuildQuantity(machineId: machineId, productId: productId))
    }

    /// Tick every rebuild-only row of the given machines (the "pack all"
    /// buttons). Products refilled anyway follow their own packed tick.
    private func tickAllRebuildRows(machineIds: [UUID]) {
        for machineId in machineIds {
            let refilled = Set(combinedPackingList
                .filter { item in item.machineNeeds.contains { $0.machineId == machineId } }
                .map(\.productId))
            var set = rebuildPackTicks[machineId] ?? []
            for (pid, need) in rebuildNeeds(machineId: machineId) where need > 0 && !refilled.contains(pid) {
                set.insert(pid)
            }
            rebuildPackTicks[machineId] = set
        }
    }

    /// Machines (of `machineIds`, in that order) whose accepted slots need
    /// the product from the warehouse, with that need.
    func rebuildMachineNeeds(productId: UUID, machineIds: [UUID]) -> [RebuildMachineNeed] {
        machineIds.compactMap { machineId in
            let need = rebuildNeeds(machineId: machineId)[productId] ?? 0
            return need > 0 ? RebuildMachineNeed(machineId: machineId, need: need) : nil
        }
    }

    /// Most rebuild units a machine can pack of a product: what its slots
    /// need, capped by the warehouse stock the other machines' rebuilds leave.
    func maxRebuildQuantity(machineId: UUID, productId: UUID) -> Int {
        let need = rebuildNeeds(machineId: machineId)[productId] ?? 0
        guard selectedWarehouseId != nil, !warehouseStock.isEmpty else { return need }
        let total = warehouseStockFor(productId: productId)?.totalQuantity ?? 0
        let others = committedRebuild
            .filter { $0.key != machineId }
            .reduce(0) { $0 + ($1.value[productId] ?? 0) }
        return max(0, min(need, total - others))
    }

    /// Pack fewer (or again more) rebuild units of a product for one machine,
    /// e.g. only half a spiral of a new product. 0 is allowed: the slot is
    /// still rebuilt, the refiller fills what is at hand.
    func setRebuildQuantity(machineId: UUID, productId: UUID, quantity: Int) {
        let clamped = max(0, min(maxRebuildQuantity(machineId: machineId, productId: productId), quantity))
        var machineMap = rebuildCustomQuantities[machineId] ?? [:]
        machineMap[productId] = clamped
        rebuildCustomQuantities[machineId] = machineMap
    }

    /// Open change requests with their pending slots, keyed by machine id.
    /// Never throws: a failing lookup must not block a normal tour.
    func fetchOpenChangeRequests(machineIds: [UUID]) async -> [UUID: SlotChangeRequest] {
        do {
            return try await SlotChangeService.fetchOpenRequests(machineIds: machineIds)
        } catch {
            print("[RefillWizard] change requests unavailable: \(error)")
            return [:]
        }
    }

    /// Queue review-step replacements of one machine into its open change
    /// request instead of switching the slots now: the slot is rebuilt at
    /// the machine, where the old stock is counted.
    private func queueReplacements(machineId: UUID, suggestions: [ReplacementSuggestion]) async throws {
        let changes: [(trayId: UUID, productId: UUID)] = suggestions.compactMap { suggestion in
            guard let productId = suggestion.replacementProductId else { return nil }
            return (trayId: suggestion.trayId, productId: productId)
        }
        guard !changes.isEmpty else { return }
        try await SlotChangeService.queueProducts(machineId: machineId, changes: changes)
    }

    // MARK: - Slot Rebuild at the Machine

    /// Forget the rebuild cards (next machine, resume, reset).
    func resetCurrentRebuild() {
        currentRebuild = []
        currentRebuildMachineId = nil
        preparingRebuildFor = nil
    }

    /// Whether the machine has change-note slots to rebuild on this tour.
    func machineHasRebuild(_ machineId: UUID) -> Bool {
        !(machines.first(where: { $0.id == machineId })?.changeRequest?.items.isEmpty ?? true)
    }

    /// Build the rebuild cards of a machine when it comes up in the refill
    /// step: "taken out" defaults to the slot's live stock (sales since
    /// packing are already deducted), "filled in" to the fill plan. Keeps the
    /// cards (and the refiller's input) when called again for the same machine.
    func prepareRebuild(machineId: UUID) async {
        guard currentStep == .refill,
              currentRebuildMachineId != machineId,
              preparingRebuildFor != machineId,
              let machine = machines.first(where: { $0.id == machineId }) else { return }
        let items = machine.changeRequest?.items ?? []
        preparingRebuildFor = machineId
        defer { if preparingRebuildFor == machineId { preparingRebuildFor = nil } }

        var live: [UUID: Int]?
        if !items.isEmpty {
            struct StockRow: Decodable {
                let id: UUID
                let currentStock: Int
                enum CodingKeys: String, CodingKey {
                    case id
                    case currentStock = "current_stock"
                }
            }
            do {
                let rows: [StockRow] = try await client
                    .from("machine_trays")
                    .select("id, current_stock")
                    .in("id", values: items.map(\.trayId.uuidString))
                    .execute()
                    .value
                live = Dictionary(rows.map { ($0.id, $0.currentStock) }, uniquingKeysWith: { first, _ in first })
            } catch {
                print("[RefillWizard] live stock for rebuild failed: \(error)")
            }
        }
        // The view went away (task cancelled) or the refiller switched
        // machines while this was loading: build the cards next time.
        guard !Task.isCancelled,
              currentMachine?.id == machineId,
              currentRebuildMachineId != machineId else { return }

        let known = Dictionary(
            (allTraysByMachine[machineId] ?? []).map { ($0.id, $0.currentStock) },
            uniquingKeysWith: { first, _ in first }
        )
        currentRebuild = items.compactMap { item in
            let stock: Int
            if let live {
                // A slot deleted since planning has nothing to rebuild.
                guard let value = live[item.trayId] else { return nil }
                stock = value
            } else {
                stock = known[item.trayId] ?? 0
            }
            return RebuildSlot(item: item, liveStock: stock, removed: stock, filled: 0)
        }
        currentRebuildMachineId = machineId
        recomputeRebuildFill()
    }

    /// Refresh the suggested fill of every slot whose fill the refiller
    /// hasn't typed.
    private func recomputeRebuildFill() {
        guard let machineId = currentRebuildMachineId else { return }
        let active = currentRebuild.filter { $0.action != .skip }
        let removed = Dictionary(active.map { ($0.item.id, $0.removed) }, uniquingKeysWith: { first, _ in first })
        let plan = SlotChange.fillPlan(
            active.map(\.item.line),
            removedByItem: removed,
            vanByProduct: rebuildPacked[machineId] ?? [:]
        )
        for i in currentRebuild.indices {
            let suggestion = plan[currentRebuild[i].item.id] ?? .zero
            currentRebuild[i].moved = suggestion.moved
            currentRebuild[i].fromVan = suggestion.van
            if !currentRebuild[i].filledTouched {
                currentRebuild[i].filled = suggestion.total
            }
        }
    }

    func setRebuildRemoved(itemId: UUID, value: Int) {
        guard let i = currentRebuild.firstIndex(where: { $0.item.id == itemId }) else { return }
        currentRebuild[i].removed = max(0, value)
        currentRebuild[i].removedTouched = true
        recomputeRebuildFill()
    }

    func setRebuildFilled(itemId: UUID, value: Int) {
        guard let i = currentRebuild.firstIndex(where: { $0.item.id == itemId }) else { return }
        let item = currentRebuild[i].item
        currentRebuild[i].filled = item.toProductId == nil ? 0 : max(0, min(item.toCapacity, value))
        currentRebuild[i].filledTouched = true
    }

    /// Mark a slot rebuilt / not rebuilt; `nil` undoes the decision.
    func setRebuildAction(itemId: UUID, action: SlotChangeAction?) {
        guard let i = currentRebuild.firstIndex(where: { $0.item.id == itemId }) else { return }
        // A slot whose age restriction changes can only be quit once the
        // age setting at the machine is confirmed.
        if action == .done && currentRebuild[i].needsAgeConfirmation { return }
        currentRebuild[i].action = action
        recomputeRebuildFill()
    }

    func setRebuildPriceSet(itemId: UUID, value: Bool) {
        guard let i = currentRebuild.firstIndex(where: { $0.item.id == itemId }) else { return }
        currentRebuild[i].priceSet = value
    }

    /// Tick / untick "age setting changed". Unticking a slot already marked
    /// rebuilt puts it back to undecided.
    func setRebuildAgeSet(itemId: UUID, value: Bool) {
        guard let i = currentRebuild.firstIndex(where: { $0.item.id == itemId }) else { return }
        currentRebuild[i].ageSet = value
        if !value && currentRebuild[i].action == .done && currentRebuild[i].item.changesAge {
            currentRebuild[i].action = nil
            recomputeRebuildFill()
        }
    }

    /// Every slot of the change note has been marked rebuilt or not rebuilt.
    var rebuildReady: Bool {
        currentRebuild.allSatisfy { $0.action != nil }
    }

    private func computeRebuildLeftovers(slots: [RebuildSlot], machineId: UUID) -> [RebuildLeftover] {
        guard !slots.isEmpty else { return [] }
        let outcome = Dictionary(
            slots.map { slot in
                (slot.item.id, SlotItemOutcome(
                    action: slot.action == .skip ? .skip : .done,
                    removed: slot.removed,
                    filled: slot.filled
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let left = SlotChange.computeLeftovers(
            slots.map(\.item.line),
            outcome: outcome,
            packedByProduct: rebuildPacked[machineId] ?? [:]
        )
        // Stable order: as the products first appear on the note.
        var order: [UUID] = []
        var names: [UUID: String] = [:]
        var images: [UUID: String] = [:]
        func note(_ productId: UUID?, _ name: String?, _ image: String?) {
            guard let productId else { return }
            if !order.contains(productId) { order.append(productId) }
            if let name { names[productId] = name }
            if let image { images[productId] = image }
        }
        for slot in slots {
            note(slot.item.fromProductId, slot.item.fromName, slot.item.fromImagePath)
            note(slot.item.toProductId, slot.item.toName, slot.item.toImagePath)
        }
        let rest = left.keys.filter { !order.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        return (order + rest).compactMap { pid in
            guard let split = left[pid] else { return nil }
            return RebuildLeftover(
                productId: pid, name: names[pid], imagePath: images[pid],
                van: split.van, machine: split.machine
            )
        }
    }

    // MARK: - Tour Leftovers (summary step)

    /// The tour's leftovers per product, summed over the machines (computed
    /// values, before the refiller's count on the summary step).
    var tourLeftoverTotals: [TourLeftoverTotal] {
        SlotChange.aggregateTourLeftovers(tourLeftovers, machineOrder: machines.map(\.id))
    }

    /// There are leftovers and they were not booked yet.
    var hasUnreturnedTourLeftovers: Bool {
        !tourLeftoversReturned && !tourLeftoverTotals.isEmpty
    }

    /// Store what a machine left over (overwrites, so a retry never double
    /// counts). Without a warehouse nothing was deducted, so nothing is
    /// booked back — as before, nothing is stored.
    private func storeTourLeftovers(machineId: UUID, slots: [RebuildSlot]) {
        guard selectedWarehouseId != nil else { return }
        let left = computeRebuildLeftovers(slots: slots, machineId: machineId).map {
            TourLeftover(productId: $0.productId, name: $0.name, imagePath: $0.imagePath, van: $0.van, machine: $0.machine)
        }
        tourLeftovers[machineId] = left.isEmpty ? nil : left
        if !left.isEmpty { tourLeftoversReturned = false }
    }

    /// Counted units of the van / taken out of the machines (defaults: computed).
    func leftoverVan(_ total: TourLeftoverTotal) -> Int {
        leftoverVanQty[total.productId] ?? total.van
    }

    func leftoverMachine(_ total: TourLeftoverTotal) -> Int {
        leftoverMachineQty[total.productId] ?? total.machine
    }

    func setLeftoverVan(productId: UUID, value: Int) {
        leftoverVanQty[productId] = max(0, value)
    }

    func setLeftoverMachine(productId: UUID, value: Int) {
        leftoverMachineQty[productId] = max(0, value)
    }

    func leftoverDestination(productId: UUID) -> LeftoverDestination {
        // Without a warehouse only writing off makes sense.
        guard selectedWarehouseId != nil else { return .waste }
        return leftoverDestinations[productId] ?? .warehouse
    }

    func setLeftoverDestination(productId: UUID, destination: LeftoverDestination) {
        leftoverDestinations[productId] = destination
    }

    /// `date` = "yyyy-MM-dd", or nil to clear.
    func setLeftoverExpiry(productId: UUID, date: String?) {
        leftoverExpiry[productId] = date
    }

    /// Pre-fill the best-before date of goods that came out of the machines:
    /// the date of the batch the last refill of that product into one of
    /// those machines came from. The machines do not track batches, so the
    /// refiller confirms it. Mirrors `useSlotChangeRequests.suggestExpiry`.
    func loadTourExpirySuggestions() async {
        guard !expirySuggestionsLoaded else { return }
        expirySuggestionsLoaded = true
        struct ExpiryRow: Decodable {
            let expirationDate: String?
            enum CodingKeys: String, CodingKey { case expirationDate = "expiration_date" }
        }
        for total in tourLeftoverTotals where total.machine > 0 && !total.machineIds.isEmpty {
            guard leftoverExpiry[total.productId] == nil else { continue }
            do {
                let rows: [ExpiryRow] = try await client
                    .from("warehouse_transactions")
                    .select("expiration_date")
                    .in("reference_id", values: total.machineIds.map(\.uuidString))
                    .eq("product_id", value: total.productId.uuidString)
                    .eq("transaction_type", value: "outgoing_refill")
                    .not("expiration_date", operator: .is, value: "null")
                    .order("created_at", ascending: false)
                    .limit(1)
                    .execute()
                    .value
                if let date = rows.first?.expirationDate, leftoverExpiry[total.productId] == nil {
                    leftoverExpiry[total.productId] = String(date.prefix(10))
                }
            } catch {
                print("[RefillWizard] expiry suggestion failed: \(error)")
            }
        }
    }

    /// Book the tour's leftovers back at the warehouse (or write them off)
    /// with the counted quantities: `return_slot_change_leftovers`, once per
    /// tour (a retry replays the first result). Returns success; on failure
    /// `error` is set and the refiller can try again.
    @discardableResult
    func returnTourLeftovers() async -> Bool {
        guard !tourLeftoversReturned else { return true }
        var payload: [AnyJSON] = []
        for total in tourLeftoverTotals {
            let van = leftoverVan(total)
            let machine = leftoverMachine(total)
            guard van + machine > 0 else { continue }
            let destination = leftoverDestination(productId: total.productId)
            let expiry: String? = destination == .warehouse && machine > 0 ? leftoverExpiry[total.productId] : nil
            payload.append(AnyJSON.object([
                "product_id": .string(total.productId.uuidString),
                "van_qty": .integer(van),
                "machine_qty": .integer(machine),
                "destination": .string(destination.rawValue),
                "expiration_date": expiry.map { AnyJSON.string($0) } ?? .null,
                "batch_number": .string(String(localized: "Machine return")),
            ]))
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.rpc("return_slot_change_leftovers", params: [
                "p_tour_id": AnyJSON.string(tourId),
                "p_warehouse_id": selectedWarehouseId.map { AnyJSON.string($0.uuidString) } ?? .null,
                "p_leftovers": AnyJSON.array(payload),
            ]).execute()
            tourLeftoversReturned = true
            saveTourState()
            return true
        } catch {
            print("[RefillWizard] return_slot_change_leftovers failed: \(error)")
            self.error = String(localized: "The leftover goods could not be booked: \(error.localizedDescription). Please try again.")
            return false
        }
    }

    // MARK: - Notes for the next tour

    /// Load the open notes for the packing step. A failing lookup is only
    /// logged: the tour goes on without the notes.
    func loadTourNotes() async {
        do {
            let rows: [MachineTourNote] = try await client
                .from("machine_tour_notes")
                .select(MachineTourNote.selectColumns)
                .is("done_at", value: nil)
                .order("created_at", ascending: true)
                .execute()
                .value
            tourNotes = MachineTourNotes.notesForPacking(rows, currentTourId: tourId)
        } catch {
            print("[RefillWizard] tour notes unavailable: \(error)")
            tourNotes = []
        }
    }

    /// Tick a note off while packing. It is removed right away and put
    /// back (with an error) if the server refuses.
    func completeTourNote(_ noteId: UUID) async {
        guard let note = tourNotes.first(where: { $0.id == noteId }) else { return }
        tourNoteError = nil
        tourNotes.removeAll { $0.id == noteId }
        do {
            try await client.rpc("complete_machine_tour_notes", params: [
                "p_note_ids": AnyJSON.array([AnyJSON.string(noteId.uuidString)]),
                "p_tour_id": tourId.isEmpty ? AnyJSON.null : AnyJSON.string(tourId),
            ]).execute()
        } catch {
            print("[RefillWizard] complete_machine_tour_notes failed: \(error)")
            tourNotes = MachineTourNotes.notesForPacking(tourNotes + [note], currentTourId: tourId)
            tourNoteError = error.localizedDescription
        }
    }

    /// This tour's open note for a machine (prefills the note sheet), nil
    /// when there is none.
    func currentTourNote(machineId: UUID) async throws -> String? {
        guard !tourId.isEmpty else { return nil }
        struct NoteRow: Decodable { let note: String }
        let rows: [NoteRow] = try await client
            .from("machine_tour_notes")
            .select("note")
            .eq("machine_id", value: machineId.uuidString)
            .eq("written_in_tour", value: tourId)
            .is("done_at", value: nil)
            .limit(1)
            .execute()
            .value
        return rows.first?.note
    }

    /// Write (or overwrite) this tour's note for a machine via
    /// `save_machine_tour_note`; an empty text deletes it.
    func saveTourNote(machineId: UUID, text: String) async throws {
        try await client.rpc("save_machine_tour_note", params: [
            "p_machine_id": AnyJSON.string(machineId.uuidString),
            "p_tour_id": tourId.isEmpty ? AnyJSON.null : AnyJSON.string(tourId),
            "p_note": AnyJSON.string(MachineTourNotes.normalized(text)),
        ]).execute()
    }

    // MARK: - Quit the change note

    /// Quit the change note of a machine via `apply_slot_change` — before the
    /// normal refill. `skipAll` (machine skipped) marks every slot not rebuilt.
    /// The leftovers are not booked here: they are stored in the tour state
    /// (`tourLeftovers`) and booked at the end of the tour. Retried like the
    /// refill; the RPC is idempotent per (request, tour). Returns the slots as
    /// quit, or nil when it could not be saved (`error` set).
    private func applyRebuild(machineId: UUID, skipAll: Bool) async -> [RebuildSlot]? {
        guard let machine = machines.first(where: { $0.id == machineId }),
              let request = machine.changeRequest,
              !request.items.isEmpty else { return [] }

        var slots: [RebuildSlot]
        if currentRebuildMachineId == machineId {
            slots = currentRebuild
        } else if skipAll {
            slots = request.items.map { RebuildSlot(item: $0, liveStock: 0, removed: 0, filled: 0) }
        } else {
            self.error = String(localized: "Mark every slot of the change note as rebuilt or not rebuilt first.")
            return nil
        }
        if skipAll {
            for i in slots.indices { slots[i].action = .skip }
        }
        guard slots.allSatisfy({ $0.action != nil }) else {
            self.error = String(localized: "Mark every slot of the change note as rebuilt or not rebuilt first.")
            return nil
        }

        let itemsPayload: [AnyJSON] = slots.map { slot in
            AnyJSON.object([
                "item_id": .string(slot.item.id.uuidString),
                "action": .string((slot.action ?? .skip).rawValue),
                "removed": .integer(slot.removed),
                "filled": .integer(slot.filled),
                "price_set": .bool(slot.priceSet),
                "age_set": .bool(slot.action == .done && slot.item.changesAge && slot.ageSet),
            ])
        }
        let params: [String: AnyJSON] = [
            "p_request_id": .string(request.id.uuidString),
            "p_tour_id": .string(tourId),
            "p_warehouse_id": selectedWarehouseId.map { AnyJSON.string($0.uuidString) } ?? .null,
            "p_items": .array(itemsPayload),
            // Booked at the end of the tour (`returnTourLeftovers`).
            "p_leftovers": .array([]),
        ]

        let backoffSeconds: [Double] = [1.0, 3.0]
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await client.rpc("apply_slot_change", params: params).execute()
                // Skipped slots leave every packed unit in the van, which is
                // exactly what `computeLeftovers` yields for them.
                storeTourLeftovers(machineId: machineId, slots: slots)
                return slots
            } catch {
                lastError = error
                print("[RefillWizard] apply_slot_change attempt \(attempt)/3 failed: \(error)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(backoffSeconds[attempt - 1] * 1_000_000_000))
                }
            }
        }
        let reason = lastError?.localizedDescription ?? String(localized: "unknown error")
        self.error = String(localized: "The slot change could not be saved: \(reason). Please try again.")
        return nil
    }

    // MARK: - Packing Step Actions

    // MARK: - Review Step Actions

    /// Set a replacement product for a tray.
    func setReplacement(trayId: UUID, productId: UUID) {
        guard let idx = replacements.firstIndex(where: { $0.trayId == trayId }) else { return }
        replacements[idx].replacementProductId = productId
        replacements[idx].isSkipped = false
    }

    /// Skip replacing a specific tray.
    func skipReplacement(trayId: UUID) {
        guard let idx = replacements.firstIndex(where: { $0.trayId == trayId }) else { return }
        replacements[idx].isSkipped = true
        replacements[idx].replacementProductId = nil
    }

    /// Whether all replacements have been handled (replaced or skipped).
    var allReplacementsHandled: Bool {
        replacements.allSatisfy { $0.replacementProductId != nil || $0.isSkipped }
    }

    /// Apply replacements to the database and proceed to packing.
    func applyReplacementsAndContinue() async {
        let toReplace = replacements.filter { $0.replacementProductId != nil }
        guard allReplacementsHandled else { return }

        isSaving = true

        do {
            // Never switch the slot here: a replacement is queued into the
            // machine's open slot change request, so it shows up as a change
            // note in this tour and is rebuilt at the machine, where the old
            // stock is counted (sales keep booking to the old product until
            // then). One request per machine, merged with what is already open.
            let byMachine = Dictionary(grouping: toReplace, by: \.machineId)
            for (machineId, suggestions) in byMachine {
                try await queueReplacements(machineId: machineId, suggestions: suggestions)
            }
            if !toReplace.isEmpty {
                replacementNotice = String(localized: "\(toReplace.count) slot(s) queued as a change note. The new product goes in at the machine.")
            }

            // Reload machine data so the queued slots appear as change notes
            reviewCompleted = true
            await loadData()
            currentStep = .packing
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    /// Skip all remaining unhandled replacements, then apply any already-chosen replacements and continue.
    func skipReview() async {
        // Mark only unhandled entries as skipped — keep already-chosen replacements
        for idx in replacements.indices {
            if replacements[idx].replacementProductId == nil && !replacements[idx].isSkipped {
                replacements[idx].isSkipped = true
            }
        }
        await applyReplacementsAndContinue()
    }

    /// Navigate back to a previous step (tapped via step indicator).
    func navigateToStep(_ step: RefillStep) {
        guard step.rawValue < currentStep.rawValue else { return }
        if step == .review {
            reviewCompleted = false
        }
        currentStep = step
    }

    func toggleMachinePacked(machineId: UUID) {
        guard let index = machines.firstIndex(where: { $0.id == machineId }) else { return }
        machines[index].isPacked.toggle()
    }

    func packAllMachines() {
        packEverything()
    }

    /// Pack every product needed for one specific machine (stock-aware).
    /// Mirrors `packAllMachines` but scoped — drives the "Pack all for %@"
    /// button shown when the Pack step has a machine chip active.
    ///
    /// Note: does NOT call `saveTourState()`. Consistent with the existing
    /// pack-step helpers (`togglePackedForMachine`, `togglePackedAll`,
    /// `packEverything`/`packAllMachines`) which also skip it. `saveTourState()`
    /// is a no-op during `.packing` anyway (guard at line 361), but matching
    /// the existing pattern keeps future maintenance simple.
    func packAllForMachine(_ machineId: UUID) {
        tickAllRebuildRows(machineIds: [machineId])
        for item in combinedPackingList {
            guard item.machineNeeds.contains(where: { $0.machineId == machineId }) else { continue }
            guard !isOutOfStockForMachine(machineId: machineId, productId: item.productId) else { continue }
            if !isMachinePacked(machineId: machineId, productId: item.productId) {
                togglePackedForMachine(productId: item.productId, machineId: machineId)
            }
        }
    }

    // MARK: - Step Navigation

    func startTour() async {
        guard packedMachines.count > 0 else { return }

        isSaving = true
        tourId = UUID().uuidString
        tourLog = []
        tourLeftovers = [:]
        tourLeftoversReturned = false
        leftoverVanQty = [:]
        leftoverMachineQty = [:]
        leftoverDestinations = [:]
        leftoverExpiry = [:]
        expirySuggestionsLoaded = false
        staleStockTrayIds = []
        // Rebuild units, computed while still packing (warehouse-capped).
        let rebuildCommit = committedRebuild
        resetCurrentRebuild()

        // Apply custom packing quantities and mark which trays belong to this tour.
        // Trays for products that were NOT packed get fillAmount = 0 and isInTour = false.
        for mi in machines.indices {
            let machine = machines[mi]
            guard machine.isPacked else {
                // Unpacked machine: exclude all of its trays from the tour display.
                for ti in machines[mi].trays.indices {
                    machines[mi].trays[ti].isInTour = false
                }
                continue
            }
            let packedProductIds = packedItems[machine.id] ?? Set()
            var distributedProductIds = Set<UUID>()

            for ti in machines[mi].trays.indices {
                let tray = machines[mi].trays[ti]

                // Product-less trays: no longer part of a freshly built tour
                // (`buildRefillMachines` skips them, like the PWA); only a tour
                // saved by an older build can still hold one — keep it as it was.
                guard let productId = tray.tray.productId else {
                    machines[mi].trays[ti].isInTour = true
                    continue
                }

                // Product trays: in the tour only if the product was packed.
                guard packedProductIds.contains(productId) else {
                    machines[mi].trays[ti].isInTour = false
                    machines[mi].trays[ti].fillAmount = 0
                    continue
                }

                // Already handled together with an earlier slot of this product.
                guard !distributedProductIds.contains(productId) else { continue }

                machines[mi].trays[ti].isInTour = true

                // Apply custom quantity if set (always the case for a packed
                // product — `pinPackingQuantity` pins it at pack time).
                guard let machineCustom = customQuantities[machine.id],
                      let customQty = machineCustom[productId] else { continue }
                distributedProductIds.insert(productId)

                // Spread the packed quantity across every slot of the product,
                // emptiest slot first, so no selection stays sold out while
                // another slot of the same product is topped up. Slots that get
                // nothing leave the tour (mirrors the PWA, which hides them).
                let productTrayIndices = machines[mi].trays.indices.filter {
                    machines[mi].trays[$0].tray.productId == productId
                }
                let amounts = MachineStockHealth.distributeAcrossSlots(
                    productTrayIndices.map {
                        let t = machines[mi].trays[$0].tray
                        return (itemNumber: t.itemNumber, capacity: t.capacity, currentStock: t.currentStock)
                    },
                    amount: customQty
                )
                for (idx, amount) in zip(productTrayIndices, amounts) {
                    machines[mi].trays[idx].fillAmount = amount
                    machines[mi].trays[idx].isInTour = amount > 0
                }
            }
        }

        // Only the accepted slots of a change note travel with the tour;
        // declined ones stay open server-side for a later tour.
        for mi in machines.indices {
            guard machines[mi].isPacked, let request = machines[mi].changeRequest else { continue }
            let accepted = request.items.filter { isRebuildAccepted($0.id) }
            machines[mi].changeRequest = accepted.isEmpty ? nil : SlotChangeRequest(
                id: request.id, machineId: request.machineId, note: request.note, items: accepted
            )
        }
        let tourMachineIds = Set(machines.filter { $0.isPacked && $0.changeRequest != nil }.map(\.id))
        rebuildPacked = rebuildCommit.filter { tourMachineIds.contains($0.key) }

        // Deduct warehouse stock (FIFO) for all packed products — matches web startTour()
        if let warehouseId = selectedWarehouseId {
            await deductWarehouseStock(warehouseId: warehouseId, rebuild: rebuildPacked)
        }

        // Tour-started feed event — written after the warehouse deductions so an
        // aborted start never leaves an orphaned feed entry (spec §3.1). On iOS
        // deduction failures don't block the tour, so this runs on every start.
        // Field-compatible with the PWA's buildTourStartedEntry payload.
        let tourMachines = packedMachines
        var tourMeta: [String: AnyJSON] = [
            "machine_count": .integer(tourMachines.count),
            "machine_ids": .array(tourMachines.map { .string($0.id.uuidString) }),
            "machine_names": .array(tourMachines.map { .string($0.machine.displayName) }),
        ]
        if let warehouseName = warehouses.first(where: { $0.id == selectedWarehouseId })?.name {
            tourMeta["warehouse_name"] = .string(warehouseName)
        }
        await writeActivityLog(machineId: nil, machineName: nil, action: "tour_started", extraMetadata: tourMeta)

        currentMachineIndex = 0
        isSaving = false
        currentStep = .refill
        saveTourState()
    }

    /// Deduct warehouse stock via the `deduct_warehouse_stock_fifo` RPC for each packed product-machine pair.
    /// Slot-rebuild units (`rebuild`: machine → product → qty) go into the same
    /// deduction: one per (machine, product), normal refill + rebuild summed.
    /// Their share is tracked in `rebuildPacked` so unused units can go back
    /// to this tour's batches (`apply_slot_change` matches them by `tour_id`).
    private func deductWarehouseStock(warehouseId: UUID, rebuild: [UUID: [UUID: Int]] = [:]) async {
        // Collect deductions from packed machines
        struct Deduction {
            let machineId: UUID
            let productId: UUID
            let quantity: Int
        }

        var deductions: [Deduction] = []
        for machine in machines where machine.isPacked {
            // Only products the user actually ticked off in the packing step.
            // `startTour()` gates tour inclusion on the same `packedItems` set
            // (products left unchecked get `fillAmount = 0` / `isInTour = false`),
            // so deducting every tray product instead billed the warehouse for
            // goods that never left the shelf.
            let trayProductIds = Set(machine.trays.compactMap { $0.tray.productId })
            let productIds = (packedItems[machine.id] ?? []).intersection(trayProductIds)
            var totals: [UUID: Int] = [:]
            for productId in productIds {
                let qty = packingQuantity(machineId: machine.id, productId: productId)
                guard qty > 0 else { continue }
                totals[productId, default: 0] += qty
            }
            for (productId, qty) in rebuild[machine.id] ?? [:] where qty > 0 {
                totals[productId, default: 0] += qty
            }
            for (productId, qty) in totals.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                deductions.append(Deduction(machineId: machine.id, productId: productId, quantity: qty))
            }
        }

        guard !deductions.isEmpty else { return }

        // Get user info for audit trail
        let userId: String? = await {
            try? await client.auth.session.user.id.uuidString
        }()
        let userEmail: String? = await {
            try? await client.auth.session.user.email
        }()

        // Execute deductions (non-blocking errors — warehouse deduction failure shouldn't block the tour)
        for d in deductions {
            do {
                try await client.rpc(
                    "deduct_warehouse_stock_fifo",
                    params: [
                        "p_warehouse_id": AnyJSON.string(warehouseId.uuidString),
                        "p_product_id": AnyJSON.string(d.productId.uuidString),
                        "p_quantity": AnyJSON.integer(d.quantity),
                        "p_user_id": userId.map { AnyJSON.string($0) } ?? AnyJSON.null,
                        "p_reference_id": AnyJSON.string(d.machineId.uuidString),
                        "p_notes": AnyJSON.string("Refill tour"),
                        "p_metadata": AnyJSON.object([
                            "_user_email": userEmail.map { AnyJSON.string($0) } ?? AnyJSON.null,
                            "tour_id": AnyJSON.string(tourId)
                        ])
                    ]
                ).execute()
            } catch {
                print("[RefillWizard] Warehouse deduction failed for product \(d.productId): \(error)")
                // Non-critical: continue tour even if deduction fails
            }
        }
    }

    /// Adjust the fill amount for a tray in the current machine.
    func adjustFillAmount(machineId: UUID, trayId: UUID, amount: Int) {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }),
              let ti = machines[mi].trays.firstIndex(where: { $0.id == trayId }) else { return }

        let tray = machines[mi].trays[ti]
        let maxFill = tray.tray.capacity - tray.tray.currentStock
        machines[mi].trays[ti].fillAmount = max(0, min(maxFill, amount))
    }

    /// Fill a single tray to capacity in the wizard.
    func fillTrayToCapacity(machineId: UUID, trayId: UUID) {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }),
              let ti = machines[mi].trays.firstIndex(where: { $0.id == trayId }) else { return }

        let tray = machines[mi].trays[ti]
        machines[mi].trays[ti].fillAmount = tray.tray.capacity - tray.tray.currentStock
    }

    /// Fill every tray **of this tour** in the current machine to capacity.
    ///
    /// Scoped to `isInTour` deliberately. `startTour` sets `isInTour = false`
    /// and `fillAmount = 0` on trays whose product the driver did not pack —
    /// the normal case when one product was out of warehouse stock — and those
    /// trays still have room. Touching them here credited machine stock, and
    /// inflated `total_added` in the audit row, for goods that never left the
    /// warehouse: into trays the refill step does not even render, so the
    /// driver could neither see it nor undo it.
    func fillAllTrays(machineId: UUID) {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }) else { return }
        for ti in machines[mi].trays.indices where machines[mi].trays[ti].isInTour {
            let tray = machines[mi].trays[ti]
            machines[mi].trays[ti].fillAmount = tray.tray.capacity - tray.tray.currentStock
        }
    }

    /// Server response row from the `refill_machine_trays` RPC.
    private struct TrayApplicationResult: Decodable {
        let trayId: UUID
        let oldStock: Int
        let newStock: Int
        let fillAmount: Int
        let wasAlreadyApplied: Bool

        enum CodingKeys: String, CodingKey {
            case trayId             = "tray_id"
            case oldStock           = "old_stock"
            case newStock           = "new_stock"
            case fillAmount         = "fill_amount"
            case wasAlreadyApplied  = "was_already_applied"
        }
    }

    /// Call the atomic `refill_machine_trays` RPC. The server runs all tray
    /// updates in one transaction and dedupes via `(tour_id, tray_id)`, so
    /// safe to retry blindly on network errors.
    private func applyRefillRPC(
        machineId: UUID,
        traysToRefill: [RefillTray]
    ) async throws -> [TrayApplicationResult] {
        let trayPayload: [AnyJSON] = traysToRefill.map { tray in
            AnyJSON.object([
                "tray_id":     .string(tray.tray.id.uuidString),
                "fill_amount": .integer(tray.fillAmount)
            ])
        }
        return try await client.rpc(
            "refill_machine_trays",
            params: [
                "p_machine_id": AnyJSON.string(machineId.uuidString),
                "p_tour_id":    AnyJSON.string(tourId),
                "p_trays":      AnyJSON.array(trayPayload)
            ]
        )
        .execute()
        .value
    }

    /// Confirm refill for the current machine. All tray updates run in one
    /// atomic RPC. On network failures we retry up to 3× with exponential
    /// backoff — the RPC is idempotent, so retries cannot double-apply.
    /// If all attempts fail, the machine is **not** marked refilled and the
    /// wizard stays put, letting the user retry the same machine cleanly.
    ///
    /// A change note on the machine is quit first (`apply_slot_change`, which
    /// switches the rebuilt slots; its leftovers wait for the end of the
    /// tour in `tourLeftovers`); only when that
    /// succeeded does the normal refill of the other slots run. Both RPCs are
    /// idempotent per tour, so a retry after a partial failure is safe.
    func confirmRefill(machineId: UUID) async {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }) else { return }

        var rebuiltSlots: [RebuildSlot] = []
        if machineHasRebuild(machineId) {
            guard currentRebuildMachineId == machineId, rebuildReady else {
                self.error = String(localized: "Mark every slot of the change note as rebuilt or not rebuilt first.")
                return
            }
            isSaving = true
            let rebuilt = await applyRebuild(machineId: machineId, skipAll: false)
            isSaving = false
            guard let rebuilt else { return }  // error surfaced, the user can retry
            rebuiltSlots = rebuilt
        }

        // `isInTour` as well as a positive amount: defence in depth, so no
        // future caller that forgets the tour scope can book stock into a tray
        // the driver never packed (see `fillAllTrays`, and `startTour`, which is
        // what makes a not-packed tray `isInTour == false` in the first place).
        let traysToRefill = machines[mi].trays.filter { $0.fillAmount > 0 && $0.isInTour }

        // No tray needs a stock write — still record the visit so the tour
        // log and audit trail show this machine was opened.
        if traysToRefill.isEmpty {
            await recordRefillSuccess(
                mi: mi,
                machineId: machineId,
                traysSnapshot: [],
                traysCount: 0,
                itemsAdded: 0,
                rebuiltSlots: rebuiltSlots
            )
            return
        }

        isSaving = true
        defer { isSaving = false }

        let backoffSeconds: [Double] = [1.0, 3.0]   // before attempts 2 and 3
        var lastError: Error?

        for attempt in 1...3 {
            do {
                let results = try await applyRefillRPC(
                    machineId: machineId,
                    traysToRefill: traysToRefill
                )

                // Mirror server-authoritative stock values into local state.
                for r in results {
                    guard let ti = machines[mi].trays.firstIndex(where: { $0.tray.id == r.trayId }) else { continue }
                    let oldTray = machines[mi].trays[ti].tray
                    let newTray = Tray(
                        id: oldTray.id,
                        machineId: oldTray.machineId,
                        itemNumber: oldTray.itemNumber,
                        productId: oldTray.productId,
                        capacity: oldTray.capacity,
                        currentStock: r.newStock,
                        minStock: oldTray.minStock,
                        fillWhenBelow: oldTray.fillWhenBelow,
                        products: oldTray.products
                    )
                    machines[mi].trays[ti] = RefillTray(
                        tray: newTray,
                        fillAmount: machines[mi].trays[ti].fillAmount,
                        isInTour: machines[mi].trays[ti].isInTour
                    )
                }

                let itemsAdded = results.reduce(0) { $0 + max(0, $1.newStock - $1.oldStock) }
                await recordRefillSuccess(
                    mi: mi,
                    machineId: machineId,
                    traysSnapshot: traysToRefill,
                    traysCount: results.count,
                    itemsAdded: itemsAdded,
                    rebuiltSlots: rebuiltSlots
                )
                return
            } catch {
                lastError = error
                print("[RefillWizard] confirmRefill attempt \(attempt)/3 failed: \(error)")
                if attempt < 3 {
                    let delaySeconds = backoffSeconds[attempt - 1]
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
        }

        // All 3 attempts failed. Leave machine in the tour so the user can retry.
        let reason = lastError?.localizedDescription ?? String(localized: "unknown error")
        self.error = String(localized: "Refill could not be saved after 3 attempts: \(reason). Please try again.")
    }

    /// Shared post-success bookkeeping: tour log, activity log, advance.
    ///
    /// Rebuilt slots (`rebuiltSlots`, quit by `apply_slot_change`) count as
    /// refilled trays too: every slot quit "rebuilt" with a new product and a
    /// positive fill adds a `products` line (`rebuild: true`), its slot to
    /// `trays_refilled` and its units to `total_added` — otherwise the history
    /// only shows the normal refill of the machine.
    private func recordRefillSuccess(
        mi: Int,
        machineId: UUID,
        traysSnapshot: [RefillTray],
        traysCount: Int,
        itemsAdded: Int,
        rebuiltSlots: [RebuildSlot] = []
    ) async {
        machines[mi].isRefilled = true
        if currentRebuildMachineId == machineId { resetCurrentRebuild() }

        let slotsRebuilt = rebuiltSlots.filter { $0.action == .done }.count
        let filledSlots = rebuiltSlots.filter {
            $0.action == .done && $0.item.toProductId != nil && $0.filled > 0
        }
        let rebuildAdded = filledSlots.reduce(0) { $0 + $1.filled }

        tourLog.append(TourLogEntry(
            machineId: machineId,
            machineName: machines[mi].machine.displayName,
            traysRefilled: traysCount + filledSlots.count,
            totalAdded: itemsAdded + rebuildAdded,
            skipped: false,
            slotsRebuilt: slotsRebuilt > 0 ? slotsRebuilt : nil
        ))

        let productLines: [AnyJSON] = traysSnapshot.map { tray in
            AnyJSON.object([
                "product_id": tray.tray.productId.map { .string($0.uuidString) } ?? .null,
                "product_name": .string(tray.tray.productName),
                "quantity": .integer(tray.fillAmount)
            ])
        } + filledSlots.map { slot in
            AnyJSON.object([
                "product_id": slot.item.toProductId.map { .string($0.uuidString) } ?? .null,
                "product_name": .string(slot.item.toName ?? ""),
                "quantity": .integer(slot.filled),
                "item_number": .integer(slot.item.itemNumber),
                "rebuild": .bool(true)
            ])
        }

        await writeActivityLog(
            machineId: machineId,
            machineName: machines[mi].machine.displayName,
            action: "stock_refill_tour",
            extraMetadata: [
                "trays_refilled": .integer(traysCount + filledSlots.count),
                "total_added": .integer(itemsAdded + rebuildAdded),
                "products": .array(productLines)
            ]
        )

        advanceToNextMachine()
        saveTourState()
    }

    /// Skip the current machine.
    ///
    /// A change note on the machine is quit as "not rebuilt" first: its slots
    /// stay open for the next tour and everything packed for them rides along
    /// as van leftovers, booked at the end of the tour. If that cannot be
    /// saved the machine is not skipped.
    func skipMachine(machineId: UUID) async {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }) else { return }
        if machineHasRebuild(machineId) {
            isSaving = true
            let result = await applyRebuild(machineId: machineId, skipAll: true)
            isSaving = false
            guard result != nil else { return }
        }
        if currentRebuildMachineId == machineId { resetCurrentRebuild() }
        machines[mi].isSkipped = true

        // Record in tour log
        tourLog.append(TourLogEntry(
            machineId: machineId,
            machineName: machines[mi].machine.displayName,
            traysRefilled: 0,
            totalAdded: 0,
            skipped: true
        ))

        // Write skip activity log entry (non-blocking)
        await writeActivityLog(
            machineId: machineId,
            machineName: machines[mi].machine.displayName,
            action: "stock_refill_tour_skip",
            extraMetadata: [:]
        )

        advanceToNextMachine()
        saveTourState()
    }

    private func advanceToNextMachine() {
        let remaining = machines.filter { $0.isPacked && !$0.isRefilled && !$0.isSkipped }
        if remaining.isEmpty {
            currentStep = .summary
        }
        // currentMachineIndex stays at 0 since we always look at the first remaining
        currentMachineIndex = 0
    }

    // MARK: - Activity Log

    /// Write an activity log entry for a refill/skip action. Non-critical — failures are silently logged.
    private func writeActivityLog(machineId: UUID?, machineName: String?, action: String, extraMetadata: [String: AnyJSON]) async {
        do {
            let session = try await client.auth.session
            let user = session.user
            let firstName = user.userMetadata["first_name"]?.stringValue
            let lastName = user.userMetadata["last_name"]?.stringValue
            let fullName = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let userDisplay = fullName.isEmpty ? user.email : fullName

            // Fetch company_id from organization_members
            struct OrgMember: Decodable { let companyId: UUID; enum CodingKeys: String, CodingKey { case companyId = "company_id" } }
            let members: [OrgMember] = try await client
                .from("organization_members")
                .select("company_id")
                .eq("user_id", value: user.id.uuidString)
                .limit(1)
                .execute()
                .value
            guard let companyId = members.first?.companyId else { return }

            var metadata: [String: AnyJSON] = [
                "tour_id": .string(tourId),
                "_user_email": user.email.map { .string($0) } ?? .null,
                "_user_display": userDisplay.map { .string($0) } ?? .null,
            ]
            if let machineId { metadata["machine_id"] = .string(machineId.uuidString) }
            if let machineName { metadata["machine_name"] = .string(machineName) }
            if let warehouseId = selectedWarehouseId {
                metadata["warehouse_id"] = .string(warehouseId.uuidString)
            }
            for (key, value) in extraMetadata {
                metadata[key] = value
            }

            try await client
                .from("activity_log")
                .insert([
                    "company_id": AnyJSON.string(companyId.uuidString),
                    "user_id": AnyJSON.string(user.id.uuidString),
                    "entity_type": AnyJSON.string("stock"),
                    "entity_id": AnyJSON.string(machineId?.uuidString ?? tourId),
                    "action": AnyJSON.string(action),
                    "metadata": AnyJSON.object(metadata)
                ])
                .execute()
        } catch {
            print("[RefillWizard] Activity log write failed: \(error)")
            // Non-critical — don't block the refill flow
        }
    }

    // MARK: - Cash book integration

    /// Set of machine IDs visited during this tour (non-skipped).
    var visitedMachineIds: Set<UUID> {
        Set(tourLog.filter { !$0.skipped }.map { $0.machineId })
    }

    /// Resolves which Barkassen need cash collection from this tour. Issues
    /// one RPC per candidate Barkasse (typically 0–2). Does NOT mutate the
    /// VM's `theoreticalCash` — uses `fetchTheoreticalCash(for:)` for an
    /// isolated read.
    func resolveTourCash(using cashBookVM: CashBookViewModel) async -> TourCashResolution {
        let visited = visitedMachineIds
        let candidates = cashBookVM.barkassenForVisitedMachines(visited)
        var withCash: [CashBook] = []
        var cashMap: [UUID: Double] = [:]
        for cb in candidates {
            guard let tc = await cashBookVM.fetchTheoreticalCash(for: cb.id) else { continue }
            // Scope the expected cash to the machines actually visited on this
            // tour. `cashSalesSince` would count machines on the same Barkasse
            // that were never touched, so a partial tour would imply the
            // operator emptied all of them.
            let scoped = tc.expectedCash(forMachines: visited)
            if scoped > 0.001 {
                withCash.append(cb)
                cashMap[cb.id] = scoped
            }
        }
        return TourCashResolution(barkassen: withCash, cashByCashBookId: cashMap)
    }

    // MARK: - Reset

    func reset() {
        currentStep = .review
        replacements = []
        reviewCompleted = false
        currentMachineIndex = 0
        tourLog = []
        tourId = ""
        hasSavedTour = false
        packedItems = [:]
        customQuantities = [:]
        staleStockTrayIds = []
        changeRequests = [:]
        rebuildDecisions = [:]
        rebuildPacked = [:]
        rebuildPackTicks = [:]
        rebuildCustomQuantities = [:]
        tourLeftovers = [:]
        tourLeftoversReturned = false
        leftoverVanQty = [:]
        leftoverMachineQty = [:]
        leftoverDestinations = [:]
        leftoverExpiry = [:]
        expirySuggestionsLoaded = false
        replacementNotice = nil
        tourNotes = []
        tourNoteError = nil
        resetCurrentRebuild()
        // Re-arm the entry gate so the next Refill-tab appearance reloads
        // fresh machine data for a brand-new tour instead of being skipped.
        didRunInitialLoad = false
        Self.clearSavedTour()
        for i in machines.indices {
            machines[i].isPacked = false
            machines[i].isRefilled = false
            machines[i].isSkipped = false
            for j in machines[i].trays.indices {
                machines[i].trays[j].fillAmount = machines[i].trays[j].tray.deficit
            }
        }
    }
}

// MARK: - TourCashResolution

/// Result of resolving Barkassen-with-cash for a refill tour. Used by
/// `RefillSummaryView` to drive both the multi-Barkasse block and the
/// single-Barkasse auto-sheet.
struct TourCashResolution {
    let barkassen: [CashBook]                // those with cashSalesSince > 0
    let cashByCashBookId: [UUID: Double]     // map for O(1) lookup in the UI
}
