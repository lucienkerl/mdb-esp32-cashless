import SwiftUI

/// Review step: shows discontinued/expired products and lets user pick replacements or skip.
struct ReviewStepView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    /// Tracks which tray's picker sheet is open (by tray ID).
    @State private var pickerTrayId: UUID?
    @State private var selectedProduct: ProductSelection?

    struct ProductSelection: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text("Product Review")
                            .font(.title3.bold())
                        Text("The following trays need attention — discontinued, expired, out-of-stock, or unassigned products. Choose a replacement or skip.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    ForEach(viewModel.replacements) { suggestion in
                        replacementCard(suggestion)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 100)
            }

            // Bottom Bar
            bottomBar
        }
        .sheet(item: $pickerTrayId) { trayId in
            NavigationStack {
                ReplacementProductPicker(
                    products: viewModel.availableProducts,
                    selectedProductId: viewModel.replacements.first(where: { $0.trayId == trayId })?.replacementProductId,
                    existingSlotsByProduct: existingSlots(forTrayId: trayId),
                    machineLayout: machineLayout(forTrayId: trayId),
                    targetSlotNumber: targetSlot(forTrayId: trayId)?.itemNumber,
                    targetSlotCapacity: targetSlot(forTrayId: trayId)?.capacity,
                    remainingStock: { id in
                        // Only show stock counts when a warehouse with stock
                        // data is loaded — otherwise we'd render bogus zeros.
                        guard viewModel.selectedWarehouseId != nil,
                              !viewModel.warehouseStock.isEmpty
                        else { return nil }
                        return viewModel.remainingWarehouseStock(productId: id)
                    },
                    currentCategoryId: viewModel.currentCategoryId(forTrayId: trayId),
                    categories: viewModel.productCategories,
                    recentRemovals: recentRemovals(forTrayId: trayId),
                    onSelect: { productId in
                        viewModel.setReplacement(trayId: trayId, productId: productId)
                        pickerTrayId = nil
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { pickerTrayId = nil }
                    }
                }
            }
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
    }

    // MARK: - Replacement Card

    private func replacementCard(_ suggestion: ReplacementSuggestion) -> some View {
        let isUnassigned = suggestion.reason == .unassigned

        return VStack(spacing: 12) {
            // Current product header
            HStack(spacing: 12) {
                // Slot badge
                Text("\(suggestion.slotNumber)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(badgeColor(for: suggestion.reason)))

                if isUnassigned {
                    // Placeholder icon in lieu of a product image.
                    Image(systemName: "questionmark.square.dashed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.currentProductName)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            reasonBadge(suggestion.reason)
                            Text(suggestion.machineName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if suggestion.currentStock > 0 {
                            Text("\(suggestion.currentStock) items still in machine")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("0 items in machine")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Button {
                        guard let pid = suggestion.currentProductId else { return }
                        selectedProduct = ProductSelection(
                            id: pid,
                            name: suggestion.currentProductName,
                            imagePath: suggestion.currentProductImage,
                            sellprice: nil
                        )
                    } label: {
                        HStack(spacing: 12) {
                            ProductImage(imagePath: suggestion.currentProductImage, size: 40)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.currentProductName)
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .strikethrough(true, color: .red)
                                    .foregroundStyle(.primary)

                                HStack(spacing: 6) {
                                    reasonBadge(suggestion.reason)
                                    Text(suggestion.machineName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if suggestion.currentStock > 0 {
                                    Text("\(suggestion.currentStock) items still in machine")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("0 items in machine")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            Divider()

            // Replacement / Skip
            if suggestion.isSkipped {
                HStack {
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                    Text(isUnassigned
                         ? "Skipped — slot stays unassigned"
                         : "Skipped — keeping current product")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") {
                        if let idx = viewModel.replacements.firstIndex(where: { $0.trayId == suggestion.trayId }) {
                            viewModel.replacements[idx].isSkipped = false
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }
            } else if let replacementId = suggestion.replacementProductId,
                      let product = viewModel.availableProducts.first(where: { $0.id == replacementId }) {
                // Already has a replacement selected — tap to change
                Button {
                    pickerTrayId = suggestion.trayId
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.green)
                        ProductImage(imagePath: product.imagePath, size: 32)
                        Text(product.name ?? String(localized: "Unknown"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                        Spacer()
                        Text("Change")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.blue)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                // Needs action — Replace/Assign or Skip
                HStack(spacing: 12) {
                    Button {
                        pickerTrayId = suggestion.trayId
                    } label: {
                        Label(
                            isUnassigned ? "Assign" : "Replace",
                            systemImage: isUnassigned ? "plus.circle" : "arrow.triangle.2.circlepath"
                        )
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        viewModel.skipReplacement(trayId: suggestion.trayId)
                    } label: {
                        Text("Skip")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        // Data-dependent UI-test anchor: only exists once loadData() has
        // populated viewModel.replacements (fixtures guarantee at least one
        // unassigned tray, so this always appears on the Review step).
        .accessibilityIdentifier("refill-replacement-card")
    }

    // MARK: - Reason Badge

    private func badgeColor(for reason: ReplacementReason) -> Color {
        switch reason {
        case .discontinued: return .red
        case .expired: return .orange
        case .noStock: return .purple
        case .unassigned: return .blue
        }
    }

    private func reasonBadge(_ reason: ReplacementReason) -> some View {
        let (text, color): (LocalizedStringKey, Color) = {
            switch reason {
            case .discontinued: return ("Discontinued", .red)
            case .expired: return ("Expired", .orange)
            case .noStock: return ("No Stock", .purple)
            case .unassigned: return ("Unassigned", .blue)
            }
        }()

        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    // MARK: - Target Slot

    /// Look up the tray being replaced from the unfiltered tray set so the
    /// picker can show its capacity (spiral size). Reads
    /// `viewModel.allTraysByMachine` — the same source as `existingSlots` /
    /// `machineLayout` — because `machines[*].trays` only holds trays that
    /// need refill action. Returns `nil` if the machine or tray isn't found,
    /// which suppresses the capacity callout.
    private func targetSlot(forTrayId trayId: UUID) -> Tray? {
        guard let suggestion = viewModel.replacements.first(where: { $0.trayId == trayId })
        else { return nil }
        return viewModel.allTraysByMachine[suggestion.machineId]?
            .first(where: { $0.id == trayId })
    }

    // MARK: - Recent Removals

    /// Products recently taken out of the machine of the tray being replaced.
    private func recentRemovals(forTrayId trayId: UUID) -> [UUID: RecentRemoval] {
        guard let suggestion = viewModel.replacements.first(where: { $0.trayId == trayId })
        else { return [:] }
        return viewModel.recentRemovals[suggestion.machineId] ?? [:]
    }

    // MARK: - Existing Slots

    /// Build a map of productId → sorted slot numbers for every tray in the
    /// same machine as the tray being replaced, excluding the tray itself.
    ///
    /// Reads `viewModel.allTraysByMachine` (the unfiltered tray set) rather
    /// than `viewModel.machines[*].trays`, which only contains trays that
    /// need refill action — full/healthy trays would otherwise be missing
    /// from the picker badge even though the product is physically in the
    /// machine. Trays with `productId == nil` contribute nothing.
    private func existingSlots(forTrayId trayId: UUID) -> [UUID: [Int]] {
        guard let suggestion = viewModel.replacements.first(where: { $0.trayId == trayId })
        else { return [:] }

        let machineTrays = viewModel.allTraysByMachine[suggestion.machineId] ?? []

        var result: [UUID: [Int]] = [:]
        for tray in machineTrays where tray.id != trayId {
            guard let productId = tray.productId else { continue }
            result[productId, default: []].append(tray.itemNumber)
        }
        for key in result.keys {
            result[key]?.sort()
        }
        return result
    }

    /// Compute the full machine layout for the grid header in the picker.
    ///
    /// Reads `viewModel.allTraysByMachine` (the unfiltered tray set, same
    /// as `existingSlots`). Returns `MachineGridLayout(rowCount: 0, ...)`
    /// when the machine has no trays, or only the target slot — both
    /// signal "do not render the grid section".
    ///
    /// - Row = `(itemNumber / 10) - 1`, clamped to 0 for itemNumber < 10.
    /// - Column = `itemNumber % 10`.
    /// - Width = next occupied slot in the same row's itemNumber minus
    ///   this slot's itemNumber; 1 if there is no next slot in the row.
    private func machineLayout(forTrayId trayId: UUID) -> MachineGridLayout {
        guard let suggestion = viewModel.replacements.first(where: { $0.trayId == trayId })
        else { return MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: []) }

        let allTrays = viewModel.allTraysByMachine[suggestion.machineId] ?? []

        // Skip grid entirely when the machine is empty or has only the target.
        let nonTargetCount = allTrays.filter { $0.id != trayId }.count
        guard nonTargetCount > 0 else {
            return MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: [])
        }

        // Group trays by row, sort each row by itemNumber.
        var trayByRow: [Int: [Tray]] = [:]
        for tray in allTrays {
            let row = max(0, (tray.itemNumber / 10) - 1)
            trayByRow[row, default: []].append(tray)
        }
        for key in trayByRow.keys {
            trayByRow[key]?.sort { $0.itemNumber < $1.itemNumber }
        }

        // Build slots with width = next.itemNumber - this.itemNumber.
        var slots: [MachineGridSlot] = []
        for (row, rowTrays) in trayByRow {
            for (idx, tray) in rowTrays.enumerated() {
                let nextItemNumber = idx + 1 < rowTrays.count ? rowTrays[idx + 1].itemNumber : nil
                // Last slot in the row extends to the row's end: gap-to-end
                // is interpreted as "this slot is wider," same as mid-row gaps.
                // E.g. row ending at item 18 (col 8) with no 19 → width 2.
                let column = tray.itemNumber % 10
                let width = nextItemNumber.map { $0 - tray.itemNumber } ?? (10 - column)
                slots.append(
                    MachineGridSlot(
                        id: tray.id,
                        itemNumber: tray.itemNumber,
                        row: row,
                        column: column,
                        width: max(1, width),
                        productId: tray.productId,
                        productImagePath: tray.products?.imagePath,
                        isTarget: tray.id == trayId
                    )
                )
            }
        }

        let rowCount = (trayByRow.keys.max() ?? -1) + 1
        return MachineGridLayout(rowCount: rowCount, columnsPerRow: 10, slots: slots)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                // Skip all
                Button {
                    Task { await viewModel.skipReview() }
                } label: {
                    Text("Skip Rest")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Spacer()

                // Continue
                Button {
                    Task { await viewModel.applyReplacementsAndContinue() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    } else {
                        let hasReplacements = viewModel.replacements.contains { $0.replacementProductId != nil }
                        Label(
                            hasReplacements ? "Apply & Continue" : "Continue",
                            systemImage: "arrow.right.circle.fill"
                        )
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.allReplacementsHandled || viewModel.isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

// MARK: - UUID Identifiable for sheet(item:)

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
