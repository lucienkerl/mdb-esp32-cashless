// ios/VMflow/ViewModels/AnalyticsSalesViewModel.swift
import Foundation
import Combine

@MainActor
final class AnalyticsSalesViewModel: ObservableObject {
    @Published var data: AnalyticsSalesData?
    @Published var isLoading = false
    @Published var error: String?
    @Published var dimension: String = "machine"

    private let client = SupabaseService.shared.client
    private var cancellables = Set<AnyCancellable>()
    private weak var filter: AnalyticsFilter?

    /// Wires this ViewModel to a filter so any filter change re-fetches with debounce.
    /// Also wires `$dimension` so switching the dimension triggers a fresh fetch
    /// (skipping the initial value — `.task` runs `load()` once on appear).
    func bind(filter: AnalyticsFilter) {
        self.filter = filter
        filter.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.load() }
            }
            .store(in: &cancellables)

        $dimension
            .removeDuplicates()
            .dropFirst()
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
        let p_dimension: String
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
            p_vat_rates:     filter.vatRates,
            p_dimension:     dimension
        )

        do {
            let result: AnalyticsSalesData = try await client
                .rpc("analytics_sales_breakdown", params: params)
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
                domain: "AnalyticsSalesVM",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not determine company")]
            )
        }
        return companyId
    }
}

// MARK: - Response shape

struct AnalyticsSalesData: Codable {
    let version: Int
    let dimension: String
    let rows: [Row]

    struct Row: Codable, Identifiable {
        var id: String { keyAsString }
        let key: AnyKey
        let label: String
        let revenue: Double
        let units: Int
        let avgBasket: Double
        let count: Int
        let shareRevenuePct: Double
        let shareUnitsPct: Double

        var keyAsString: String { key.stringValue }

        enum CodingKeys: String, CodingKey {
            case key, label, revenue, units
            case avgBasket = "avg_basket"
            case count
            case shareRevenuePct = "share_revenue_pct"
            case shareUnitsPct = "share_units_pct"
        }
    }
}

/// Tagged union for the `key` field — RPC emits UUIDs (machine/product/category),
/// strings (channel/vat-as-text), or numbers (hour/dow). We decode any of these
/// to a String for downstream filter mutation.
enum AnyKey: Codable, Equatable {
    case string(String)
    case number(Double)

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        throw DecodingError.typeMismatch(
            AnyKey.self,
            .init(codingPath: decoder.codingPath,
                  debugDescription: "AnyKey requires String or Number")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        }
    }
}
