import Foundation
import Supabase

/// Fetches all vending machines with per-machine statistics (revenue, stock health).
/// Sorts machines by stock urgency: critical > low > fill > ok.
@MainActor
final class MachineListViewModel: ObservableObject {
    @Published var machines: [MachineStats] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchText = ""

    private let client = SupabaseService.shared.client

    /// Filtered machines based on search text.
    var filteredMachines: [MachineStats] {
        if searchText.isEmpty { return machines }
        let query = searchText.lowercased()
        return machines.filter { $0.machine.displayName.lowercased().contains(query) }
    }

    // MARK: - Load

    func loadMachines() async {
        isLoading = true
        error = nil

        do {
            // 1. Fetch machines with embedded relation
            let machines: [VendingMachine] = try await client
                .from("vendingMachine")
                .select("id, name, location_lat, location_lon, embedded, country_code, address_street, address_house_number, address_postal_code, address_city, formatted_address, nayax_machine_id, public_listing, linked_selections, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version, firmware_build_date, mdb_address, mdb_diagnostics, last_restart_reason, last_restart_at, online_since)")
                .execute()
                .value

            // 2. Fetch recent sales (2 weeks for weekly stats)
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

            // Week boundaries (Monday-based)
            let weekday = calendar.component(.weekday, from: startOfToday)
            // .weekday: 1=Sun, 2=Mon, ... 7=Sat → days since Monday
            let daysSinceMonday = (weekday + 5) % 7
            let startOfThisWeek = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday)!
            let startOfLastWeek = calendar.date(byAdding: .day, value: -7, to: startOfThisWeek)!

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let recentSales: [Sale] = try await client
                .from("sales")
                .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
                .gte("created_at", value: formatter.string(from: startOfLastWeek))
                .execute()
                .value

            // Group sales by machine
            let salesByMachine = Dictionary(grouping: recentSales, by: { $0.machineId })

            // 3. Fetch all trays for stock health
            let allTrays: [Tray] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
                .execute()
                .value

            let traysByMachine = Dictionary(grouping: allTrays, by: { $0.machineId })

            // 4. Fetch paxcounter data
            let paxData: [PaxcounterEntry] = try await client
                .from("paxcounter")
                .select("id, embedded_id, count, created_at")
                .order("created_at", ascending: false)
                .execute()
                .value

            // Get latest pax per embedded
            var latestPax: [UUID: Int] = [:]
            for entry in paxData {
                if let embId = entry.embeddedId, latestPax[embId] == nil {
                    latestPax[embId] = entry.count
                }
            }

            // 5. Fetch warehouse stock batches for availability info
            let stockBatches: [WarehouseStockBatchLite] = try await client
                .from("warehouse_stock_batches")
                .select("product_id, quantity")
                .gt("quantity", value: 0)
                .execute()
                .value

            // Presence check, like the PWA's `buildWarehouseStockInfo`: a
            // product is refillable when any positive batch exists; with no
            // batches at all every product counts as refillable.
            let warehouseProductIds = Set(stockBatches.map(\.productId))
            let hasWarehouses = !stockBatches.isEmpty

            // 6. Build MachineStats
            var stats: [MachineStats] = []

            for machine in machines {
                var ms = MachineStats(machine: machine)

                // Sales — classify into today, yesterday, this week, last week
                let machineSales = salesByMachine[machine.id] ?? []
                for sale in machineSales {
                    let price = sale.itemPrice ?? 0
                    if sale.createdAt >= startOfToday {
                        ms.todayRevenue += price
                        ms.todaySalesCount += 1
                    } else if sale.createdAt >= startOfYesterday {
                        ms.yesterdayRevenue += price
                        ms.yesterdaySalesCount += 1
                    }
                    // Weekly buckets (includes today/yesterday)
                    if sale.createdAt >= startOfThisWeek {
                        ms.thisWeekRevenue += price
                        ms.thisWeekSalesCount += 1
                    } else if sale.createdAt >= startOfLastWeek {
                        ms.lastWeekRevenue += price
                        ms.lastWeekSalesCount += 1
                    }
                }

                // Stock: warehouse-aware per-product counts, shared with the
                // machine detail tile (`MachineStats.applyStock`).
                ms.warehouseProductIds = warehouseProductIds
                ms.hasWarehouses = hasWarehouses
                ms.applyStock(trays: traysByMachine[machine.id] ?? [])

                // Paxcounter
                if let embeddedId = machine.embedded {
                    ms.paxcounterCount = latestPax[embeddedId]
                }

                stats.append(ms)
            }

            // Devices that need attention (offline, no response, machine not
            // talking to the reader) first, then by stock urgency (critical,
            // low, fill, ok; then more low+empty products first). Stable, so
            // ties keep the fetch order like the PWA.
            let now = Date()
            self.machines = stats.enumerated().sorted { a, b in
                let ca = a.element.machine.connectivity(now: now).needsAttention
                let cb = b.element.machine.connectivity(now: now).needsAttention
                if ca != cb { return ca }
                let pa = a.element.sortPriority, pb = b.element.sortPriority
                return pa != pb ? pa < pb : a.offset < b.offset
            }.map(\.element)

        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Paxcounter Model

private struct PaxcounterEntry: Codable {
    let id: UUID
    let embeddedId: UUID?
    let count: Int
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, count
        case embeddedId = "embedded_id"
        case createdAt = "created_at"
    }
}

// MARK: - Lightweight warehouse stock batch for availability queries

private struct WarehouseStockBatchLite: Codable {
    let productId: UUID
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case quantity
        case productId = "product_id"
    }
}
