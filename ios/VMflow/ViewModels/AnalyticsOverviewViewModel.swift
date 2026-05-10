// ios/VMflow/ViewModels/AnalyticsOverviewViewModel.swift
import Foundation
import Combine

@MainActor
final class AnalyticsOverviewViewModel: ObservableObject {
    @Published var data: AnalyticsOverviewData?
    @Published var isLoading = false
    @Published var error: String?
    /// Realtime hint — flips true when a new sale arrives so the view can show a banner.
    @Published var hasNewData = false

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

    /// Subscribes to RealtimeService.salesVersion to surface a "new data available" hint.
    func subscribeRealtime() {
        RealtimeService.shared.$salesVersion
            .dropFirst()
            .sink { [weak self] _ in
                self?.hasNewData = true
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

        let compareFrom: Date?
        let compareTo: Date?
        if filter.compare,
           let dayDelta = Calendar.current.dateComponents([.day], from: filter.from, to: filter.to).day {
            compareTo = filter.from
            compareFrom = Calendar.current.date(byAdding: .day, value: -dayDelta, to: filter.from)
        } else {
            compareFrom = nil
            compareTo = nil
        }

        let params = Params(
            p_company_id:    companyId,
            p_from:          filter.from,
            p_to:            filter.to,
            p_compare_from:  compareFrom,
            p_compare_to:    compareTo,
            p_machine_ids:   filter.machines.compactMap(UUID.init),
            p_channels:      filter.channels,
            p_category_ids:  filter.categories.compactMap(UUID.init),
            p_vat_rates:     filter.vatRates
        )

        do {
            let result: AnalyticsOverviewData = try await client
                .rpc("analytics_overview", params: params)
                .execute()
                .value
            self.data = result
            self.hasNewData = false
        } catch is CancellationError {
            // Silent — refreshable cancels routinely
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
                domain: "AnalyticsOverviewVM",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not determine company")]
            )
        }
        return companyId
    }
}

// MARK: - Response shape

struct AnalyticsOverviewData: Codable {
    let version: Int
    let kpis: KPIs
    let kpisCompare: KPIs?
    let dailySeries: [DailyPoint]
    let topProducts: [TopProductRow]
    let topMachines: [TopMachineRow]

    enum CodingKeys: String, CodingKey {
        case version, kpis
        case kpisCompare = "kpis_compare"
        case dailySeries = "daily_series"
        case topProducts = "top_products"
        case topMachines = "top_machines"
    }

    struct KPIs: Codable {
        let revenue: Double
        let units: Int
        let avgBasket: Double
        let conversionPct: Double?

        enum CodingKeys: String, CodingKey {
            case revenue, units
            case avgBasket = "avg_basket"
            case conversionPct = "conversion_pct"
        }
    }

    struct DailyPoint: Codable, Identifiable {
        var id: String { date }
        /// 'YYYY-MM-DD' string from jsonb — parsed with a static formatter on display.
        let date: String
        let revenue: Double
        let units: Int
    }

    struct TopProductRow: Codable, Identifiable {
        var id: UUID { productId }
        let productId: UUID
        let name: String
        let imagePath: String?
        let units: Int
        let revenue: Double
        let mixPct: Double

        enum CodingKeys: String, CodingKey {
            case productId = "product_id"
            case name
            case imagePath = "image_path"
            case units
            case revenue
            case mixPct = "mix_pct"
        }
    }

    struct TopMachineRow: Codable, Identifiable {
        var id: UUID { machineId }
        let machineId: UUID
        let name: String
        let status: String?
        let revenue: Double

        enum CodingKeys: String, CodingKey {
            case machineId = "machine_id"
            case name
            case status
            case revenue
        }
    }
}
