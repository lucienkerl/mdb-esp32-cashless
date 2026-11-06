import SwiftUI

/// Packing step: product-centric view showing all products needed across machines.
/// Each product card lists which machines need it with per-machine checkboxes.
struct PackingStepView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    @State private var selectedProduct: ProductSelection?
    /// Tour start with lines not ticked yet: show what stays behind.
    @State private var showsOpenLines = false

    fileprivate struct ProductSelection: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    // Notes written on earlier tours ("bring new spirals")
                    if !viewModel.tourNotes.isEmpty {
                        TourNotesCard(notes: viewModel.tourNotes, error: viewModel.tourNoteError) { id in
                            Task { await viewModel.completeTourNote(id) }
                        }
                    }

                    if !viewModel.warehouses.isEmpty {
                        warehousePicker
                    }
                    ChipBar(viewModel: viewModel)

                    if let notice = viewModel.replacementNotice {
                        replacementNoticeBanner(notice)
                    }

                    // Change notes (slot change requests) of the machines in view
                    changeNotes

                    Group {
                        switch viewModel.activeChip {
                        case .all:
                            AllPackingList(viewModel: viewModel, selectedProduct: $selectedProduct)
                        case .machine(let id):
                            MachinePackingList(viewModel: viewModel, machineId: id, selectedProduct: $selectedProduct)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.activeChip)
                }
                .padding(.horizontal)
                .padding(.bottom, 100)
            }

            // Bottom Bar
            bottomBar
        }
        .sheet(isPresented: $showsOpenLines) {
            OpenPackLinesSheet(viewModel: viewModel) {
                showsOpenLines = false
                Task { await viewModel.startTour() }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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

    // MARK: - Change Notes

    @ViewBuilder
    private var changeNotes: some View {
        switch viewModel.activeChip {
        case .all:
            ForEach(viewModel.machinesWithChangeNote) { machine in
                RefillChangeNoteCard(viewModel: viewModel, machine: machine)
            }
        case .machine(let id):
            if let machine = viewModel.machinesWithChangeNote.first(where: { $0.id == id }) {
                RefillChangeNoteCard(viewModel: viewModel, machine: machine, showsMachineName: false)
            }
        }
    }

    /// Confirmation after review-step replacements were queued as change notes.
    private func replacementNoticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .foregroundStyle(.orange)
            Text(notice)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                viewModel.replacementNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    // MARK: - Warehouse Picker

    private var warehousePicker: some View {
        HStack {
            Image(systemName: "building.2")
                .foregroundStyle(.secondary)
            Picker("Warehouse", selection: $viewModel.selectedWarehouseId) {
                ForEach(viewModel.warehouses) { warehouse in
                    Text(warehouse.name).tag(UUID?.some(warehouse.id))
                }
            }
            .pickerStyle(.menu)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.fill.tertiary))
        .onChange(of: viewModel.selectedWarehouseId) { _, newValue in
            if let warehouseId = newValue {
                Task { await viewModel.loadWarehouseStock(warehouseId: warehouseId) }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    let ready = viewModel.packedMachines.count
                    Text(ready == 1 ? String(localized: "1 machine ready") : String(localized: "\(ready) machines ready"))
                        .font(.subheadline.weight(.medium))
                }

                Spacer()

                Button {
                    HapticFeedback.medium.fire()
                    if viewModel.openPackLines.isEmpty {
                        Task { await viewModel.startTour() }
                    } else {
                        showsOpenLines = true
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    } else {
                        Label("Start Tour", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.packedMachines.isEmpty || viewModel.isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

// MARK: - AllPackingList Subview

/// Product-centric list for the `.all` chip, in warehouse order: one card per
/// product, one line per machine. A line holds everything the machine gets of
/// the product — the refill and the units for its slot rebuilds — under one
/// tick ("ticked = in the box") and one amount.
private struct AllPackingList: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    @Binding var selectedProduct: PackingStepView.ProductSelection?

    var body: some View {
        VStack(spacing: 12) {
            // A machine with only a change note has nothing to pack here —
            // don't claim "all stocked" next to its note.
            let rows = viewModel.packRows(for: .all)
            if rows.isEmpty && !viewModel.isLoading
                && viewModel.machinesWithChangeNote.isEmpty {
                emptyState
            } else {
                ForEach(rows) { row in
                    PackProductCard(
                        viewModel: viewModel,
                        product: PackCardProduct(row),
                        machineIds: lineMachines(row),
                        showsMachines: true,
                        selectedProduct: $selectedProduct
                    )
                }
            }
        }
    }

    /// The machines with a line on the card: those refilling the product,
    /// then those needing it only for a rebuild.
    private func lineMachines(_ row: PackRow) -> [UUID] {
        switch row {
        case .product(let item, _):
            var ids = item.machineNeeds.map(\.machineId)
            let rebuild = viewModel.rebuildMachineNeeds(productId: item.productId, machineIds: viewModel.machines.map(\.id))
            for entry in rebuild where !ids.contains(entry.machineId) {
                ids.append(entry.machineId)
            }
            return ids
        case .rebuild(let rebuildRow):
            return rebuildRow.machineIds
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("All Stocked!")
                .font(.title3.weight(.semibold))
            Text("No machines need refilling right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }
}

// MARK: - ChipBar Subview

private struct ChipBar: View {
    @ObservedObject var viewModel: RefillWizardViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.chipOrder, id: \.self) { chip in
                    chipPill(chip)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private func chipPill(_ chip: ChipFilter) -> some View {
        let isActive = viewModel.activeChip == chip
        let isDone = viewModel.chipIsFullyPacked(chip)
        let name = viewModel.chipName(chip)
        let count = viewModel.chipItemCount(chip)
        // Machine chips carry the tour health dot, like the PWA's machine
        // cards (`effectiveStockHealth`): dimmed when the selected warehouse
        // has none of the machine's products.
        let health: StockHealth? = {
            guard case .machine(let id) = chip,
                  let machine = viewModel.machines.first(where: { $0.id == id }) else { return nil }
            return viewModel.effectiveStockHealth(machine)
        }()
        // A machine on the tour only for its change note is not dimmed.
        let hasChangeNote: Bool = {
            guard case .machine(let id) = chip,
                  let machine = viewModel.machines.first(where: { $0.id == id }) else { return false }
            return viewModel.hasAcceptedRebuild(machine)
        }()

        let bg: Color = {
            if isActive && isDone { return .green }
            if isActive { return .accentColor }
            if isDone { return Color.green.opacity(0.15) }
            return Color(.secondarySystemGroupedBackground)
        }()
        let fg: Color = {
            if isActive { return .white }
            if isDone { return .green }
            return .primary
        }()

        return Button {
            HapticFeedback.light.fire()
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.activeChip = chip
            }
        } label: {
            HStack(spacing: 4) {
                if let health, !isDone {
                    Circle()
                        .fill(Self.healthColor(health))
                        .frame(width: 7, height: 7)
                }
                Text(name)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                } else {
                    Text(" · \(count)")
                        .font(.caption2)
                        .opacity(0.7)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
            .overlay(Capsule().stroke(.black.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(isActive ? 0.15 : 0.05), radius: isActive ? 4 : 2, y: 1)
            .opacity(health == .ok && !isActive && !hasChangeNote ? 0.4 : 1)
        }
        .buttonStyle(.plain)
    }

    private static func healthColor(_ health: StockHealth) -> Color {
        switch health {
        case .critical: return .red
        case .low: return .orange
        case .fill: return .blue
        case .ok: return .green
        }
    }
}

// MARK: - MachinePackingList Subview

/// Flat per-product list scoped to one machine — used when the active chip
/// is `.machine(id)`. Same cards as the `.all` view, with the machine's one
/// line each, so packed state stays in sync across both views.
private struct MachinePackingList: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let machineId: UUID
    @Binding var selectedProduct: PackingStepView.ProductSelection?

    var body: some View {
        let rows = viewModel.packRows(for: .machine(machineId))
        if rows.isEmpty {
            emptyState
        } else {
            VStack(spacing: 12) {
                ForEach(rows) { row in
                    PackProductCard(
                        viewModel: viewModel,
                        product: PackCardProduct(row),
                        machineIds: [machineId],
                        showsMachines: false,
                        selectedProduct: $selectedProduct
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text(String(localized: "No products to pack for this machine"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Product Card

/// The product a card is about (a refilled product or one needed only for
/// slot rebuilds).
private struct PackCardProduct {
    let id: UUID
    let name: String
    let imagePath: String?
    let sellprice: Double?

    init(_ row: PackRow) {
        switch row {
        case .product(let item, _):
            id = item.productId
            name = item.productName
            imagePath = item.imagePath
            sellprice = item.sellprice
        case .rebuild(let rebuildRow):
            id = rebuildRow.productId
            name = rebuildRow.name ?? ""
            imagePath = rebuildRow.imagePath
            sellprice = nil
        }
    }

    var formattedPrice: String? {
        sellprice.map { String(format: "%.2f \u{20AC}", $0) }
    }
}

/// One product of the packing list: image, name, warehouse stock and — with
/// several machines — the total, then one line per machine. No tick of its
/// own: a card is done when every line is ticked.
private struct PackProductCard: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let product: PackCardProduct
    let machineIds: [UUID]
    /// Name the machine on each line (the "All" chip).
    let showsMachines: Bool
    @Binding var selectedProduct: PackingStepView.ProductSelection?

    var body: some View {
        let lines = machineIds.map { viewModel.packLine(machineId: $0, productId: product.id) }
        let open = lines.filter { !$0.isUnavailable }
        let total = lines.reduce(0) { $0 + $1.total }
        let need = lines.reduce(0) { $0 + $1.need }
        let unavailable = open.isEmpty
        let allTicked = !open.isEmpty && open.allSatisfy(\.ticked)
        let short = open.contains { $0.ticked && $0.shortfall > 0 }
        let borderColor: Color = short ? .orange.opacity(0.55) : (allTicked ? .green.opacity(0.45) : .clear)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProductImage(imagePath: product.imagePath, size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(product.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(unavailable ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        WarehouseStockBadge(viewModel: viewModel, productId: product.id, needed: need)
                        if let price = product.formattedPrice {
                            Text(price)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 4)

                Button {
                    selectedProduct = PackingStepView.ProductSelection(
                        id: product.id,
                        name: product.name,
                        imagePath: product.imagePath,
                        sellprice: product.sellprice
                    )
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Product details"))

                // The total only adds something with several lines.
                if lines.count > 1 {
                    Text(verbatim: "\(total)×")
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.blue.opacity(0.1)))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 10)

            ForEach(lines, id: \.machineId) { line in
                Divider()
                    .padding(.leading, 12)
                PackLineRow(
                    viewModel: viewModel,
                    line: line,
                    machineName: showsMachines ? viewModel.chipName(.machine(line.machineId)) : nil
                )
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: short ? 2 : 1.5))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        .opacity(unavailable ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: allTicked)
    }
}

/// One machine's line of a product: a big tick (everything of the line lies
/// in the box), what it is for — "3 refill + ⇄ 5 rebuild · slot 57" — and
/// one stepper for the whole amount. Packing less takes it off the refill
/// first; the rebuilt slots keep their goods as long as possible.
private struct PackLineRow: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let line: PackLine
    /// Machine name, shown on the "All" chip.
    let machineName: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                guard !line.isUnavailable else { return }
                HapticFeedback.light.fire()
                viewModel.toggleLine(machineId: line.machineId, productId: line.productId)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: line.isUnavailable ? "xmark.square" :
                            (line.ticked ? "checkmark.square.fill" : "square"))
                        .font(.title2)
                        .foregroundStyle(line.isUnavailable ? Color.red.opacity(0.4) :
                                            (line.ticked ? Color.green : Color.secondary))
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        if let machineName {
                            Text(verbatim: machineName)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        reason
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(line.isUnavailable)
            .accessibilityLabel(Text("In the box"))
            .accessibilityValue(Text(verbatim: "\(line.total)"))

            HStack(spacing: 6) {
                stepButton(systemImage: "minus", enabled: !line.isUnavailable && line.total > 0) {
                    viewModel.setLineQuantity(machineId: line.machineId, productId: line.productId, quantity: line.total - 1)
                }
                Text(verbatim: "\(line.total)")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .frame(minWidth: 44, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(line.isUnavailable ? 0.04 : 0.1)))
                    .foregroundStyle(line.isUnavailable ? Color.secondary : Color.blue)
                stepButton(systemImage: "plus", enabled: !line.isUnavailable && line.total < line.maxQuantity) {
                    viewModel.setLineQuantity(machineId: line.machineId, productId: line.productId, quantity: line.total + 1)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .opacity(line.isUnavailable ? 0.6 : 1.0)
    }

    /// "3 refill + ⇄ 5 rebuild · slot 57 · 2 still missing".
    private var reason: Text {
        var parts: [Text] = []
        if line.refillNeed > 0 {
            parts.append(line.hasRefill
                ? Text("\(line.refill) refill").foregroundStyle(.secondary)
                : Text("Refill: no stock").foregroundStyle(.red))
        }
        if line.rebuildNeed > 0 {
            parts.append(
                (Text(Image(systemName: "arrow.left.arrow.right")) + Text(verbatim: " ")
                    + Text("\(line.rebuild) rebuild") + Text(verbatim: " · ") + Text(verbatim: slotText))
                    .foregroundStyle(Color.rebuildViolet)
                    .fontWeight(.semibold)
            )
        }
        var text = parts.first ?? Text(verbatim: "")
        for part in parts.dropFirst() {
            text = text + Text(verbatim: " + ").foregroundStyle(.secondary) + part
        }
        if line.shortfall > 0 && !line.isUnavailable {
            text = text + Text(verbatim: " · ").foregroundStyle(.secondary)
                + Text(line.shortfall == 1 ? String(localized: "1 still missing") : String(localized: "\(line.shortfall) still missing"))
                    .foregroundStyle(.orange).fontWeight(.semibold)
        }
        return text
    }

    private var slotText: String {
        let slots = line.slots.map { String($0) }
        return slots.count == 1
            ? String(localized: "slot \(slots[0])")
            : String(localized: "slots \(slots.joined(separator: ", "))")
    }

    private func stepButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            HapticFeedback.light.fire()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 12).stroke(Color(.systemGray3), lineWidth: 1.5))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        }
        .disabled(!enabled)
    }
}

/// Warehouse stock of a product: "40 in stock", or orange when what is
/// left after the other ticked lines does not cover `needed`.
private struct WarehouseStockBadge: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let productId: UUID
    let needed: Int

    var body: some View {
        if let stock = viewModel.warehouseStockFor(productId: productId) {
            let remaining = viewModel.remainingWarehouseStock(productId: productId)
            let committed = viewModel.committedQuantity(productId: productId)
            if stock.totalQuantity <= 0 {
                pill(Text("Out of Stock"), color: .red)
            } else if remaining <= 0 && committed > 0 {
                pill(Text("\(committed)/\(stock.totalQuantity) committed"), color: .orange)
            } else if remaining < needed {
                pill(Text("\(stock.totalQuantity) in stock (\(remaining) left)"), color: .orange)
            } else {
                Text("\(stock.totalQuantity) in stock")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } else if viewModel.selectedWarehouseId != nil && !viewModel.warehouseStock.isEmpty {
            pill(Text("Not in warehouse"), color: .red)
        }
    }

    private func pill(_ text: Text, color: Color) -> some View {
        text
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Open Lines Sheet

/// Tour start while lines are not ticked: what stays in the warehouse (not
/// booked). The refiller goes back to packing or starts without it.
private struct OpenPackLinesSheet: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let onStartAnyway: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lines = viewModel.openPackLines
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "shippingbox")
                            .font(.title)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lines.count == 1
                                 ? String(localized: "1 line not in the box")
                                 : String(localized: "\(lines.count) lines not in the box"))
                                .font(.title3.bold())
                            Text("These goods stay in the warehouse and are not booked.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(spacing: 0) {
                        ForEach(lines) { line in
                            if line.id != lines.first?.id { Divider().padding(.leading, 62) }
                            HStack(spacing: 12) {
                                ProductImage(imagePath: line.imagePath, size: 38)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(line.productName)
                                        .font(.subheadline.weight(.semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(verbatim: line.machineName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !line.rebuildSlots.isEmpty {
                                        Label {
                                            Text(verbatim: slotText(line.rebuildSlots))
                                        } icon: {
                                            Image(systemName: "arrow.left.arrow.right")
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.rebuildViolet)
                                        .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text(verbatim: "\(line.quantity)")
                                    .font(.title3.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(Color.primary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))

                    if lines.contains(where: { !$0.rebuildSlots.isEmpty }) {
                        Label("If goods for a slot are missing at the machine, tap “Not possible today” there. The slot comes up again next tour.", systemImage: "arrow.left.arrow.right")
                            .font(.footnote)
                            .foregroundStyle(Color.rebuildViolet)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text("Keep packing")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onStartAnyway()
                    } label: {
                        Text("Start without these goods")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private func slotText(_ slots: [Int]) -> String {
        let list = slots.map { String($0) }
        return list.count == 1
            ? String(localized: "slot \(list[0])")
            : String(localized: "slots \(list.joined(separator: ", "))")
    }
}

#Preview {
    NavigationStack {
        PackingStepView(viewModel: RefillWizardViewModel())
    }
}
