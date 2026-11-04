import Foundation
import Supabase

/// Drives the Dashboard view with KPIs, 30-day chart data, and the recent-activity feed.
@MainActor
final class DashboardViewModel: ObservableObject {
    // MARK: - Published State

    @Published var todayRevenue: Double = 0
    @Published var todaySalesCount: Int = 0
    @Published var yesterdayRevenue: Double = 0
    @Published var yesterdaySalesCount: Int = 0
    @Published var weekRevenue: Double = 0
    @Published var weekSalesCount: Int = 0
    @Published var lastWeekRevenue: Double = 0
    @Published var lastWeekSalesCount: Int = 0
    @Published var monthRevenue: Double = 0
    @Published var monthSalesCount: Int = 0
    @Published var lastMonthRevenue: Double = 0
    @Published var lastMonthSalesCount: Int = 0

    @Published var machinesOnline: Int = 0
    /// Machines that have a device (machines without one are not counted as offline).
    @Published var machinesTotal: Int = 0
    @Published var fleet = FleetConnectivity()
    @Published var stockCriticalCount: Int = 0
    @Published var stockLowCount: Int = 0
    @Published var newDealsCount: Int = 0

    @Published var dailySales: [DailySales] = []
    /// Merged dashboard timeline: sales + refills + tour starts + intake sessions.
    @Published var recentActivity: [ActivityFeedItem] = []

    /// Number of days back from start_of_today the activity window covers.
    /// 0 = today only; 6 = last 7 days; 13 = last 14 days; 7N−1 after N expansions.
    @Published var activityDaysBack: Int = 0

    /// Becomes false when widening the window brings no additional source rows
    /// (history exhausted). Resets to true when a reload brings in more rows
    /// (e.g. realtime delivery into the current window).
    @Published var hasMoreActivity: Bool = true

    /// True while an infinite-scroll fetch is in flight — drives the sentinel spinner.
    @Published var isLoadingMoreActivity: Bool = false

    /// Raw source-row count (sales + activity rows + intake transactions) of the
    /// last load. Exhaustion compares RAW rows, not merged items — new transactions
    /// merging into an existing boundary IntakeGroup would otherwise leave the
    /// merged count unchanged and falsely signal "exhausted" (spec §2). Published
    /// (read-only) because the infinite-scroll sentinel keys its `.task(id:)` on it
    /// to re-arm after every completed load.
    @Published private(set) var rawSourceRowCount = 0

    /// True after a real (non-cancellation) load-more failure — the sentinel
    /// renders a manual Retry row instead of a spinner until the next attempt.
    @Published var loadMoreFailed = false

    /// user_id → display name cache for intake attribution (users table lookups).
    private var userNameCache: [UUID: String] = [:]
    /// Product names for slot change feed rows, keyed by lowercased product id.
    private var productNameCache: [String: String] = [:]

    @Published var isLoading = false
    @Published var error: String?

    /// Average daily revenue over the loaded daily-chart window, including zero-revenue days.
    /// Σ revenue / dailySales.count. The chart header says "30 days" but loadDailyChart()
    /// actually pre-populates 31 daily buckets (`for dayOffset in 0..<31`); we divide by the
    /// actual array count so the average matches what's visually rendered.
    var dailyAverage: Double {
        guard !dailySales.isEmpty else { return 0 }
        return dailySales.reduce(0) { $0 + $1.revenue } / Double(dailySales.count)
    }

    /// Total revenue over the loaded daily-chart window — matches the sum of all bars in the chart.
    /// Used in the chart header instead of `monthRevenue` so the displayed total stays in sync with
    /// the visible 30-day window rather than jumping to the current calendar month's running total.
    var dailyTotal: Double {
        dailySales.reduce(0) { $0 + $1.revenue }
    }

    private let client = SupabaseService.shared.client

    // MARK: - Load All

