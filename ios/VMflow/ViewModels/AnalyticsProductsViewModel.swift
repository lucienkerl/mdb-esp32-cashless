// ios/VMflow/ViewModels/AnalyticsProductsViewModel.swift
import Foundation
import Combine

@MainActor
final class AnalyticsProductsViewModel: ObservableObject {
    @Published var data: AnalyticsProductsData?
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
            p_to:             filter.to,
            p_compare_from:  nil,
            p_compare_to:    nil,
            p_machine_ids:   filter.machines.compactMap(UUID.init),
            p_channels:      filter.channels,
            p_category_ids:  filter.categories.compactMap(UUID.init),
            p_vat_rates:     filter.vatRates
        )

        do {
            let result: AnalyticsProductsData = try await client
                .rpc("analytics_products", params: params)
                .execute()
                .value
            self.data = result
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
                domain: "AnalyticsProductsVM",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not determine company")]
            )
        }
        return companyId
    }
}

// MARK: - Response shape

struct AnalyticsProductsData: Codable {
    let version: Int
    let kpis: KPIs
    let products: [ProductRow]
    let mixShiftSeries: [MixShiftPoint]

    enum CodingKeys: String, CodingKey {
        case version, kpis, products
        case mixShiftSeries = "mix_shift_series"
    }

    struct KPIs: Codable {
        let activeCount: Int
        let slowMoverCount: Int
        let discontinuedCount: Int
        let categoriesWithSales: Int

        enum CodingKeys: String, CodingKey {
            case activeCount = "active_count"
            case slowMoverCount = "slow_mover_count"
            case discontinuedCount = "discontinued_count"
            case categoriesWithSales = "categories_with_sales"
        }
    }

    struct ProductRow: Codable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let imagePath: String?
        let categoryId: UUID?
        let velocity: Double
        let units: Int
        let revenue: Double
        let mixPct: Double
        let vatRate: Double?
        let lastSoldAt: Date?
        let status: String   // active | slow | dead | discontinued
        let slowMoverDays: Int

        enum CodingKeys: String, CodingKey {
            case id, name
            case imagePath = "image_path"
            case categoryId = "category_id"
            case velocity, units, revenue
            case mixPct = "mix_pct"
            case vatRate = "vat_rate"
            case lastSoldAt = "last_sold_at"
            case status
            case slowMoverDays = "slow_mover_days"
        }
    }

    struct MixShiftPoint: Codable, Equatable {
        /// DATE column — kept raw because Supabase Swift's default decoder
        /// expects ISO-8601 timestamps and chokes on bare `2026-04-15`.
        let date: String
        let categoryId: UUID?
        let revenue: Double

        enum CodingKeys: String, CodingKey {
            case date
            case categoryId = "category_id"
            case revenue
        }
    }
}
