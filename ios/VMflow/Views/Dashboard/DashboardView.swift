import SwiftUI
import Charts

/// Main dashboard with KPIs, 30-day chart, recent activity, and quick actions.
struct DashboardView: View {
    var onNavigate: (SidebarItem) -> Void = { _ in }
    @EnvironmentObject var auth: AuthService
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject private var realtime: RealtimeService
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Selected date for chart drag-to-scrub. nil = no tooltip visible.
    @State private var selectedDate: Date?

    /// Sale-row product tap → presents `ProductDetailSheet`. nil = no sheet.
    @State private var selectedProduct: ProductSelection?

    /// Push CashBookView when the cash-book tile is tapped.
    @State private var showCashBook = false

    /// Profile menu → "Change Name" sheet.
    @State private var showRenameProfile = false

    /// Feed rows (refill/tour/intake) whose detail list is expanded.
    @State private var expandedActivityIds: Set<String> = []

    struct ProductSelection: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
    }

    private var realtimeVersion: Int {
        realtime.salesVersion + realtime.machinesVersion + realtime.embeddedVersion + realtime.activityVersion
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                newDealsBanner

                // KPI Cards
                kpiSection

                // Cash Book tile
                CashBookCard(onTap: { showCashBook = true })

                // 30-Day Chart
                chartSection

                // Recent Activity
                recentActivitySection
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .navigationDestination(isPresented: $showCashBook) {
            CashBookView()
        }
        .dataRefreshable {
            await viewModel.loadDashboard()
        }
        .navigationTitle(auth.organization?.name ?? "Dashboard")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Shows who is signed in — the same name that lands in the
                    // refill/activity logs, so it is worth surfacing here.
                    Section(auth.displayName) {
                        Button {
                            showRenameProfile = true
                        } label: {
                            Label("Change Name", systemImage: "person.text.rectangle")
                        }
                    }
                    Button(role: .destructive) {
                        Task { await auth.logout() }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "person.circle")
                        .font(.title3)
                }
            }
        }
        .sheet(isPresented: $showRenameProfile) {
            ProfileNameSheet()
                .environmentObject(auth)
        }
        .task {
            await viewModel.loadDashboard()
        }
        .onChange(of: realtimeVersion) { _, _ in
            Task { await viewModel.loadDashboard() }
        }
        .overlay {
            if viewModel.isLoading && viewModel.dailySales.isEmpty {
                ProgressView("Loading dashboard...")
            }
        }
        .sheet(item: $selectedProduct) { sel in
            ProductDetailSheet(
                productId: sel.id,
                fallbackName: sel.name,
                fallbackImagePath: sel.imagePath,
                fallbackSellprice: sel.sellprice
            )
        }
    }

    // MARK: - New deals banner

    /// Green banner shown when the daily refresh brought in new/unhandled deals.
    /// Tapping deep-links into Deals so the user can pin or archive them.
    @ViewBuilder
    private var newDealsBanner: some View {
        if viewModel.newDealsCount > 0 {
            Button {
                onNavigate(.deals)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "tag.fill")
                        .foregroundStyle(.green)
                    Text(viewModel.newDealsCount == 1
                        ? String(localized: "1 new deal")
                        : String(localized: "\(viewModel.newDealsCount) new deals"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.green.opacity(0.7))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.green.opacity(0.12))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.green.opacity(0.3), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - KPI Cards

    private var kpiColumns: [GridItem] {
        if sizeClass == .regular {
            return Array(repeating: GridItem(.flexible()), count: 4)
        }
        return [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var kpiSection: some View {
        VStack(spacing: 12) {
            // Offline-machines warning banner — only when something is wrong.
            if viewModel.machinesTotal > 0 && viewModel.machinesOnline < viewModel.machinesTotal {
                offlineMachinesBanner
            }

            LazyVGrid(columns: kpiColumns, spacing: 12) {
                RevenueKPICard(
                    icon: "sun.max.fill",
                    title: "Today",
                    currentRevenue: viewModel.todayRevenue,
                    currentSales: viewModel.todaySalesCount,
                    previousLabel: "Yesterday",
                    previousRevenue: viewModel.yesterdayRevenue,
                    previousSales: viewModel.yesterdaySalesCount,
                    color: .blue
                )

                RevenueKPICard(
                    icon: "calendar",
                    title: "This Week",
                    currentRevenue: viewModel.weekRevenue,
                    currentSales: viewModel.weekSalesCount,
                    previousLabel: "Last Week",
                    previousRevenue: viewModel.lastWeekRevenue,
                    previousSales: viewModel.lastWeekSalesCount,
                    color: .indigo
                )

                RevenueKPICard(
                    icon: "calendar.badge.clock",
                    title: "This Month",
                    currentRevenue: viewModel.monthRevenue,
                    currentSales: viewModel.monthSalesCount,
                    previousLabel: "Last Month",
                    previousRevenue: viewModel.lastMonthRevenue,
                    previousSales: viewModel.lastMonthSalesCount,
                    color: .purple
                )

                StockAlertsCard(
                    critical: viewModel.stockCriticalCount,
                    low: viewModel.stockLowCount,
                    machinesOnline: viewModel.machinesOnline,
                    machinesTotal: viewModel.machinesTotal
                )
            }
        }
    }

    /// Red banner shown above the KPI grid when not every machine is online.
    private var offlineMachinesBanner: some View {
        let offline = viewModel.machinesTotal - viewModel.machinesOnline
        return Button {
            onNavigate(.machines)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    // Two distinct keys so both pluralize cleanly in the catalog;
                    // interpolating the "s" made the string unlocalizable.
                    (offline == 1 ? Text("1 machine offline") : Text("\(offline) machines offline"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Text("Tap to view")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.red.opacity(0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.red.opacity(0.3), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        // Only rendered once machine data has loaded AND at least one machine
        // is offline — a data-dependent UI-test anchor for the dashboard
        // screenshot (fixtures deliberately have 2/3 machines online).
        .accessibilityIdentifier("dashboard-offline-banner")
    }

}

// MARK: - Dense KPI Cards (Dashboard-only)

/// Period-over-period revenue tile: current period (revenue + sales) on top,
/// previous period (revenue + sales) on the bottom, separated by a divider.
/// All cards are forced to the same minimum height to keep the dashboard grid
/// visually balanced regardless of which previous-period values are present.
private let kpiCardMinHeight: CGFloat = 138

private struct RevenueKPICard: View {
    let icon: String
    let title: LocalizedStringKey
    let currentRevenue: Double
    let currentSales: Int
    let previousLabel: LocalizedStringKey
    let previousRevenue: Double
    let previousSales: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            // Current period
            Text(currentRevenue, format: .currency(code: "EUR"))
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                Image(systemName: "cart.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(currentSales) sales")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Divider()
                .padding(.vertical, 1)

            // Previous period
            Text(previousLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(previousRevenue, format: .currency(code: "EUR"))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(verbatim: "·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("\(previousSales) sales")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: kpiCardMinHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

/// Stock + machines tile — same visual rhythm and identical height as
/// RevenueKPICard. Top half: alert summary. Bottom half: machines online.
private struct StockAlertsCard: View {
    let critical: Int
    let low: Int
    let machinesOnline: Int
    let machinesTotal: Int

    private var alertColor: Color {
        if critical > 0 { return .red }
        if low > 0 { return .yellow }
        return .green
    }

    private var allStockClear: Bool { critical == 0 && low == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                    .font(.subheadline)
                    .foregroundStyle(alertColor)
                Text("Stock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Top half: stock alerts
            if allStockClear {
                Text("OK")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.green)
                Text("All machines stocked")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("\(critical + low) alerts")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(alertColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    if critical > 0 {
                        Label(title: { Text(verbatim: "\(critical)") }, icon: {
                            Circle().fill(.red).frame(width: 6, height: 6)
                        })
                        .labelStyle(InlineDotLabelStyle())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    if low > 0 {
                        Label(title: { Text(verbatim: "\(low)") }, icon: {
                            Circle().fill(.yellow).frame(width: 6, height: 6)
                        })
                        .labelStyle(InlineDotLabelStyle())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            Divider()
                .padding(.vertical, 1)

            // Bottom half: machines online
            Text("Machines online")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: machinesOnline == machinesTotal ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(machinesOnline == machinesTotal ? .green : .red)
                Text(verbatim: "\(machinesOnline) / \(machinesTotal)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: kpiCardMinHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

/// Tight `Label` layout for the stock-alert dot+number pairs so they sit
/// flush together with no extra spacing.
private struct InlineDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - DashboardView (continuation)
//
// Chart, sales-list, and helper functions live in this extension so that
// the file-private RevenueKPICard / StockAlertsCard structs above can be
// declared between the KPI section and the rest without breaking nesting.

extension DashboardView {

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Revenue (30 days)")
                    .font(.headline)
                Spacer()
                Text(formatCurrency(viewModel.dailyTotal))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            if !viewModel.dailySales.isEmpty {
                Chart {
                    ForEach(viewModel.dailySales) { day in
                        BarMark(
                            x: .value("Date", day.date, unit: .day),
                            y: .value("Revenue", day.revenue)
                        )
                        .foregroundStyle(day.isWeekend ? Color.blue.opacity(0.45).gradient : Color.blue.gradient)
                        .cornerRadius(3)
                    }

                    if viewModel.dailyAverage > 0 {
                        RuleMark(y: .value("Avg", viewModel.dailyAverage))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .annotation(
                                position: .top,
                                alignment: .trailing,
                                spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                Text("Ø \(formatCurrency(viewModel.dailyAverage))")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                    }

                    if let selectedDate, let day = selectedDay {
                        RuleMark(x: .value("Selected", day.date, unit: .day))
                            .foregroundStyle(.gray.opacity(0.35))
                            .annotation(
                                position: .top,
                                alignment: .center,
                                spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                tooltipView(for: day)
                            }
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        AxisGridLine()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        if let revenue = value.as(Double.self) {
                            AxisValueLabel {
                                Text(formatCurrencyCompact(revenue))
                            }
                        }
                        AxisGridLine()
                    }
                }
                .frame(height: 200)
                .animation(.smooth, value: selectedDate)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                    .frame(height: 200)
                    .overlay {
                        Text("No sales data")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            // Terminal empty state ONLY when history is exhausted — an empty
            // window with hasMoreActivity still true must render the sentinel
            // below, otherwise older history would be permanently unreachable
            // (the old "Load more" button rendered even when today was empty).
            if viewModel.recentActivity.isEmpty && !viewModel.isLoading && !viewModel.hasMoreActivity {
                Text("No recent activity")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                let grouped = groupFeedItemsByDay(viewModel.recentActivity)
                // LazyVStack: only the rows visible in the ScrollView's viewport are
                // instantiated. Without it, large windows (e.g. 21+ days) render
                // hundreds of rows eagerly, each spawning an AsyncImage
                // HTTP request — iOS kills the app under memory pressure.
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(grouped, id: \.date) { group in
                        DaySectionHeader(
                            label: dayLabel(for: group.date),
                            count: group.items.count,
                            unit: String(localized: "entries"),
                            revenue: group.salesRevenue
                        )
                        ForEach(group.items) { item in
                            feedRow(for: item)
                        }
                    }

                    // Infinite-scroll sentinel: when it becomes visible the next
                    // window loads. Hidden during full dashboard loads so the
                    // initial load and a window expansion never run concurrently
                    // (loadDashboard doesn't set isLoadingMoreActivity, so the
                    // loadMore guard alone wouldn't cover that race) — and each
                    // completed dashboard load re-inserts the sentinel, whose
                    // fresh .task fires on appearance (auto-fill on short feeds).
                    // Keyed on the RAW row count so a completed expansion re-arms
                    // it while it is still on screen, even if all new rows merged
                    // into an existing boundary intake group.
                    if viewModel.hasMoreActivity && !viewModel.isLoading {
                        if viewModel.loadMoreFailed {
                            // After a real load-more error nothing would re-fire the
                            // sentinel's task — offer a manual retry like the old button.
                            Button {
                                Task { await viewModel.loadMoreRecentActivity() }
                            } label: {
                                Label(String(localized: "Retry"), systemImage: "arrow.clockwise")
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        } else {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .task(id: viewModel.rawSourceRowCount) {
                                await viewModel.loadMoreRecentActivity()
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    @ViewBuilder
    private func feedRow(for item: ActivityFeedItem) -> some View {
        switch item {
        case .sale(let saleItem):
            RecentSaleRow(item: saleItem) {
                guard let pid = saleItem.sale.productId else { return }
                selectedProduct = ProductSelection(
                    id: pid,
                    name: saleItem.productName ?? String(localized: "Item #\(saleItem.sale.itemNumber ?? 0)"),
                    imagePath: saleItem.productImagePath,
                    sellprice: saleItem.sale.itemPrice
                )
            }

        case .machineRefilled(let refill):
            ActivityEventRow(
                icon: "shippingbox.fill",
                tint: .green,
                title: refill.machineName,
                subtitle: refillSubtitle(refill),
                date: refill.createdAt,
                detailLines: refill.products.map { "\($0.quantity)× \($0.name)" },
                isExpanded: expandedActivityIds.contains(item.id),
                onToggle: { toggleExpanded(item.id) }
            )

        case .tourStarted(let tour):
            ActivityEventRow(
                icon: "figure.walk",
                tint: .indigo,
                title: String(localized: "Tour started"),
                subtitle: tourSubtitle(tour),
                date: tour.createdAt,
                detailLines: tour.machineNames,
                isExpanded: expandedActivityIds.contains(item.id),
                onToggle: { toggleExpanded(item.id) }
            )

        case .stockIntake(let intake):
            ActivityEventRow(
                icon: "tray.and.arrow.down.fill",
                tint: .orange,
                title: String(localized: "Stock intake"),
                subtitle: intakeSubtitle(intake),
                date: intake.date,
                detailLines: intake.products.map { "\($0.quantity)× \($0.name)" },
                isExpanded: expandedActivityIds.contains(item.id),
                onToggle: { toggleExpanded(item.id) }
            )

        case .slotsRebuilt(let change):
            ActivityEventRow(
                icon: "arrow.triangle.swap",
                tint: Color.rebuildViolet,
                title: String(localized: "Slots rebuilt"),
                subtitle: slotChangeSubtitle(change),
                date: change.createdAt,
                detailLines: change.slots.map(slotChangeLine),
                isExpanded: expandedActivityIds.contains(item.id),
                onToggle: { toggleExpanded(item.id) }
            )

        case .cashBookEntry(let cash):
            ActivityEventRow(
                icon: cashBookIcon(cash.type),
                tint: cashBookTint(cash.type),
                title: cashBookTitle(cash.type),
                subtitle: cashBookSubtitle(cash),
                date: cash.createdAt,
                detailLines: (cash.note?.isEmpty == false) ? [cash.note!] : [],
                isExpanded: expandedActivityIds.contains(item.id),
                onToggle: { toggleExpanded(item.id) }
            )
        }
    }

    private func toggleExpanded(_ id: String) {
        if expandedActivityIds.contains(id) {
            expandedActivityIds.remove(id)
        } else {
            expandedActivityIds.insert(id)
        }
    }

    private func refillSubtitle(_ refill: RefillActivity) -> String {
        var parts: [String] = []
        if let user = refill.userDisplay {
            parts.append(String(localized: "Filled by \(user)"))
        }
        parts.append(String(localized: "\(refill.totalAdded) items"))
        return parts.joined(separator: " · ")
    }

    private func slotChangeSubtitle(_ change: SlotChangeActivity) -> String {
        var parts: [String] = [change.machineName]
        if let user = change.userDisplay { parts.append(user) }
        if change.skippedCount > 0 {
            parts.append(String(localized: "\(change.skippedCount) not rebuilt"))
        }
        return parts.joined(separator: " · ")
    }

    /// "#12 · Cola · +8" — the product name is left out when it can't be resolved.
    private func slotChangeLine(_ slot: SlotChangeActivity.Slot) -> String {
        var parts = ["#\(slot.itemNumber)"]
        if let name = slot.productName { parts.append(name) }
        parts.append("+\(slot.filled)")
        return parts.joined(separator: " · ")
    }

    private func tourSubtitle(_ tour: TourActivity) -> String {
        var parts: [String] = []
        if let user = tour.userDisplay { parts.append(user) }
        parts.append(String(localized: "\(tour.machineCount) machines"))
        if let wh = tour.warehouseName { parts.append(wh) }
        return parts.joined(separator: " · ")
    }

    private func intakeSubtitle(_ intake: IntakeGroup) -> String {
        var parts: [String] = []
        if let user = intake.userDisplay { parts.append(user) }
        parts.append(String(localized: "\(intake.productCount) products"))
        if let wh = intake.warehouseName { parts.append(wh) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Cash book (Barkasse) feed row
    // Reuse the entry-type labels + colours from the cash-book screen
    // (EntriesListSection.badgeStyle) so the feed stays consistent with it.

    private func cashBookSubtitle(_ cash: CashBookActivity) -> String {
        var parts: [String] = []
        if let user = cash.userDisplay { parts.append(user) }
        parts.append(NumberFormatter.localizedString(from: cash.amount as NSNumber, number: .currency))
        if let cat = cash.category, !cat.isEmpty {
            let key: String = "cash_book_category_\(cat)"
            parts.append(String(localized: String.LocalizationValue(key)))
        }
        return parts.joined(separator: " · ")
    }

    private func cashBookTitle(_ type: CashBookEntryType) -> String {
        switch type {
        case .initial:    return String(localized: "cash_book_type_initial")
        case .withdrawal: return String(localized: "cash_book_type_withdrawal")
        case .correction: return String(localized: "cash_book_type_correction")
        case .payout:     return String(localized: "cash_book_type_payout")
        case .expense:    return String(localized: "cash_book_type_expense")
        case .reversal:   return String(localized: "cash_book_type_reversal")
        case .unknown:    return String(localized: "cash_book_type_unknown")
        }
    }

    private func cashBookTint(_ type: CashBookEntryType) -> Color {
        switch type {
        case .initial:    return .gray
        case .withdrawal: return .red
        case .correction: return .yellow
        case .payout:     return .blue
        case .expense:    return .orange
        case .reversal:   return .orange
        case .unknown:    return .gray
        }
    }

    private func cashBookIcon(_ type: CashBookEntryType) -> String {
        switch type {
        case .initial:    return "flag.fill"
        case .withdrawal: return "building.columns.fill"
        case .correction: return "slider.horizontal.3"
        case .payout:     return "arrow.up.circle.fill"
        case .expense:    return "cart.fill"
        case .reversal:   return "arrow.uturn.backward.circle.fill"
        case .unknown:    return "eurosign.circle.fill"
        }
    }

    // MARK: - Helpers

    private var selectedDay: DailySales? {
        guard let selectedDate else { return nil }
        return viewModel.dailySales.first {
            Calendar.current.isDate($0.date, inSameDayAs: selectedDate)
        }
    }

    @ViewBuilder
    private func tooltipView(for day: DailySales) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formatTooltipDate(day.date))
                .font(.caption.weight(.semibold))
            HStack(spacing: 12) {
                Text("Revenue")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatCurrency(day.revenue))
                    .monospacedDigit()
            }
            .font(.caption2)
            HStack(spacing: 12) {
                Text("Sales")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(day.count)")
                    .monospacedDigit()
            }
            .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .frame(minWidth: 140)
    }

    private func formatTooltipDate(_ date: Date) -> String {
        // Date.FormatStyle is locale-aware out of the box.
        // - en: "Wed, 15 Apr"
        // - de: "Mi., 15. Apr."
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func formatCurrency(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private func formatCurrencyCompact(_ amount: Double) -> String {
        if amount >= 1000 {
            return String(format: "%.0fk", amount / 1000)
        }
        return String(format: "%.0f", amount)
    }

    // MARK: - Day Grouping Helpers

    private struct FeedDayGroup {
        let date: Date
        let items: [ActivityFeedItem]

        /// Summed revenue of the day's sales; nil when the day has no sales.
        var salesRevenue: Double? {
            let prices = items.compactMap { item -> Double? in
                if case .sale(let s) = item { return s.sale.itemPrice ?? 0 }
                return nil
            }
            return prices.isEmpty ? nil : prices.reduce(0, +)
        }
    }

    private func groupFeedItemsByDay(_ items: [ActivityFeedItem]) -> [FeedDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.date)
        }
        return grouped.keys.sorted(by: >).map { date in
            FeedDayGroup(date: date, items: grouped[date]!.sorted { $0.date > $1.date })
        }
    }

    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: date)
    }
}

// MARK: - Recent Sale Row

struct RecentSaleRow: View {
    let item: SaleWithMachine
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: item.productImagePath, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.productName ?? String(localized: "Item #\(item.sale.itemNumber ?? 0)"))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let machineName = item.machineName {
                    Text(machineName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.sale.formattedPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(formatTime(item.sale.createdAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Activity Event Row

/// Non-sale feed row: tinted icon circle, title, subtitle, time — visually in
/// rhythm with RecentSaleRow. Tapping toggles an inline detail list (products
/// or machine names); rows without details don't react.
struct ActivityEventRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let date: Date
    let detailLines: [String]
    let isExpanded: Bool
    var onToggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTime(date))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !detailLines.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
            }

            if isExpanded && !detailLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(detailLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 48)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !detailLines.isEmpty else { return }
            withAnimation(.snappy(duration: 0.2)) { onToggle() }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Profile Name Sheet

/// Renames the signed-in user. The name is what shows up as the author of
/// refill tours, cash-book entries and other activity-log rows, so this is the
/// one place to correct it without going through the web app.
struct ProfileNameSheet: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var isSaving = false
    @State private var saveError: String?

    private var canSave: Bool {
        !(firstName.trimmingCharacters(in: .whitespaces).isEmpty
          && lastName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "First Name"), text: $firstName)
                        .textContentType(.givenName)
                    TextField(String(localized: "Last Name"), text: $lastName)
                        .textContentType(.familyName)
                } footer: {
                    Text("This name identifies you in refill tours, cash book entries and the activity log.")
                }

                if let email = auth.userEmail {
                    Section {
                        HStack {
                            Text("Email")
                            Spacer()
                            Text(email).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Change Name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            let failure = await auth.updateProfileName(
                                firstName: firstName, lastName: lastName)
                            isSaving = false
                            if let failure {
                                saveError = failure
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .task {
                await auth.loadProfile()
                firstName = auth.firstName
                lastName = auth.lastName
            }
            .alert(
                String(localized: "Error"),
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button(String(localized: "OK")) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }
}

// MARK: - Time Ago Helper

func timeAgo(from date: Date) -> String {
    let interval = Date().timeIntervalSince(date)

    if interval < 60 { return String(localized: "Just now") }
    if interval < 3600 { return String(localized: "\(Int(interval / 60))m ago") }
    if interval < 86400 { return String(localized: "\(Int(interval / 3600))h ago") }
    if interval < 604800 { return String(localized: "\(Int(interval / 86400))d ago") }

    let formatter = DateFormatter()
    formatter.dateStyle = .short
    return formatter.string(from: date)
}

#Preview {
    NavigationStack {
        DashboardView()
            .environmentObject(AuthService())
    }
}
