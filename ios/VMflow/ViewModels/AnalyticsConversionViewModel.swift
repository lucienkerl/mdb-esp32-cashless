// ios/VMflow/ViewModels/AnalyticsConversionViewModel.swift
import Foundation
import Combine

@MainActor
final class AnalyticsConversionViewModel: ObservableObject {
    @Published var data: AnalyticsConversionData?
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
            let result: AnalyticsConversionData = try await client
                .rpc("analytics_conversion", params: params)
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
                domain: "AnalyticsConversionVM",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not determine company")]
            )
        }
        return companyId
    }
}

// MARK: - Response shape

struct AnalyticsConversionData: Codable {
    let version: Int
    let kpis: KPIs
    let machines: [MachineRow]
    let hourHeatmap: [String: [Double?]]
    let dailyConversionSeries: [DailyPoint]

    enum CodingKeys: String, CodingKey {
        case version, kpis, machines
        case hourHeatmap = "hour_heatmap"
        case dailyConversionSeries = "daily_conversion_series"
    }

    struct KPIs: Codable {
        let footfall: Int
        let conversionPct: Double?
        let bestMachineId: UUID?
        let emptyPasses: Int

        enum CodingKeys: String, CodingKey {
            case footfall
            case conversionPct = "conversion_pct"
            case bestMachineId = "best_machine_id"
            case emptyPasses = "empty_passes"
        }
    }

    struct MachineRow: Codable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let pax: Int
        let sales: Int
        let conversionPct: Double
        let revenuePerVisitor: Double?

        enum CodingKeys: String, CodingKey {
            case id, name, pax, sales
            case conversionPct = "conversion_pct"
            case revenuePerVisitor = "revenue_per_visitor"
        }
    }

    struct DailyPoint: Codable, Identifiable {
        var id: String { date }
        let date: String   // YYYY-MM-DD
        let conversionPct: Double?

        enum CodingKeys: String, CodingKey {
            case date
            case conversionPct = "conversion_pct"
        }
    }
}