    func loadDashboard() async {
        isLoading = true
        error = nil

        do {
            async let salesTask: () = loadSalesKPIs()
            async let machinesTask: () = loadMachineStats()
            async let chartTask: () = loadDailyChart()
            async let recentTask: () = loadRecentActivity()
            async let newDealsTask: () = loadNewDealsCount()

            _ = try await (salesTask, machinesTask, chartTask, recentTask, newDealsTask)
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - New deals

    /// Count of new/unhandled deals for the current user (dashboard banner).
    /// Swallows errors so backends without the RPC don't break the dashboard.
    private func loadNewDealsCount() async {
        do {
            newDealsCount = try await client
                .rpc("get_new_deals_count")
                .execute()
                .value
        } catch {
            newDealsCount = 0
        }
    }

    // MARK: - Sales KPIs

    private func loadSalesKPIs() async throws {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let startOfLastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfWeek)!
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfMonth)!

        // Query the earliest of the prior-period boundaries so all KPI buckets
        // can be filled from a single fetch.
        let queryLowerBound = [startOfLastMonth, startOfLastWeek, startOfYesterday].min()!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
            .gte("created_at", value: formatter.string(from: queryLowerBound))
            .order("created_at", ascending: false)
            .execute()
            .value

        var todayRev = 0.0, todayCount = 0
        var yesterdayRev = 0.0, yesterdayCount = 0
        var weekRev = 0.0, weekCount = 0
        var lastWeekRev = 0.0, lastWeekCount = 0
        var monthRev = 0.0, monthCount = 0
        var lastMonthRev = 0.0, lastMonthCount = 0

        for sale in sales {
            let price = sale.itemPrice ?? 0
            let createdAt = sale.createdAt

            // Month buckets — current vs previous full calendar month
            if createdAt >= startOfMonth {
                monthRev += price
                monthCount += 1
            } else if createdAt >= startOfLastMonth && createdAt < startOfMonth {
                lastMonthRev += price
                lastMonthCount += 1
            }

            // Week buckets — current vs previous full ISO week
            if createdAt >= startOfWeek {
                weekRev += price
                weekCount += 1
            } else if createdAt >= startOfLastWeek && createdAt < startOfWeek {
                lastWeekRev += price
                lastWeekCount += 1
            }

            // Day buckets — today vs yesterday
            if createdAt >= startOfToday {
                todayRev += price
                todayCount += 1
            } else if createdAt >= startOfYesterday && createdAt < startOfToday {
                yesterdayRev += price
                yesterdayCount += 1
            }
        }

        todayRevenue = todayRev
        todaySalesCount = todayCount
        yesterdayRevenue = yesterdayRev
        yesterdaySalesCount = yesterdayCount
        weekRevenue = weekRev
        weekSalesCount = weekCount
        lastWeekRevenue = lastWeekRev
        lastWeekSalesCount = lastWeekCount
        monthRevenue = monthRev
        monthSalesCount = monthCount
        lastMonthRevenue = lastMonthRev
        lastMonthSalesCount = lastMonthCount
    }

    // MARK: - Machine Stats

