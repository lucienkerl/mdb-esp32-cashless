import SwiftUI

/// Packing step: product-centric view showing all products needed across machines.
/// Each product card lists which machines need it with per-machine checkboxes.
struct PackingStepView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    @State private var selectedProduct: ProductSelection?

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
                    HeaderStrip(viewModel: viewModel)

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
                    Text("\(viewModel.packedMachines.count) machines ready")
                        .font(.subheadline.weight(.medium))
                    Text("\(viewModel.totalItemsToPack) items to pack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    HapticFeedback.medium.fire()
                    Task { await viewModel.startTour() }
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

/// Today's product-centric list — extracted unchanged from PackingStepView.
/// Renders cards grouped by product with expandable per-machine sub-rows.
/// Used when the active chip is `.all`. Slot rebuild units sit in the same
/// list, in warehouse order: a violet "+N rebuild" badge on the product's
/// card, or a violet row of their own (`RebuildPackRowView`).
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
                    switch row {
                    case .product(let item, let rebuild):
                        productCard(item, rebuild: rebuild)
                    case .rebuild(let rebuildRow):
                        RebuildPackRowView(viewModel: viewModel, row: rebuildRow, showsMachines: true)
                    }
                }
            }
        }
    }

    // MARK: - Product Card

    private func productCard(_ item: CombinedPackingItem, rebuild: Int) -> some View {
        let fullyPacked = viewModel.isProductFullyPacked(item)
        // "Out of stock" should mean: nothing left AND nothing packed yet.
        // If the product is fully committed to one or more machines, the
        // remaining stock is 0 but the card is packed, not unusable.
        let outOfStock = !fullyPacked && viewModel.isOutOfWarehouseStock(productId: item.productId)

        // "All needs met" = every machine-need is both checked AND getting
        // at least the full required quantity. Distinguishes the ideal state
        // (every tray will be fully topped up) from a product that's checked
        // off but underpacked because of warehouse cap or a manual qty reduction.
        let allNeedsMet = item.machineNeeds.allSatisfy { need in
            viewModel.isMachinePacked(machineId: need.machineId, productId: item.productId)
                && viewModel.displayQuantity(machineId: need.machineId, productId: item.productId) >= need.quantity
        }
        // "Underpacked" = user has committed to this product (at least one
        // machine is checked), but the total packed quantity is below the
        // total required. Warrants a warning border so the user doesn't miss it.
        let anyPacked = item.machineNeeds.contains { need in
            viewModel.isMachinePacked(machineId: need.machineId, productId: item.productId)
        }
        let underpacked = !outOfStock && anyPacked && !allNeedsMet

        // Border color signals the card's commitment status at a glance.
        let borderColor: Color = {
            if outOfStock { return .clear }
            if allNeedsMet { return .green.opacity(0.35) }
            if underpacked { return .orange.opacity(0.55) }
            return .clear
        }()
        let borderWidth: CGFloat = underpacked ? 2 : 1.5

        // Total packed vs. total needed — shown beside the quantity badge
        // when there's a shortfall, so the user sees "6× / 9 needed" at a glance.
        let totalPacked = item.machineNeeds.reduce(0) { sum, need in
            let isPacked = viewModel.isMachinePacked(machineId: need.machineId, productId: item.productId)
            return sum + (isPacked ? viewModel.displayQuantity(machineId: need.machineId, productId: item.productId) : 0)
        }
        let shortfall = max(0, item.totalQuantity - totalPacked)

        return VStack(spacing: 0) {
            // Product header
            Button {
                guard !outOfStock else { return }
                HapticFeedback.light.fire()
                viewModel.togglePackedAll(productId: item.productId)
            } label: {
                HStack(spacing: 12) {
                    // Checkbox for all machines
                    Image(systemName: outOfStock ? "xmark.circle.fill" :
                            (fullyPacked ? "checkmark.circle.fill" : "circle"))
                        .font(.title3)
                        .foregroundStyle(outOfStock ? .red.opacity(0.5) :
                                        (fullyPacked ? .green : .secondary))

                    ProductImage(imagePath: item.imagePath, size: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.productName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(outOfStock ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            warehouseStockBadge(for: item)

                            if let price = item.formattedSellprice {
                                Text(price)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Info button — opens ProductDetailSheet without triggering
                    // the parent toggle. Nested Button + .borderless ensures
                    // SwiftUI treats it as a separate hit target.
                    Button {
                        selectedProduct = PackingStepView.ProductSelection(
                            id: item.productId,
                            name: item.productName,
                            imagePath: item.imagePath,
                            sellprice: item.sellprice
                        )
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    // Total quantity — use displayQuantity so unchecked rows
                    // reflect the warehouse cap instead of the raw deficit.
                    let totalQty = item.machineNeeds.reduce(0) { sum, need in
                        sum + viewModel.displayQuantity(machineId: need.machineId, productId: item.productId)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(totalQty)×")
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(
                                outOfStock ? Color.secondary :
                                (underpacked ? Color.orange : Color.blue)
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(
                                outOfStock ? Color.gray.opacity(0.1) :
                                (underpacked ? Color.orange.opacity(0.12) : Color.blue.opacity(0.1))
                            ))
                        if underpacked {
                            // Make the shortfall explicit — "-3" is more
                            // actionable than just a coloured border.
                            Text("-\(shortfall) short")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                                .monospacedDigit()
                        }
                        if rebuild > 0 {
                            RebuildBadge(units: rebuild)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(outOfStock)
            .padding(14)

            Divider()
                .padding(.leading, 14)

            // Machine sub-rows
            VStack(spacing: 0) {
                ForEach(item.machineNeeds) { need in
                    machineNeedRow(item: item, need: need)

                    if need.id != item.machineNeeds.last?.id {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
                // Units of the same product for slot rebuilds, adjustable
                // per machine like the refill itself.
                ForEach(viewModel.rebuildMachineNeeds(productId: item.productId, machineIds: viewModel.machines.map(\.id))) { entry in
                    Divider()
                        .padding(.leading, 52)
                    RebuildQuantityRow(
                        viewModel: viewModel,
                        machineId: entry.machineId,
                        productId: item.productId,
                        need: entry.need,
                        showsMachine: true
                    )
                }
            }
            .padding(.bottom, 6)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        .opacity(outOfStock ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: fullyPacked)
        .animation(.easeInOut(duration: 0.2), value: underpacked)
    }

    // MARK: - Machine Need Row

    private func machineNeedRow(item: CombinedPackingItem, need: MachineNeed) -> some View {
        let isPacked = viewModel.isMachinePacked(machineId: need.machineId, productId: item.productId)
        let isDisabled = viewModel.isOutOfStockForMachine(machineId: need.machineId, productId: item.productId)
        // Display the capped quantity for unchecked rows so reducing a tile
        // after an uncheck doesn't suddenly jump up to the raw deficit.
        let qty = viewModel.displayQuantity(machineId: need.machineId, productId: item.productId)
        let maxQty = viewModel.maxPackingQuantity(machineId: need.machineId, productId: item.productId)
        // "Partial" fires on either cause: warehouse cap (maxQty < need) or
        // the user having manually dialled the quantity down below the need.
        let isPartial = isPacked && qty < need.quantity

        return HStack(spacing: 10) {
            // Checkbox
            Button {
                guard !isDisabled else { return }
                HapticFeedback.light.fire()
                viewModel.togglePackedForMachine(productId: item.productId, machineId: need.machineId)
            } label: {
                Image(systemName: isDisabled ? "xmark.square" :
                        (isPacked ? "checkmark.square.fill" : "square"))
                    .font(.title3)
                    .foregroundStyle(isDisabled ? .red.opacity(0.4) :
                                    (isPacked ? .blue : .secondary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isDisabled)

            VStack(alignment: .leading, spacing: 2) {
                Text(need.machineName)
                    .font(.subheadline)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text("needs \(need.quantity) / \(need.capacity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if isDisabled {
                        Text("No stock")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.red)
                    } else if isPartial {
                        Text("Partial")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            // Quantity stepper
            HStack(spacing: 6) {
                Button {
                    HapticFeedback.light.fire()
                    viewModel.setPackingQuantity(
                        machineId: need.machineId,
                        productId: item.productId,
                        quantity: qty - 1
                    )
                } label: {
                    Image(systemName: "minus")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.systemGray3), lineWidth: 1.5)
                        )
                        .foregroundStyle(qty > 0 ? .primary : .quaternary)
                }
                .disabled(qty <= 0 || isDisabled)

                Text("\(qty)")
                    .font(.body.weight(.bold))
                    .monospacedDigit()
                    .frame(minWidth: 44, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDisabled ? Color.gray.opacity(0.1) : Color.blue.opacity(0.1))
                    )
                    .foregroundStyle(isDisabled ? Color.secondary : Color.blue)

                Button {
                    HapticFeedback.light.fire()
                    viewModel.setPackingQuantity(
                        machineId: need.machineId,
                        productId: item.productId,
                        quantity: qty + 1
                    )
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.systemGray3), lineWidth: 1.5)
                        )
                        .foregroundStyle(qty < maxQty && !isDisabled ? .primary : .quaternary)
                }
                .disabled(qty >= maxQty || isDisabled)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .opacity(isDisabled ? 0.6 : 1.0)
    }

    // MARK: - Warehouse Stock Badge

    @ViewBuilder
    private func warehouseStockBadge(for item: CombinedPackingItem) -> some View {
        if let stock = viewModel.warehouseStockFor(productId: item.productId) {
            let remaining = viewModel.remainingWarehouseStock(productId: item.productId)
            let committed = viewModel.committedQuantity(productId: item.productId)

            if stock.totalQuantity <= 0 {
                Text("Out of Stock")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.red.opacity(0.12)))
            } else if remaining <= 0 && committed > 0 {
                Text("\(committed)/\(stock.totalQuantity) committed")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.12)))
            } else if remaining < item.totalQuantity {
                Text("\(stock.totalQuantity) in stock (\(remaining) left)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.12)))
            } else {
                Text("\(stock.totalQuantity) in stock")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        } else if viewModel.selectedWarehouseId != nil && !viewModel.warehouseStock.isEmpty {
            // Warehouse loaded but this product has zero stock
            Text("Not in warehouse")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.red.opacity(0.12)))
        }
    }

    // MARK: - Empty State

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

// MARK: - HeaderStrip Subview

private struct HeaderStrip: View {
    @ObservedObject var viewModel: RefillWizardViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text(headerText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                HapticFeedback.light.fire()
                switch viewModel.activeChip {
                case .all:
                    viewModel.packAllMachines()
                case .machine(let id):
                    viewModel.packAllForMachine(id)
                }
            } label: {
                Text(selectAllLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(foreground)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeChip)
    }

    // MARK: derived

    private enum HeaderState { case pending, done, alert }

    private var state: HeaderState {
        switch viewModel.activeChip {
        case .all:
            return viewModel.chipIsFullyPacked(.all) ? .done : .pending
        case .machine(let id):
            let done = viewModel.chipIsFullyPacked(.machine(id))
            if done { return .done }
            // Alert = at least one product is packed for this machine but the
            // overall chip is no longer fully packed (a sale increased deficit
            // since pack time).
            let anyPacked = viewModel.combinedPackingList.contains { item in
                item.machineNeeds.contains(where: { $0.machineId == id })
                    && viewModel.isMachinePacked(machineId: id, productId: item.productId)
            }
            return anyPacked ? .alert : .pending
        }
    }

    private var background: Color {
        switch state {
        case .pending: return Color.blue.opacity(0.10)
        case .done:    return Color.green.opacity(0.14)
        case .alert:   return Color.orange.opacity(0.14)
        }
    }

    private var foreground: Color {
        switch state {
        case .pending: return Color.blue
        case .done:    return Color.green
        case .alert:   return Color.orange
        }
    }

    private var headerText: String {
        switch viewModel.activeChip {
        case .all:
            let total = viewModel.chipItemCount(.all)
            if state == .done {
                return String(localized: "✓ All boxes packed · \(total) items")
            } else {
                let ready = viewModel.packedMachines.count
                let totalM = viewModel.machines.count
                return String(localized: "All machines · \(total) items · \(ready)/\(totalM) ready")
            }
        case .machine(let id):
            let name = viewModel.chipName(.machine(id))
            let total = viewModel.chipItemCount(.machine(id))
            let packed = viewModel.chipPackedCount(.machine(id))
            let totalNeeds = viewModel.chipNeedsCount(.machine(id))
            switch state {
            case .done:    return String(localized: "✓ \(name) · Box complete · \(packed)/\(totalNeeds) packed")
            case .alert:
                // Neutral wording: we can't distinguish a true "new sale"
                // event from the user manually dialing down a stepper after
                // packing. Both leave the box partial — say so directly.
                return String(localized: "⚠ \(name) · Box partial · \(packed)/\(totalNeeds) packed")
            case .pending: return String(localized: "\(name) · Box: \(total) items · \(packed)/\(totalNeeds) packed")
            }
        }
    }

    private var selectAllLabel: String {
        switch viewModel.activeChip {
        case .all:
            return String(localized: "Select All")
        case .machine(let id):
            let name = viewModel.chipName(.machine(id))
            return String(localized: "Pack all for \(name)")
        }
    }
}

// MARK: - MachinePackingList Subview

/// Flat per-product list scoped to one machine — used when the active chip
/// is `.machine(id)`. Each card commits / adjusts the `(machineId, productId)`
/// pair via the same ViewModel functions the `.all` view uses, so packed
/// state stays in sync across both views.
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
                    switch row {
                    case .product(let item, let rebuild):
                        card(item, rebuild: rebuild)
                    case .rebuild(let rebuildRow):
                        RebuildPackRowView(viewModel: viewModel, row: rebuildRow, showsMachines: false)
                    }
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

    @ViewBuilder
    private func card(_ item: CombinedPackingItem, rebuild: Int) -> some View {
        // By construction visibleItemsForActiveChip always returns items
        // with exactly one MachineNeed for the active machine. Guard
        // anyway — if a future refactor breaks that invariant we'd rather
        // render nothing than crash.
        if let need = item.machineNeeds.first {
            let isPacked = viewModel.isMachinePacked(machineId: machineId, productId: item.productId)
            let isDisabled = viewModel.isOutOfStockForMachine(machineId: machineId, productId: item.productId)
            let qty = viewModel.displayQuantity(machineId: machineId, productId: item.productId)
            let maxQty = viewModel.maxPackingQuantity(machineId: machineId, productId: item.productId)
            let isFullyPacked = isPacked && qty >= need.quantity
            let isPartial = isPacked && qty < need.quantity

            let borderColor: Color = {
                if isDisabled { return .clear }
                if isFullyPacked { return .green.opacity(0.35) }
                if isPartial { return .orange.opacity(0.55) }
                return .clear
            }()
            let borderWidth: CGFloat = isPartial ? 2 : 1.5

            VStack(alignment: .leading, spacing: 8) {
                // Title row — full width, with info button pinned right
                HStack(alignment: .top, spacing: 6) {
                    Text(item.productName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isDisabled ? .secondary : .primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if rebuild > 0 {
                        RebuildBadge(units: rebuild)
                            .padding(.top, 2)
                    }

                    Button {
                        selectedProduct = PackingStepView.ProductSelection(
                            id: item.productId,
                            name: item.productName,
                            imagePath: item.imagePath,
                            sellprice: item.sellprice
                        )
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, height: 32, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }

                // Controls row — checkbox, image, meta (single-line truncated), stepper
                HStack(alignment: .center, spacing: 10) {
                    Button {
                        guard !isDisabled else { return }
                        HapticFeedback.light.fire()
                        viewModel.togglePackedForMachine(productId: item.productId, machineId: machineId)
                    } label: {
                        // Mirror AllPackingList.machineNeedRow: checkbox follows
                        // isPacked (machine-level commit), NOT isFullyPacked.
                        // Partial state is signaled by the orange border +
                        // "Partial" badge in the meta line, so the checkbox
                        // stays clearly "checked" when the user has committed
                        // even at less than full need.
                        Image(systemName: isDisabled ? "xmark.circle.fill" :
                                (isPacked ? "checkmark.circle.fill" : "circle"))
                            .font(.title2)
                            .foregroundStyle(isDisabled ? .red.opacity(0.5) :
                                            (isPacked ? .green : .secondary))
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDisabled)

                    ProductImage(imagePath: item.imagePath, size: 40)

                    metaLine(
                        need: need,
                        price: item.formattedSellprice,
                        isDisabled: isDisabled,
                        isPartial: isPartial
                    )
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        Button {
                            HapticFeedback.light.fire()
                            viewModel.setPackingQuantity(machineId: machineId, productId: item.productId, quantity: qty - 1)
                        } label: {
                            Image(systemName: "minus")
                                .font(.callout.weight(.semibold))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                                .background(RoundedRectangle(cornerRadius: 8).stroke(Color(.systemGray3), lineWidth: 1.5))
                                .foregroundStyle(qty > 0 ? .primary : .quaternary)
                        }
                        .disabled(qty <= 0 || isDisabled)

                        Text("\(qty)")
                            .font(.body.weight(.bold))
                            .monospacedDigit()
                            .frame(minWidth: 32, minHeight: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(isDisabled ? Color.gray.opacity(0.1) : Color.blue.opacity(0.1)))
                            .foregroundStyle(isDisabled ? Color.secondary : Color.blue)

                        Button {
                            HapticFeedback.light.fire()
                            viewModel.setPackingQuantity(machineId: machineId, productId: item.productId, quantity: qty + 1)
                        } label: {
                            Image(systemName: "plus")
                                .font(.callout.weight(.semibold))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                                .background(RoundedRectangle(cornerRadius: 8).stroke(Color(.systemGray3), lineWidth: 1.5))
                                .foregroundStyle(qty < maxQty && !isDisabled ? .primary : .quaternary)
                        }
                        .disabled(qty >= maxQty || isDisabled)
                    }
                    .buttonStyle(.borderless)
                }

                if let rebuildNeed = viewModel.rebuildMachineNeeds(productId: item.productId, machineIds: [machineId]).first {
                    Divider()
                    RebuildQuantityRow(
                        viewModel: viewModel,
                        machineId: machineId,
                        productId: item.productId,
                        need: rebuildNeed.need,
                        showsMachine: false,
                        inset: 0
                    )
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: borderWidth))
            .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
            .opacity(isDisabled ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isFullyPacked)
            .animation(.easeInOut(duration: 0.2), value: isPartial)
        }
    }

    /// Single concatenated `Text` so the meta row stays on one line and
    /// truncates at the tail when space runs out instead of wrapping the
    /// "Partial" / "No stock" badge below the row.
    private func metaLine(need: MachineNeed, price: String?, isDisabled: Bool, isPartial: Bool) -> Text {
        var line = Text("needs \(need.quantity) / \(need.capacity)").foregroundStyle(.secondary)
        if let price {
            line = line
                + Text(" · ").foregroundStyle(.tertiary)
                + Text(price).foregroundStyle(.secondary)
        }
        if isDisabled {
            line = line
                + Text(" · ").foregroundStyle(.tertiary)
                + Text("No stock").foregroundStyle(.red).fontWeight(.semibold)
        } else if isPartial {
            line = line
                + Text(" · ").foregroundStyle(.tertiary)
                + Text("Partial").foregroundStyle(.orange).fontWeight(.semibold)
        }
        return line
    }
}

// MARK: - Rebuild Rows

/// Violet "⇄ N rebuild" pill: units packed on top of the normal refill for
/// slot rebuilds (committed and deducted together with it).
private struct RebuildBadge: View {
    let units: Int

    var body: some View {
        Label {
            Text("\(units) rebuild")
        } icon: {
            Image(systemName: "arrow.left.arrow.right")
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(Color.rebuildViolet)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.rebuildVioletFill.opacity(0.15)))
        .fixedSize()
    }
}

/// A product packed only for slot rebuilds. Looks like any other card of the
/// packing list — the violet "⇄ New · slot" pill says what it is for. Like a
/// normal product, only a ticked row is taken along and booked out of the
/// warehouse at tour start. Mirrors the PWA's `RefillRebuildPackRow.vue`.
private struct RebuildPackRowView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let row: RebuildPackRow
    /// List the machines the units are for (the "All" chip).
    let showsMachines: Bool

    /// "New · Bahnhof Süd, slot 23" (the slots of every machine in scope).
    private var forLine: String {
        let parts: [String] = row.machineIds.compactMap { machineId in
            guard let machine = viewModel.machines.first(where: { $0.id == machineId }) else { return nil }
            let slots = viewModel.acceptedRebuildItems(machineId: machineId)
                .filter { $0.toProductId == row.productId }
                .map { String($0.itemNumber) }
            guard !slots.isEmpty else { return nil }
            let slotText = slots.count == 1
                ? String(localized: "slot \(slots[0])")
                : String(localized: "slots \(slots.joined(separator: ", "))")
            return showsMachines ? "\(machine.machine.displayName), \(slotText)" : slotText
        }
        return "\(String(localized: "New")) · \(parts.joined(separator: " · "))"
    }

    var body: some View {
        let ticked = viewModel.isRebuildRowTicked(row)

        VStack(spacing: 0) {
            Button {
                HapticFeedback.light.fire()
                viewModel.toggleRebuildRowTick(row)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(ticked ? Color.green : Color.secondary)

                    ProductImage(imagePath: row.imagePath, size: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name ?? "")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Label {
                            Text(verbatim: forLine)
                        } icon: {
                            Image(systemName: "arrow.left.arrow.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.rebuildViolet)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.rebuildVioletFill.opacity(0.15)))
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(row.packed)×")
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.blue.opacity(0.1)))
                        if row.packed < row.need {
                            Text("(\(row.need) needed)")
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Per machine, only when there is something to choose between
            // (several machines) — the amount itself is changed by tapping.
            ForEach(viewModel.rebuildMachineNeeds(productId: row.productId, machineIds: row.machineIds)) { entry in
                Divider()
                    .padding(.leading, 14)
                RebuildQuantityRow(
                    viewModel: viewModel,
                    machineId: entry.machineId,
                    productId: row.productId,
                    need: entry.need,
                    showsMachine: showsMachines
                )
            }
        }
        .padding(.bottom, 2)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ticked ? Color.green.opacity(0.35) : Color.clear, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        .animation(.easeInOut(duration: 0.2), value: ticked)
    }
}

/// Rebuild units of a product for one machine. Collapsed it is one quiet
/// line — "Bahnhof Süd  ⇄ 10" — and a tap opens the violet −/+ stepper, so
/// the refiller can pack less than the slots need (e.g. only half a spiral
/// of a new product) without the list being full of steppers.
/// Mirrors the PWA's `RefillRebuildQuantity.vue`.
private struct RebuildQuantityRow: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let machineId: UUID
    let productId: UUID
    let need: Int
    /// Name the machine (the "All" chip); otherwise the row just says "Rebuild".
    let showsMachine: Bool
    /// Horizontal padding: 0 inside a card that already has its own.
    var inset: CGFloat = 14

    @State private var isEditing = false

    var body: some View {
        let qty = viewModel.rebuildQuantity(machineId: machineId, productId: productId)
        let maxQty = viewModel.maxRebuildQuantity(machineId: machineId, productId: productId)

        VStack(spacing: 8) {
            Button {
                HapticFeedback.light.fire()
                withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if showsMachine {
                            Text(verbatim: viewModel.chipName(.machine(machineId)))
                        } else {
                            Text("Rebuild")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    if qty < need {
                        Text("of \(need)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                    RebuildBadgeQty(qty: qty)
                    Image(systemName: isEditing ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isEditing {
                HStack(spacing: 6) {
                    Spacer()
                    stepButton(systemImage: "minus", enabled: qty > 0) {
                        viewModel.setRebuildQuantity(machineId: machineId, productId: productId, quantity: qty - 1)
                    }
                    Text(verbatim: "\(qty)")
                        .font(.body.weight(.bold))
                        .monospacedDigit()
                        .frame(minWidth: 44, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.rebuildVioletFill.opacity(0.15)))
                        .foregroundStyle(Color.rebuildViolet)
                    stepButton(systemImage: "plus", enabled: qty < maxQty) {
                        viewModel.setRebuildQuantity(machineId: machineId, productId: productId, quantity: qty + 1)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 6)
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
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.rebuildVioletFill.opacity(0.5), lineWidth: 1.5)
                )
                .foregroundStyle(enabled ? Color.rebuildViolet : Color.secondary.opacity(0.4))
        }
        .disabled(!enabled)
    }
}

/// "⇄ 10" — the rebuild amount of one machine.
private struct RebuildBadgeQty: View {
    let qty: Int

    var body: some View {
        Label {
            Text(verbatim: "\(qty)")
        } icon: {
            Image(systemName: "arrow.left.arrow.right")
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(Color.rebuildViolet)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.rebuildVioletFill.opacity(0.15)))
        .fixedSize()
    }
}

#Preview {
    NavigationStack {
        PackingStepView(viewModel: RefillWizardViewModel())
    }
}
