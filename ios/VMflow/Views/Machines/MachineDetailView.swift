import SwiftUI
import Charts

/// Tabbed machine detail view: Overview (with trays), Sales.
struct MachineDetailView: View {
    let machine: VendingMachine
    let initialStats: MachineStats

    @StateObject private var viewModel: MachineDetailViewModel
    @StateObject private var trayVM: TrayViewModel
    @State private var selectedTab = 0
    @State private var showAddSheet = false
    @State private var showBatchSheet = false
    @State private var editingTray: Tray?
    @State private var selectedProduct: ProductSelection?
    @State private var rowToRestore: SuppressedSale?
    @State private var showMachineSettings = false
    @State private var showDeviceHealth = false
    @State private var showSendCredit = false
    @EnvironmentObject private var realtime: RealtimeService
    @EnvironmentObject private var auth: AuthService

    struct ProductSelection: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
    }

    private var realtimeVersion: Int {
        realtime.salesVersion + realtime.traysVersion
    }

    init(machine: VendingMachine, initialStats: MachineStats) {
        self.machine = machine
        self.initialStats = initialStats
        _viewModel = StateObject(wrappedValue: MachineDetailViewModel(machine: machine, stats: initialStats))
        _trayVM = StateObject(wrappedValue: TrayViewModel(machineId: machine.id))
    }

    /// Use the trayVM's trays if loaded, otherwise fall back to viewModel's trays.
    private var displayTrays: [Tray] {
        trayVM.trays.isEmpty ? viewModel.trays : trayVM.trays
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab Picker
            Picker("Section", selection: $selectedTab) {
                Text("Overview").tag(0)
                Text("Sales").tag(1)
                Text("Statistics").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Tab Content
            TabView(selection: $selectedTab) {
                overviewTab.tag(0)
                salesTab.tag(1)
                MachineAnalysisView(detailViewModel: viewModel, trayViewModel: trayVM).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle(machine.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSendCredit = true
                } label: {
                    Image(systemName: "eurosign.circle")
                }
                .accessibilityLabel(String(localized: "Send Credit"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDeviceHealth = true
                } label: {
                    Image(systemName: "waveform.path.ecg.rectangle")
                }
                .accessibilityLabel(String(localized: "Device Health"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMachineSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(String(localized: "Machine Settings"))
            }
        }
        .sheet(isPresented: $showMachineSettings) {
            MachineSettingsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showDeviceHealth) {
            DeviceHealthSheet(detailViewModel: viewModel)
        }
        .sheet(isPresented: $showSendCredit) {
            SendCreditSheet(viewModel: viewModel)
        }
        .task {
            await viewModel.loadDetail()
            await trayVM.loadTrays()
        }
        .onChange(of: realtimeVersion) { _, _ in
            Task {
                await viewModel.loadDetail()
                await trayVM.loadTrays()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            TrayEditSheet(
                machineId: machine.id,
                tray: nil,
                products: viewModel.products,
                onSave: { slot, productId, capacity, stock, minStock, fillBelow in
                    await trayVM.addTray(
                        itemNumber: slot,
                        productId: productId,
                        capacity: capacity,
                        currentStock: stock,
                        minStock: minStock,
                        fillWhenBelow: fillBelow
                    )
                }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showBatchSheet) {
            BatchAddTraySheet(machineId: machine.id) { start, count, capacity in
                await trayVM.batchAddTrays(startSlot: start, count: count, capacity: capacity)
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editingTray) { tray in
            TrayEditSheet(
                machineId: machine.id,
                tray: tray,
                products: viewModel.products,
                onSave: { slot, productId, capacity, stock, minStock, fillBelow in
                    await trayVM.updateTray(
                        id: tray.id,
                        itemNumber: slot,
                        productId: productId,
                        capacity: capacity,
                        currentStock: stock,
                        minStock: minStock,
                        fillWhenBelow: fillBelow
                    )
                },
                onDelete: {
                    await trayVM.deleteTray(tray)
                }
            )
            .presentationDetents([.large])
        }
        .sheet(item: $selectedProduct) { sel in
            ProductDetailSheet(
                productId: sel.id,
                fallbackName: sel.name,
                fallbackImagePath: sel.imagePath,
                fallbackSellprice: sel.sellprice
            )
        }
        .alert("Error", isPresented: .init(
            get: { trayVM.error != nil },
            set: { if !$0 { trayVM.error = nil } }
        )) {
            Button("OK") { trayVM.error = nil }
        } message: {
            Text(trayVM.error ?? "")
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Status & Info
                VStack(spacing: 12) {
                    HStack(alignment: .top) {
                        ConnectivityStatusView(machine: viewModel.machine)
                        Spacer()
                        if let firmware = machine.embeddeds?.firmwareVersion {
                            Text("v\(firmware)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.fill.tertiary))
                        }
                    }

                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ConnectivityNotice(connectivity: viewModel.machine.connectivity(now: context.date))
                    }

                    if let mac = machine.embeddeds?.macAddress {
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                            Text(mac)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))

                // Revenue KPIs
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                    KPICard(
                        icon: "eurosign.circle.fill",
                        title: "Today",
                        value: formatEUR(viewModel.stats.todayRevenue),
                        color: .blue
                    )
                    KPICard(
                        icon: "cart.fill",
                        title: "Sales Today",
                        value: "\(viewModel.stats.todaySalesCount)",
                        color: .green
                    )
                    KPICard(
                        icon: "clock.fill",
                        title: "Yesterday",
                        value: formatEUR(viewModel.stats.yesterdayRevenue),
                        color: .orange
                    )
                    KPICard(
                        icon: "cube.box.fill",
                        title: "Stock",
                        value: viewModel.stockSummary,
                        color: viewModel.stats.stockHealth == .critical ? .red :
                               viewModel.stats.stockHealth == .low ? .yellow :
                               viewModel.stats.stockHealth == .fill ? .blue : .green
                    )
                }

                // Paxcounter
                if let pax = viewModel.stats.paxcounterCount {
                    HStack {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.teal)
                        Text("Foot Traffic")
                            .font(.subheadline)
                        Spacer()
                        Text("\(pax)")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                }

                // Trays Section
                VStack(spacing: 0) {
                    // Tray Header
                    HStack {
                        Text("\(displayTrays.count) Trays")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Menu {
                            Button {
                                showAddSheet = true
                            } label: {
                                Label("Add Single Tray", systemImage: "plus")
                            }
                            Button {
                                showBatchSheet = true
                            } label: {
                                Label("Batch Add Trays", systemImage: "plus.rectangle.on.rectangle")
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                    }
                    .padding(.vertical, 8)

                    // Tray Rows
                    if displayTrays.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No trays configured")
                                .foregroundStyle(.secondary)
                            Button("Add Trays") {
                                showBatchSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                    } else {
                        TrayStockSection(
                            trays: displayTrays,
                            onAdjust: { tray, delta in
                                HapticFeedback.light.fire()
                                Task {
                                    await trayVM.adjustStock(tray: tray, delta: delta)
                                }
                            },
                            onFill: { tray in
                                HapticFeedback.medium.fire()
                                Task {
                                    await trayVM.fillToCapacity(tray)
                                }
                            },
                            onEdit: { tray in
                                editingTray = tray
                            },
                            linkedSelections: viewModel.machine.linkedSelections
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .dataRefreshable {
            await viewModel.loadDetail()
            await trayVM.loadTrays()
        }
    }

    // MARK: - Sales Tab

    private var salesTab: some View {
        Group {
            if viewModel.recentSales.isEmpty && !viewModel.isLoading {
                ScrollView {
                    VStack(spacing: 12) {
                        Image(systemName: "cart")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No sales yet")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                }
            } else {
                List {
                    let grouped = groupFeedByDay(salesFeedItems)
                    ForEach(grouped, id: \.date) { group in
                        Section {
                            ForEach(group.items) { item in
                                switch item {
                                case .sale(let sale):
                                    SaleRow(sale: sale, trays: viewModel.trays) {
                                        presentProductSheet(for: sale)
                                    }
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                case .suppressed(let s):
                                    SuppressedSaleListRow(sale: s, trays: viewModel.trays)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        // Long press instead of swipe: the paging TabView's
                                        // horizontal pan swallows trailing swipe actions.
                                        .contextMenu {
                                            if isAdmin {
                                                Button {
                                                    rowToRestore = s
                                                } label: {
                                                    Label("Take up as sale", systemImage: "checkmark.circle")
                                                }
                                            }
                                        }
                                        .restoreSaleDialog(for: s, selection: $rowToRestore) { sale in
                                            Task { await viewModel.restoreSuppressed(sale.id) }
                                        }
                                }
                            }
                        } header: {
                            DaySectionHeader(label: dayLabel(for: group.date), count: group.saleCount)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .dataRefreshable {
            await viewModel.loadDetail()
            await trayVM.loadTrays()
        }
    }

    private func formatEUR(_ amount: Double) -> String {
        String(format: "%.2f\u{00A0}\u{20AC}", amount)
    }

    /// Resolve a sale's product (snapshotted FK or tray fallback) and present the
    /// product detail sheet. No-op when no product can be determined.
    private func presentProductSheet(for sale: Sale) {
        let trayMatch = sale.itemNumber.flatMap { num in
            viewModel.trays.first { $0.itemNumber == num }
        }
        let productId = sale.productId ?? trayMatch?.productId
        guard let pid = productId else { return }
        let name = sale.products?.name ?? trayMatch?.productName ?? "Item #\(sale.itemNumber ?? 0)"
        let imagePath = sale.products?.imagePath ?? trayMatch?.products?.imagePath
        selectedProduct = ProductSelection(
            id: pid,
            name: name,
            imagePath: imagePath,
            sellprice: sale.itemPrice
        )
    }

    // MARK: - Day Grouping Helpers

    private struct DayGroup {
        let date: Date
        let sales: [Sale]
    }

    private func groupSalesByDay(_ sales: [Sale]) -> [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sales) { sale in
            calendar.startOfDay(for: sale.createdAt)
        }
        return grouped.keys.sorted(by: >).map { date in
            DayGroup(date: date, sales: grouped[date]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    private enum SalesFeedItem: Identifiable {
        case sale(Sale)
        case suppressed(SuppressedSale)
        var id: String {
            switch self {
            case .sale(let s): return "sale-\(s.id)"
            case .suppressed(let s): return "sup-\(s.id)"
            }
        }
        var date: Date {
            switch self {
            case .sale(let s): return s.createdAt
            case .suppressed(let s): return s.receivedAt
            }
        }
    }

    private struct FeedDayGroup { let date: Date; let items: [SalesFeedItem]; let saleCount: Int }

    private func groupFeedByDay(_ items: [SalesFeedItem]) -> [FeedDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { date in
            let dayItems = grouped[date]!.sorted { $0.date > $1.date }
            let saleCount = dayItems.reduce(0) { acc, it in
                if case .sale = it { return acc + 1 } else { return acc }
            }
            return FeedDayGroup(date: date, items: dayItems, saleCount: saleCount)
        }
    }

    /// Real sales + suppressed rows (only those at/after the oldest visible sale,
    /// so a suppressed-only day can't dangle below the last loaded sale).
    private var salesFeedItems: [SalesFeedItem] {
        var items = viewModel.recentSales.map { SalesFeedItem.sale($0) }
        if let cutoff = viewModel.recentSales.map({ $0.createdAt }).min() {
            items += viewModel.suppressedSales
                .filter { $0.receivedAt >= cutoff }
                .map { SalesFeedItem.suppressed($0) }
        }
        return items
    }

    private var isAdmin: Bool { auth.role == .admin }

    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: date)
    }
}

// MARK: - Sale Row (Card Style)

struct SaleRow: View {
    let sale: Sale
    let trays: [Tray]
    var onTap: () -> Void = {}

    /// Find the product for this sale via tray item number (fallback for old sales without product_id).
    private var tray: Tray? {
        guard let itemNumber = sale.itemNumber else { return nil }
        return trays.first { $0.itemNumber == itemNumber }
    }

    /// Prefer snapshotted product from FK join, fallback to tray lookup for old sales.
    private var productName: String {
        sale.products?.name ?? tray?.productName ?? "Item #\(sale.itemNumber ?? 0)"
    }

    private var productImagePath: String? {
        sale.products?.imagePath ?? tray?.products?.imagePath
    }

    private var channelColor: Color {
        switch sale.channel?.lowercased() {
        case "card": return .blue
        case "cashless", "nfc": return .purple
        case "cash": return .green
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: productImagePath, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(productName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let channel = sale.channel {
                        Text(channel.capitalized)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(channelColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(channelColor.opacity(0.12), in: Capsule())
                    }
                    if sale.itemNumber != nil {
                        Text("Slot \(sale.itemNumber!)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(sale.formattedPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(formatTime(sale.createdAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap() }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Suppressed Sale Row (read-only)

struct SuppressedSaleRow: View {
    let sale: SuppressedSale
    let trays: [Tray]

    /// Prefer snapshot product name; fall back to current tray by item number; last resort "Slot N".
    private var productName: String {
        sale.products?.name
            ?? trays.first { $0.itemNumber == sale.itemNumber }?.productName
            ?? "Slot \(sale.itemNumber ?? 0)"
    }

    private var productImagePath: String? {
        sale.products?.imagePath
            ?? trays.first { $0.itemNumber == sale.itemNumber }?.products?.imagePath
    }

    private var channelColor: Color {
        switch sale.channel?.lowercased() {
        case "card": return .blue
        case "cashless", "nfc": return .purple
        case "cash": return .green
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: productImagePath, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(productName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let channel = sale.channel {
                        Text(channel.capitalized)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(channelColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(channelColor.opacity(0.12), in: Capsule())
                    }
                    if let slot = sale.itemNumber {
                        Text("Slot \(slot)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(sale.reasonText)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(sale.formattedPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(formatTime(sale.receivedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Suppressed Sale Row (Sales-list variant: marked, non-counting)

struct SuppressedSaleListRow: View {
    let sale: SuppressedSale
    let trays: [Tray]

    private var productName: String {
        sale.products?.name
            ?? trays.first { $0.itemNumber == sale.itemNumber }?.productName
            ?? "Slot \(sale.itemNumber ?? 0)"
    }
    private var productImagePath: String? {
        sale.products?.imagePath
            ?? trays.first { $0.itemNumber == sale.itemNumber }?.products?.imagePath
    }

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: productImagePath, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(productName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Text("Auto-removed")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
                Text(sale.reasonText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(sale.formattedPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .strikethrough(true, color: .secondary)
                    .foregroundStyle(.secondary)
                Text(formatTime(sale.receivedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background { RoundedRectangle(cornerRadius: 12).fill(.regularMaterial) }
        .opacity(0.7)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Day Section Header

struct DaySectionHeader: View {
    let label: String
    let count: Int
    var unit: String = String(localized: "sales")
    /// Summed sales revenue (EUR) shown after the count; nil hides it.
    var revenue: Double? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text("· \(count) \(unit)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let revenue {
                Text("· \(revenue, format: .currency(code: "EUR"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.bar)
    }
}

// MARK: - Restore Confirmation Dialog

// Not `private` — `DeviceHealthSheet.swift` reuses this for its own
// auto-removed-duplicates list (the old "Duplicates" tab's content, moved
// there).
extension View {
    /// Per-row "take up as sale" confirmation. Attached to the pressed row (not a
    /// shared ancestor) so the iPad popover anchors at the item instead of the
    /// top edge of the list.
    func restoreSaleDialog(
        for sale: SuppressedSale,
        selection: Binding<SuppressedSale?>,
        onConfirm: @escaping (SuppressedSale) -> Void
    ) -> some View {
        confirmationDialog(
            "Take up as real sale?",
            isPresented: Binding(
                get: { selection.wrappedValue?.id == sale.id },
                set: { presented in
                    if !presented && selection.wrappedValue?.id == sale.id {
                        selection.wrappedValue = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Take up as sale") { onConfirm(sale) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adds a real sale and reduces stock by 1.")
        }
    }
}

// MARK: - Send Credit Sheet

/// Sends free credit to the machine's device, same effect as inserting a
/// coin/card payment. No sale is recorded here — the device reports the vend
/// itself over MQTT when it happens. Open to any authenticated member, not
/// just admins: the `send-credit` edge function itself doesn't require an
/// admin role for JWT auth, so the UI matches that.
private struct SendCreditSheet: View {
    @ObservedObject var viewModel: MachineDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var isSending = false
    @State private var sendError: String?

    private var amount: Double? {
        let normalized = amountText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(String(localized: "Amount"))
                        Spacer()
                        TextField("0,00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                        Text("€").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Credits the machine as if a coin or card payment had been made. No sale is recorded until the machine reports a vend.")
                }
                if let sendError {
                    Section { Text(sendError).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(String(localized: "Send Credit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Send")) {
                        Task { await send() }
                    }
                    .disabled(amount == nil || isSending)
                }
            }
            .disabled(isSending)
            .overlay {
                if isSending { ProgressView() }
            }
        }
    }

    private func send() async {
        guard let amount else { return }
        isSending = true
        defer { isSending = false }
        let ok = await viewModel.sendCredit(amount: amount)
        if ok {
            dismiss()
        } else {
            sendError = viewModel.error ?? String(localized: "Failed to send credit.")
        }
    }
}

#Preview {
    let machine = VendingMachine(
        id: UUID(),
        name: "Test Machine",
        locationLat: nil,
        locationLon: nil,
        embedded: nil,
        countryCode: "DE",
        embeddeds: Embedded(
            id: UUID(),
            status: "online",
            statusAt: Date(),
            subdomain: 1,
            macAddress: "AA:BB:CC:DD:EE:FF",
            firmwareVersion: "1.2.3"
        )
    )
    let stats = MachineStats(machine: machine)

    NavigationStack {
        MachineDetailView(machine: machine, initialStats: stats)
            .environmentObject(AuthService())
            .environmentObject(RealtimeService.shared)
    }
}