    private func loadMachineStats() async throws {
        let machines: [VendingMachine] = try await client
            .from("vendingMachine")
            .select("id, name, location_lat, location_lon, embedded, country_code, linked_selections, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version, mdb_diagnostics, online_since)")
            .execute()
            .value

        let now = Date()
        fleet = FleetConnectivity(machines.map { $0.connectivity(now: now) })
        machinesTotal = fleet.devices
        machinesOnline = fleet.online

        // Load all trays for stock health
        let trays: [Tray] = try await client
            .from("machine_trays")
            .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
            .execute()
            .value

        // Warehouse availability — a tray whose product the warehouse can't
        // refill is a swap candidate, not a refill alert.
        var stockBatches: [DashboardStockBatch] = []
        do {
            stockBatches = try await client
                .from("warehouse_stock_batches")
                .select("product_id, quantity")
                .gt("quantity", value: 0)
                .execute()
                .value
        } catch {
            // Enrichment, not core data: a failure degrades to "no warehouse
            // data" (every product refillable = the pre-warehouse behaviour)
            // instead of failing the whole dashboard. Cancellation is not a
            // failure — propagate it, or a cancelled refresh would publish
            // counts classified against an empty warehouse.
            if error is CancellationError || Task.isCancelled { throw error }
        }
        let warehouseProductIds = Set(stockBatches.map(\.productId))
        let hasWarehouses = !stockBatches.isEmpty

        let summaries = MachineStockHealth.summaries(
            trays: trays,
            warehouseProductIds: warehouseProductIds,
            hasWarehouses: hasWarehouses,
            linkedMachineIds: Set(machines.filter(\.linkedSelections).map(\.id))
        )
        // Machines without a single tray row never reach `summaries` — they
        // have nothing to refill, which is exactly the `ok` bucket.
        let buckets = MachineStockHealth.buckets(summaries.values)

        stockCriticalCount = buckets.critical
        stockLowCount = buckets.low
    }

    // MARK: - Daily Chart (30 days)

    private func loadDailyChart() async throws {
        let calendar = Calendar.current
        let now = Date()
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
            .gte("created_at", value: formatter.string(from: thirtyDaysAgo))
            .order("created_at", ascending: true)
            .execute()
            .value

        // Group by day
        var dailyMap: [Date: (revenue: Double, count: Int)] = [:]

        // Pre-populate all 30 days
        for dayOffset in 0..<31 {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: thirtyDaysAgo)!
            let startOfDay = calendar.startOfDay(for: day)
            dailyMap[startOfDay] = (0, 0)
        }

        for sale in sales {
            let day = calendar.startOfDay(for: sale.createdAt)
            let existing = dailyMap[day] ?? (0, 0)
            dailyMap[day] = (existing.revenue + (sale.itemPrice ?? 0), existing.count + 1)
        }

        dailySales = dailyMap
            .map { DailySales(date: $0.key, revenue: $0.value.revenue, count: $0.value.count) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Recent Activity (sales + refills + tour starts + intakes)

    private func loadRecentActivity() async throws {
        // Window start: start_of_today − activityDaysBack days.
        // daysBack=0 → start_of_today (only today's events since midnight, NOT last 24h).
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -activityDaysBack, to: startOfToday)!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let windowStartString = formatter.string(from: windowStart)

        // All three sources fail-or-succeed together (spec §2: no sales-only degrade).
        async let salesTask = fetchRecentSaleItems(windowStartString: windowStartString)
        async let activityTask = fetchActivityRows(windowStartString: windowStartString)
        async let intakeTask = fetchIntakeRows(windowStartString: windowStartString)
        let (sales, rawSalesCount) = try await salesTask
        let activityRows = try await activityTask
        let intakeRows = try await intakeTask

        var groups = ActivityFeedBuilder.groupIntakes(intakeRows)
        let names = await resolveUserNames(for: groups.compactMap { $0.userId })
        // resolveUserNames degrades failures (incl. cancellation) to empty results —
        // re-check so a cancelled load dies cleanly instead of committing.
        try Task.checkCancellation()
        for i in groups.indices {
            if let uid = groups[i].userId { groups[i].userDisplay = names[uid] }
        }

        // Slot change rows carry ids only: name their authors and products.
        let slotChangeIds = ActivityFeedBuilder.slotChangeLookupIds(activityRows)
        let slotChangeUsers = await resolveUserNames(for: slotChangeIds.users)
        let productNames = await resolveProductNames(for: slotChangeIds.products)
        try Task.checkCancellation()

        let rawBefore = rawSourceRowCount
        rawSourceRowCount = rawSalesCount + activityRows.count + intakeRows.count
        recentActivity = ActivityFeedBuilder.mergeFeed(
            sales: sales, activityRows: activityRows, intakeGroups: groups,
            userNames: slotChangeUsers, productNames: productNames
        )
        loadMoreFailed = false

        // Recovery: if a reload brought in more raw rows than before (e.g. realtime
        // delivery into the current window), un-exhaust the infinite scroll.
        if rawSourceRowCount > rawBefore {
            hasMoreActivity = true
        }
    }

