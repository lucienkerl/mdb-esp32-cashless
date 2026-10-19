import SwiftUI
import UIKit

/// Warehouse › Order: what to order per supplier so the stock lasts until the
/// delivery after next (`OrderSuggestion`), with manual entries, a carton
/// stepper, copying the list and "Mark as ordered", plus the orders on the
/// way. Mirrors the web's `WarehouseOrderTab.vue`.
struct WarehouseOrderView: View {
    @ObservedObject var viewModel: WarehouseViewModel
    let isAdmin: Bool
    /// Tapping a line's product image opens the product detail, like in Stock.
    var onShowProductDetail: (OrderProductInput) -> Void = { _ in }
    /// Opens Incoming (where deliveries are booked).
    var onCheckDelivery: () -> Void = {}

    @State private var cancelCandidate: PurchaseOrder?
    /// Line tapped: its batches view with the order section (supplier, carton size).
    @State private var openedProduct: OrderProductRoute?
    /// "Add" tapped: the products the picker sheet offers (all, or one supplier's).
    @State private var addPicker: AddPickerContext?

    var body: some View {
        let groups = viewModel.orderGroups
        List {
            Section {
                Text(introText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    OrderBadge(kind: .auto)
                    OrderBadge(kind: .manual)
                }
                .listRowSeparator(.hidden)
                if !addableProducts.isEmpty {
                    Button {
                        addPicker = AddPickerContext(title: nil, products: addableProducts)
                    } label: {
                        Label(String(localized: "Add to order list"), systemImage: "cart.badge.plus")
                    }
                }
            }

            if OrderSuggestion.lineCount(groups) == 0 {
                Section {
                    Label(String(localized: "Everything lasts until the delivery after next. Nothing to order."),
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(groups) { group in
                groupSection(group)
            }

            if !viewModel.openOrders.isEmpty {
                Section {
                    ForEach(viewModel.openOrders) { order in
                        openOrderRow(order)
                    }
                } header: {
                    Text(String(localized: "On the way"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(item: $openedProduct) { p in
            ProductBatchesView(
                productId: p.id,
                productName: p.name,
                productImagePath: p.imagePath,
                isAdmin: isAdmin
            )
            .environmentObject(viewModel)
        }
        .sheet(item: $addPicker) { ctx in
            AddToOrderListSheet(title: ctx.title, products: ctx.products) { productId in
                Task { await viewModel.addToOrderList(productId) }
            }
        }
        .alert(
            String(localized: "Cancel order"),
            isPresented: .init(get: { cancelCandidate != nil }, set: { if !$0 { cancelCandidate = nil } }),
            presenting: cancelCandidate
        ) { order in
            Button(String(localized: "Cancel order"), role: .destructive) {
                Task { await viewModel.cancelOrder(order) }
            }
            Button(String(localized: "Keep"), role: .cancel) {}
        } message: { order in
            Text(String(localized: "Cancel the order with \(order.supplierName ?? "—")? Its goods no longer count as on the way."))
        }
    }

    private var introText: String {
        let buffer = viewModel.orderSettings.bufferDays
        return viewModel.orderSettings.countMachineStock
            ? String(localized: "Suggestion for the next order cycle: lasts until the delivery after next plus a \(buffer)-day buffer. Machine stock and goods already on order are subtracted.")
            : String(localized: "Suggestion for the next order cycle: lasts until the delivery after next plus a \(buffer)-day buffer. Goods already on order are subtracted.")
    }

    // MARK: - Supplier group

    @ViewBuilder
    private func groupSection(_ group: OrderGroup) -> some View {
        Section {
            if group.lines.isEmpty {
                Text(String(localized: "Nothing due"))
                    .foregroundStyle(.secondary)
            }
            ForEach(group.lines) { line in
                OrderLineRow(
                    line: line,
                    showsSupplierPicker: group.supplier == nil && isAdmin,
                    suppliers: viewModel.orderSuppliers,
                    onOpen: {
                        openedProduct = OrderProductRoute(
                            id: line.product.productId,
                            name: line.product.productName,
                            imagePath: line.product.imagePath
                        )
                    },
                    onImageTap: { onShowProductDetail(line.product) },
                    onCartons: { viewModel.setCartons(line.product.productId, $0) },
                    onReset: { viewModel.resetCartons(line.product.productId) },
                    onAssign: { supplierId in Task { await viewModel.assignSupplier(line.product.productId, supplierId: supplierId) } }
                )
                .swipeActions(edge: .trailing) {
                    if line.manual != nil {
                        Button(String(localized: "Remove"), systemImage: "minus.circle") {
                            Task { await viewModel.removeFromOrderList(line.product.productId) }
                        }
                        .tint(.red)
                    }
                }
                .contextMenu {
                    if line.manual != nil {
                        Button(String(localized: "Remove from order list"), systemImage: "cart.badge.minus", role: .destructive) {
                            Task { await viewModel.removeFromOrderList(line.product.productId) }
                        }
                    }
                    if line.overridden {
                        Button(String(localized: "Reset quantity"), systemImage: "arrow.counterclockwise") {
                            viewModel.resetCartons(line.product.productId)
                        }
                    }
                }
            }

            if !group.others.isEmpty {
                Button {
                    addPicker = AddPickerContext(title: group.supplier?.name, products: group.others)
                } label: {
                    Label(String(localized: "Add product"), systemImage: "plus")
                }
            }

            if !group.lines.isEmpty {
                groupActions(group)
            }
        } header: {
            groupHeader(group)
        } footer: {
            groupFooter(group)
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: OrderGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(group.supplier?.name ?? String(localized: "No supplier"))
                if !group.lines.isEmpty {
                    Text(verbatim: "· \(String(localized: "\(group.lines.count) items"))")
                }
            }
            if let s = group.supplier {
                Text(String(localized: "Lead time \(OrderSuggestion.leadDays(s, viewModel.orderSettings)) days · ordered every \(OrderSuggestion.intervalDays(s, viewModel.orderSettings)) days"))
                    .textCase(nil)
                    .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func groupFooter(_ group: OrderGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if group.supplier == nil {
                Text(isAdmin
                     ? String(localized: "Assign a supplier right in the row and the product moves into that supplier's order.")
                     : String(localized: "An admin can assign a supplier to these products."))
            }
            if group.hasEmpty {
                Label(String(localized: "Contains empty products"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if group.belowMinOrder, let min = group.supplier?.minOrderValue {
                Label(String(localized: "Minimum order value \(min.formatted(.currency(code: "EUR"))) not reached yet"),
                      systemImage: "info.circle")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func groupActions(_ group: OrderGroup) -> some View {
        let text = OrderSuggestion.orderText(
            group,
            customerNumberLabel: String(localized: "Customer no."),
            carton: { n, size in "\(n) × \(size)" }
        )
        let hasCartons = group.lines.contains { $0.cartons > 0 }
        VStack(alignment: .leading, spacing: 10) {
            if group.value > 0 {
                HStack {
                    Text(String(localized: "Net cost"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(group.value.formatted(.currency(code: "EUR")))
                        .font(.body.monospacedDigit().weight(.semibold))
                }
            }
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = text
                    viewModel.notice = String(localized: "Copied")
                } label: {
                    Label(String(localized: "Copy list"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(!hasCartons)

                ShareLink(item: text) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(!hasCartons)

                Spacer()

                if isAdmin, group.supplier != nil {
                    Button {
                        Task { await viewModel.placeOrder(group) }
                    } label: {
                        if viewModel.busySupplierId == group.supplier?.id {
                            ProgressView()
                        } else {
                            Text(String(localized: "Mark as ordered"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasCartons || viewModel.busySupplierId != nil)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Every product not on the order list yet, whatever its supplier (the
    /// per-supplier "Add product" menu misses products without one).
    private var addableProducts: [OrderProductInput] {
        let listed = viewModel.orderListProductIds
        return viewModel.orderInputs
            .filter { !$0.discontinued && !listed.contains($0.productId) }
            .sorted { $0.productName.localizedCaseInsensitiveCompare($1.productName) == .orderedAscending }
    }

    // MARK: - On the way

    @ViewBuilder
    private func openOrderRow(_ order: PurchaseOrder) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.supplierName ?? "—")
                    .font(.body.weight(.medium))
                Text(String(localized: "ordered \(order.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(order.lines.count) items · \(order.totalUnits) units"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let name = order.orderedByName, !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(String(localized: "Check delivery"), action: onCheckDelivery)
                .buttonStyle(.bordered)
                .font(.caption)
        }
        .swipeActions(edge: .trailing) {
            if isAdmin {
                Button(String(localized: "Cancel order"), systemImage: "xmark.circle") {
                    cancelCandidate = order
                }
                .tint(.red)
            }
        }
        .contextMenu {
            if isAdmin {
                Button(String(localized: "Cancel order"), systemImage: "xmark.circle", role: .destructive) {
                    cancelCandidate = order
                }
            }
        }
    }
}

// MARK: - Order line

struct OrderProductRoute: Identifiable, Hashable {
    let id: UUID
    let name: String
    let imagePath: String?
}

private struct AddPickerContext: Identifiable {
    let id = UUID()
    /// Supplier name when opened from a supplier's group.
    let title: String?
    let products: [OrderProductInput]
}

/// Searchable product list (image, stock, sales) for putting a product on the
/// order list.
private struct AddToOrderListSheet: View {
    let title: String?
    let products: [OrderProductInput]
    let onPick: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [OrderProductInput] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return products }
        return products.filter { $0.productName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { p in
                Button {
                    onPick(p.productId)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        ProductImage(imagePath: p.imagePath, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.productName)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(verbatim: detailText(p))
                                .font(.caption)
                                .foregroundStyle(p.warehouseQty == 0 ? Color.red : Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(String(localized: "Search products"))
            )
            .navigationTitle(title ?? String(localized: "Add to order list"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }

    private func detailText(_ p: OrderProductInput) -> String {
        var parts = [String(localized: "\(p.warehouseQty) in stock")]
        if p.avgDailySales > 0 {
            parts.append(String(format: String(localized: "⌀ %.1f/day"), p.avgDailySales))
        }
        if p.onOrder > 0 {
            parts.append(String(localized: "\(p.onOrder) on the way"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct OrderLineRow: View {
    let line: OrderLine
    let showsSupplierPicker: Bool
    let suppliers: [OrderSupplier]
    let onOpen: () -> Void
    let onImageTap: () -> Void
    let onCartons: (Int) -> Void
    let onReset: () -> Void
    let onAssign: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onImageTap) {
                    ProductImage(imagePath: line.product.imagePath, size: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.product.productName)
                                .font(.body)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                OrderBadge(kind: line.manual != nil ? .manual : .auto)
                                Text(reasonText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(stockText)
                                .font(.caption2)
                                .foregroundStyle(line.product.warehouseQty == 0 ? Color.red : Color.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Button {
                    onCartons(line.cartons - 1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .disabled(line.cartons <= 0)
                .accessibilityLabel(String(localized: "less"))

                Text(cartonLabel)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 56)

                Button {
                    onCartons(line.cartons + 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(String(localized: "more"))

                VStack(alignment: .leading, spacing: 1) {
                    Text(unitsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if line.overridden {
                        Button(String(localized: "Reset quantity"), action: onReset)
                            .font(.caption2)
                            .buttonStyle(.borderless)
                    }
                }
                Spacer(minLength: 0)
            }

            if showsSupplierPicker {
                Menu {
                    ForEach(suppliers) { s in
                        Button(s.name) { onAssign(s.id) }
                    }
                } label: {
                    Label(String(localized: "Assign supplier …"), systemImage: "person.crop.circle.badge.plus")
                        .font(.subheadline)
                }
                .disabled(suppliers.isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    private var cartonLabel: String {
        let size = max(1, line.product.unitSize)
        return size > 1 ? "\(line.cartons) × \(size)" : "\(line.cartons)"
    }

    private var unitsText: String {
        let size = max(1, line.product.unitSize)
        return size > 1
            ? String(localized: "Carton of \(size) = \(line.units) units")
            : String(localized: "\(line.units) units")
    }

    private var reasonText: String {
        if let manual = line.manual {
            let via = OrderBadge.viaLabel(manual.addedVia)
            return "\(manual.addedByName ?? "—"), \(via)"
        }
        if let reach = line.reachDays {
            return String(localized: "lasts \(reach) of \(line.targetDays) d")
        }
        return String(localized: "no sales")
    }

    private var stockText: String {
        var parts = [String(localized: "Available \(line.available)")]
        if line.product.onOrder > 0 {
            parts.append(String(localized: "\(line.product.onOrder) on the way"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Badge

/// "Automatic" (from stock and reach) or "Manual" (added on purpose).
struct OrderBadge: View {
    enum Kind { case auto, manual }
    let kind: Kind

    var body: some View {
        Text(kind == .auto ? String(localized: "Automatic") : String(localized: "Manual"))
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color { kind == .auto ? .blue : .purple }

    static func viaLabel(_ via: String) -> String {
        switch via {
        case "ios": return String(localized: "iPhone")
        case "android": return String(localized: "Android")
        default: return String(localized: "web")
        }
    }
}
