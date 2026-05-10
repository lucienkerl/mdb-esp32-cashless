// ios/VMflow/ViewModels/AnalyticsOperationsViewModel.swift
import Foundation
import Combine

@MainActor
final class AnalyticsOperationsViewModel: ObservableObject {
    @Published var data: AnalyticsOperationsData?
    @Published var isLoading = false
    @Published var error: String?

    private let client = SupabaseService.shared.client
    private var cancellables = Set<AnyCancellable>()
    private weak var filter: AnalyticsFilter?

    /// Wires this ViewModel to a filter so any filter change re-fetches with debounce.
    func bind(filter: AnalyticsFilter) {
        self.filter = filter
        filter.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.load() }
            }
            .store(in: &cancellables)
    }

    struct Params: Encodable {
        let p_company_id: UUID
        let p_from: Date
        let p_to: Date
        let p_compare_from: Date?
        let p_compare_to: Date?
        let p_machine_ids: [UUID]
        let p_channels: [String]
        let p_category_ids: [UUID]
        let p_vat_rates: [Double]
    }

    func load() async {
        guard let filter else { return }

        isLoading = true
        error = nil
        defer { isLoading = false }

        let companyId: UUID
        do {
            companyId = try await fetchCompanyId()
        } catch {
            self.error = error.localizedDescription
            return
        }

        let params = Params(
            p_company_id:    companyId,
            p_from:          filter.from,
            p_to:            filter.to,
            p_compare_from:  nil,
            p_compare_to:    nil,
            p_machine_ids:   filter.machines.compactMap(UUID.init),
            p_channels:      filter.channels,
            p_category_ids:  filter.categories.compactMap(UUID.init),
            p_vat_rates:     filter.vatRates
        )

        do {
            let result: AnalyticsOperationsData = try await client
                .rpc("analytics_operations", params: params)
                .execute()
                .value
            self.data = result
        } catch is CancellationError {
            // Filter debounce cancelled the previous request — no-op
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Resolve the current user's company_id from organization_members.
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
            throw NSError(
                domain: "AnalyticsOperationsVM",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Could not determine company"]
            )
        }
        return companyId
    }
}

// MARK: - Response shape

struct AnalyticsOperationsData: Codable {
    let version: Int
    let kpis: KPIs
    let stockoutEvents: [StockoutEvent]
    let refillTours: [RefillTour]
    let stockCover: [StockCoverRow]

    enum CodingKeys: String, CodingKey {
        case version, kpis
        case stockoutEvents = "stockout_events"
        case refillTours = "refill_tours"
        case stockCover = "stock_cover"
    }

    struct KPIs: Codable {
        let stockoutHours: Double
        let lostRevenue: Double
        let refillTourCount: Int
        let avgStockCoverDays: Double?

        enum CodingKeys: String, CodingKey {
            case stockoutHours = "stockout_hours"
            case lostRevenue = "lost_revenue"
            case refillTourCount = "refill_tour_count"
            case avgStockCoverDays = "avg_stock_cover_days"
        }
    }

    struct StockoutEvent: Codable, Identifiable {
        let id: UUID
        let machineId: UUID
        let machineName: String
        let trayId: UUID
        let itemNumber: Int
        let productId: UUID?
        let productName: String?
        let startedAt: Date
        let endedAt: Date?
        let durationSeconds: Double
        let lostUnitsEstimated: Double
        let lostRevenueEstimated: Double

        enum CodingKeys: String, CodingKey {
            case id
            case machineId = "machine_id"
            case machineName = "machine_name"
            case trayId = "tray_id"
            case itemNumber = "item_number"
            case productId = "product_id"
            case productName = "product_name"
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case durationSeconds = "duration_seconds"
            case lostUnitsEstimated = "lost_units_estimated"
            case lostRevenueEstimated = "lost_revenue_estimated"
        }
    }

    struct RefillTour: Codable, Identifiable {
        var id: String { tourId }
        let tourId: String
        let startedAt: Date
        let endedAt: Date
        let durationMinutes: Int
        let userDisplay: String?
        let machinesCount: Int
        let unitsAdded: Int
        let machines: [TourMachine]

        enum CodingKeys: String, CodingKey {
            case tourId = "tour_id"
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case durationMinutes = "duration_minutes"
            case userDisplay = "user_display"
            case machinesCount = "machines_count"
            case unitsAdded = "units_added"
            case machines
        }

        struct TourMachine: Codable, Identifiable {
            let machineId: UUID
            let machineName: String
            let itemsAdded: Int
            var id: UUID { machineId }

            enum CodingKeys: String, CodingKey {
                case machineId = "machine_id"
                case machineName = "machine_name"
                case itemsAdded = "items_added"
            }
        }
    }

    struct StockCoverRow: Codable, Identifiable {
        var id: UUID { trayId }
        let trayId: UUID
        let machineId: UUID
        let machineName: String
        let itemNumber: Int
        let productId: UUID?
        let productName: String?
        let currentStock: Int
        let velocity: Double
        let coverDays: Double?

        enum CodingKeys: String, CodingKey {
            case trayId = "tray_id"
            case machineId = "machine_id"
            case machineName = "machine_name"
            case itemNumber = "item_number"
            case productId = "product_id"
            case productName = "product_name"
            case currentStock = "current_stock"
            case velocity
            case coverDays = "cover_days"
        }
    }
}