    /// Existing recent-sales pipeline, unchanged: sales + machine names + product
    /// fallback via trays. Returns the display items plus the raw row count.
    private func fetchRecentSaleItems(windowStartString: String) async throws -> ([SaleWithMachine], Int) {
        // Fetch sales with snapshotted product via FK join.
        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel, product_id, products(name, image_path)")
            .gte("created_at", value: windowStartString)
            .order("created_at", ascending: false)
            .execute()
            .value

        // Fetch machine names for these sales
        let machineIds = Set(sales.compactMap { $0.machineId })
        var machineNames: [UUID: String] = [:]

        if !machineIds.isEmpty {
            let machines: [VendingMachine] = try await client
                .from("vendingMachine")
                .select("id, name, location_lat, location_lon, embedded, country_code")
                .in("id", values: machineIds.map { $0.uuidString })
                .execute()
                .value

            for m in machines {
                machineNames[m.id] = m.displayName
            }
        }

        // Fallback: fetch tray→product lookup only for old sales without product_id
        let salesWithoutProduct = sales.filter { $0.productId == nil && $0.machineId != nil }
        var trayProductLookup: [String: (name: String?, imagePath: String?)] = [:]

        if !salesWithoutProduct.isEmpty {
            let fallbackMachineIds = Set(salesWithoutProduct.compactMap { $0.machineId })
            let trays: [Tray] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
                .in("machine_id", values: fallbackMachineIds.map { $0.uuidString })
                .execute()
                .value

            for tray in trays {
                let key = "\(tray.machineId)_\(tray.itemNumber)"
                trayProductLookup[key] = (name: tray.products?.name, imagePath: tray.products?.imagePath)
            }
        }

        let items = sales.map { sale in
            let machineName = sale.machineId.flatMap { machineNames[$0] }

            // Prefer snapshotted product from FK join, fallback to tray lookup
            var productName: String? = sale.products?.name
            var productImagePath: String? = sale.products?.imagePath

            if productName == nil, let machineId = sale.machineId, let itemNum = sale.itemNumber {
                let trayProduct = trayProductLookup["\(machineId)_\(itemNum)"]
                productName = trayProduct?.name
                productImagePath = trayProduct?.imagePath
            }

            return SaleWithMachine(sale: sale, machineName: machineName, productName: productName, productImagePath: productImagePath)
        }
        return (items, sales.count)
    }

    /// Refill + tour-start + slot-change + cash-book rows. RLS scopes to the user's company.
    private func fetchActivityRows(windowStartString: String) async throws -> [ActivityLogRow] {
        try await client
            .from("activity_log")
            .select("id, created_at, user_id, action, metadata")
            .in("action", values: ["stock_refill_tour", "tour_started", "slot_change_applied", "cash_book_entry_created"])
            .gte("created_at", value: windowStartString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Incoming warehouse transactions with product/warehouse names joined.
    /// Both type strings are read: the PWA books intakes as 'incoming', the
    /// iOS app as 'intake' (pre-existing cross-client divergence).
    private func fetchIntakeRows(windowStartString: String) async throws -> [IntakeTransactionRow] {
        try await client
            .from("warehouse_transactions")
            .select("id, created_at, warehouse_id, user_id, quantity_change, products(name), warehouses(name)")
            .in("transaction_type", values: ["incoming", "intake"])
            .gte("created_at", value: windowStartString)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Resolve display names for intake attribution. The users-table FK points
    /// to auth.users, so PostgREST can't embed it — same lookup pattern as
    /// ProductDetailSheet. Failures degrade to no name (non-critical).
    private func resolveUserNames(for ids: [UUID]) async -> [UUID: String] {
        struct UserRow: Decodable {
            let id: UUID
            let firstName: String?
            let lastName: String?
            let email: String?
            enum CodingKeys: String, CodingKey {
                case id, email
                case firstName = "first_name"
                case lastName = "last_name"
            }
        }

        let missing = Array(Set(ids.filter { userNameCache[$0] == nil }))
        if !missing.isEmpty {
            let rows: [UserRow] = (try? await client
                .from("users")
                .select("id, first_name, last_name, email")
                .in("id", values: missing.map { $0.uuidString })
                .execute()
                .value) ?? []
            for u in rows {
                let full = [u.firstName, u.lastName].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " ")
                userNameCache[u.id] = full.isEmpty ? (u.email ?? String(u.id.uuidString.prefix(8))) : full
            }
        }

        var out: [UUID: String] = [:]
        for id in ids { out[id] = userNameCache[id] }
        return out
    }

    /// Product names for the slot change rows (ids lowercased). Failures
    /// degrade to no name — the row then shows the slot number only.
    private func resolveProductNames(for ids: [String]) async -> [String: String] {
        struct ProductRow: Decodable {
            let id: UUID
            let name: String?
        }

        let missing = Array(Set(ids.filter { productNameCache[$0] == nil }))
        if !missing.isEmpty {
            let rows: [ProductRow] = (try? await client
                .from("products")
                .select("id, name")
                .in("id", values: missing)
                .execute()
                .value) ?? []
            for p in rows {
                if let name = p.name { productNameCache[p.id.uuidString.lowercased()] = name }
            }
        }

        var out: [String: String] = [:]
        for id in ids { out[id] = productNameCache[id] }
        return out
    }

    // MARK: - Load More (infinite scroll)

    /// Expand the activity window: today (1 day) → 7 days → 14 days → 21 days → …
    /// Triggered by the feed's bottom sentinel. Each call adds 7 more days;
    /// the first jumps from 1 to 7 (i.e. +6 days).
    func loadMoreRecentActivity() async {
        guard !isLoadingMoreActivity, !isLoading, hasMoreActivity else { return }

        let previousDaysBack = activityDaysBack
        let nextDaysBack = previousDaysBack == 0 ? 6 : previousDaysBack + 7

        isLoadingMoreActivity = true
        loadMoreFailed = false
        defer { isLoadingMoreActivity = false }

        let rawBefore = rawSourceRowCount
        activityDaysBack = nextDaysBack

        do {
            try await loadRecentActivity()
            // Same raw row count in a wider window → history exhausted.
            if rawSourceRowCount == rawBefore {
                hasMoreActivity = false
            }
        } catch is CancellationError {
            // Cancelled (sentinel unmounted by a concurrent dashboard reload, or
            // scrolled far away). Do NOT revert the window: a concurrent
            // loadDashboard already read the widened value — reverting would make
            // the sentinel re-fetch the same window and falsely flag "exhausted".
            // A scroll-away cancel merely skips one 7-day step on the next fire.
        } catch {
            // URLSession can surface cancellation as URLError(.cancelled), which
            // lands here instead of the CancellationError case — same no-revert
            // treatment.
            if Task.isCancelled { return }
            // Real server/network error: revert the window so the retry re-fetches
            // the same step; the sentinel switches to a manual Retry row (a plain
            // spinner would sit idle — nothing re-fires its .task after a failure).
            activityDaysBack = previousDaysBack
            loadMoreFailed = true
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Lightweight warehouse stock batch for the dashboard's refill check

/// Mirrors `WarehouseStockBatchLite` in `MachineListViewModel` — both decode
/// the same two columns; neither is shared because both are file-private.
private struct DashboardStockBatch: Codable {
    let productId: UUID
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case quantity
        case productId = "product_id"
    }
}
