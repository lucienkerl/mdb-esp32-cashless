import SwiftUI

/// Product-centric performance analysis for a machine — replaces the old
/// "Duplicates" tab. Ports the web's Analysis tab: a slot grid coloured by
/// product tier, one-click replacement suggestions, and on-demand AI
/// recommendations (`machine-insights`, Claude-backed — expensive, hence a
/// manual "Analyze" action rather than automatic).
struct MachineAnalysisView: View {
    @ObservedObject var detailViewModel: MachineDetailViewModel
    @ObservedObject var trayViewModel: TrayViewModel
    @StateObject private var vm = MachineAnalysisViewModel()
    @State private var replacingSlot: AnalysisGridSlot?
    /// Shown after a replacement was queued into the change request.
    @State private var queuedMessage: String?

    private var machineId: UUID { detailViewModel.machine.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if vm.isLoading && vm.products.isEmpty {
                    ProgressView(String(localized: "Analyzing..."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if vm.rowCount == 0 {
                    emptyState
                } else {
                    if let queuedMessage {
                        queuedBanner(queuedMessage)
                    }
                    daysPicker
                    gridSection
                    legendSection
                    aiInsightsSection
                    weakProductsSection
                }
            }
            .padding()
        }
        .dataRefreshable { await reload() }
        .task { await reload() }
        .sheet(item: $replacingSlot) { slot in
            ReplaceProductSheet(
                slot: slot,
                hasPendingChange: vm.pendingTrayIds.contains(slot.trayId),
                suggestions: vm.fillSuggestions.filter { $0.productId != slot.productId },
                catalogue: detailViewModel.products.filter { $0.id != slot.productId }
            ) { productId in
                await performSwap(trayId: slot.trayId, productId: productId)
            }
        }
        .alert(String(localized: "Error"), isPresented: .init(
            get: { vm.error != nil }, set: { if !$0 { vm.error = nil } }
        )) {
            Button(String(localized: "OK")) { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No trays configured")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Days picker

    private var daysPicker: some View {
        Picker(String(localized: "Window"), selection: Binding(
            get: { vm.days },
            set: { newValue in Task { await reload(days: newValue) } }
        )) {
            Text("7d").tag(7)
            Text("30d").tag(30)
            Text("90d").tag(90)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Grid

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Machine Layout")
                .font(.subheadline.weight(.semibold))
            AnalysisLayoutGrid(rowCount: vm.rowCount, slots: vm.slots, pendingTrayIds: vm.pendingTrayIds) { slot in
                replacingSlot = slot
            }
        }
    }

    private var legendSection: some View {
        let tiers: [SlotTier] = [.strong, .ok, .testing, .weak, .dead]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ForEach(tiers, id: \.self) { tier in
                    HStack(spacing: 4) {
                        Circle().fill(tier.color).frame(width: 8, height: 8)
                        Text(tier.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !vm.pendingTrayIds.isEmpty {
                HStack(spacing: 4) {
                    PendingChangeBadge()
                    Text("Change pending").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func queuedBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                queuedMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - AI Insights

    @ViewBuilder
    private var aiInsightsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(String(localized: "AI Recommendations"), systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await fetchInsights(forceRefresh: vm.insights != nil) }
                } label: {
                    if vm.insightsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(vm.insights == nil ? String(localized: "Analyze") : String(localized: "Refresh"))
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.insightsLoading)
            }

            if let error = vm.insightsError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let insights = vm.insights {
                Text(insights.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(insights.recommendations) { rec in
                    recommendationRow(rec)
                }
            } else if !vm.insightsLoading {
                Text("Get AI-powered suggestions on what to swap, restock, or investigate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
    }

    private func recommendationRow(_ rec: MachineInsightRecommendation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(priorityColor(rec.priority))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title).font(.footnote.weight(.medium))
                Text(rec.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority.lowercased() {
        case "high": return .red
        case "medium": return .orange
        default: return .secondary
        }
    }

    // MARK: - Products to review

    @ViewBuilder
    private var weakProductsSection: some View {
        if !vm.weakProducts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Products to Review")
                    .font(.subheadline.weight(.semibold))
                ForEach(vm.weakProducts) { product in
                    weakProductRow(product)
                }
            }
        }
    }

    private func weakProductRow(_ product: ProductAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(product.name).font(.subheadline.weight(.medium))
                Spacer()
                Text(tierLabel(product.tier))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(product.tier.color.opacity(0.15), in: Capsule())
                    .foregroundStyle(product.tier.color)
            }
            Text(String(localized: "\(Int(product.sellThroughPct))% sell-through · \(product.unitsSold) sold") + tenureSuffix(product))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !product.suggestions.isEmpty {
                Text("Try instead: \(product.suggestions.map(\.name).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }

    private func tenureSuffix(_ product: ProductAnalysis) -> String {
        guard let tenure = product.tenureDays else { return "" }
        return String(localized: " · \(tenure)d in machine")
    }

    private func tierLabel(_ tier: SlotTier) -> String { tier.label }

    // MARK: - Actions

    private func reload(days: Int? = nil) async {
        await vm.analyze(machineId: machineId, trays: trayViewModel.trays, catalogue: detailViewModel.products, windowDays: days)
    }

    private func fetchInsights(forceRefresh: Bool) async {
        await vm.fetchInsights(machineId: machineId, forceRefresh: forceRefresh, locale: Locale.current.language.languageCode?.identifier ?? "en")
    }

    /// Queues the replacement into the machine's change request; the slot
    /// itself only changes when the refiller rebuilds it on the next tour,
    /// so trays and the analysis stay as they are.
    private func performSwap(trayId: UUID, productId: UUID) async {
        let slotNumber = vm.slots.first { $0.trayId == trayId }?.itemNumber
        let ok = await vm.applySwap(trayId: trayId, productId: productId)
        guard ok else { return }
        queuedMessage = String(localized: "Slot \(slotNumber ?? 0) added to the change request. It is rebuilt on the next refill tour.")
    }
}

// MARK: - Tier styling

extension SlotTier {
    var color: Color {
        switch self {
        case .dead: return .red
        case .weak: return .orange
        case .testing: return .blue
        case .ok: return Color(red: 0.75, green: 0.65, blue: 0.05) // amber-ish, distinct from strong green
        case .strong: return .green
        case .empty: return .gray
        }
    }

    var label: String {
        switch self {
        case .dead: return String(localized: "Dead")
        case .weak: return String(localized: "Weak")
        case .testing: return String(localized: "Testing")
        case .ok: return String(localized: "OK")
        case .strong: return String(localized: "Strong")
        case .empty: return String(localized: "Empty")
        }
    }
}

// MARK: - Grid (tier-coloured, parallel to MachineLayoutGrid but for Analysis)

/// Renders `AnalysisGridSlot`s as a fixed 10-column grid, coloured by tier.
/// Deliberately separate from `MachineLayoutGrid.swift` (used by the Refill
/// Wizard) — same row/column/width math, different visual language (tier
/// colour instead of target-slot highlighting), so neither feature risks
/// breaking the other.
struct AnalysisLayoutGrid: View {
    let rowCount: Int
    let slots: [AnalysisGridSlot]
    var pendingTrayIds: Set<UUID> = []
    let onTap: (AnalysisGridSlot) -> Void

    private let cellHeight: CGFloat = 48
    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let columns = 10
            let cellWidth = max(0, (geo.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    rowView(row: row, cellWidth: cellWidth)
                }
            }
        }
        .frame(height: CGFloat(rowCount) * cellHeight + CGFloat(max(0, rowCount - 1)) * spacing)
    }

    @ViewBuilder
    private func rowView(row: Int, cellWidth: CGFloat) -> some View {
        let rowSlots = slots.filter { $0.row == row }.sorted { $0.column < $1.column }
        let lastOccupied = rowSlots.last.map { $0.column + $0.width - 1 } ?? -1

        HStack(spacing: spacing) {
            let items = columnEntries(rowSlots: rowSlots, lastOccupied: lastOccupied)
            ForEach(items, id: \.id) { entry in
                entry.view(cellWidth)
            }
        }
    }

    private struct ColumnEntry {
        let id: Int
        let view: (CGFloat) -> AnyView
    }

    private func columnEntries(rowSlots: [AnalysisGridSlot], lastOccupied: Int) -> [ColumnEntry] {
        var result: [ColumnEntry] = []
        var c = 0
        var idx = 0
        while c < 10 {
            if idx < rowSlots.count, rowSlots[idx].column == c {
                let slot = rowSlots[idx]
                result.append(ColumnEntry(id: c) { width in
                    AnyView(
                        Button { onTap(slot) } label: {
                            AnalysisGridCell(slot: slot, isPending: pendingTrayIds.contains(slot.trayId), cellWidth: width * CGFloat(slot.width) + spacing * CGFloat(slot.width - 1), cellHeight: cellHeight)
                        }
                        .buttonStyle(.plain)
                    )
                })
                c += slot.width
                idx += 1
            } else if c <= lastOccupied {
                result.append(ColumnEntry(id: c) { width in
                    AnyView(Color.clear.frame(width: width, height: cellHeight))
                })
                c += 1
            } else {
                result.append(ColumnEntry(id: c) { width in
                    AnyView(Color.clear.frame(width: width, height: cellHeight))
                })
                c += 1
            }
        }
        return result
    }
}

private struct AnalysisGridCell: View {
    let slot: AnalysisGridSlot
    var isPending = false
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(slot.tier.color.opacity(slot.tier == .empty ? 0.15 : 0.35))
                .overlay {
                    if let path = slot.imagePath, !path.isEmpty {
                        ProductImage(imagePath: path, width: cellWidth - 4, height: cellHeight - 4)
                    }
                }
            Text("\(slot.itemNumber)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(2)
        }
        .frame(width: cellWidth, height: cellHeight)
        .overlay(alignment: .topTrailing) {
            if isPending {
                PendingChangeBadge().padding(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let base = slot.productName ?? String(localized: "Slot \(slot.itemNumber), empty")
        return isPending ? base + ", " + String(localized: "Change pending") : base
    }
}

/// Marks a slot that already has a pending change on the machine's change
/// request (rebuilt on the next refill tour).
private struct PendingChangeBadge: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.orange))
            .accessibilityHidden(true)
    }
}

// MARK: - Replace Product Sheet

/// Picks a replacement product for a slot: quick-tap suggestions (fleet
/// bestsellers not yet in this machine, plus never-sold newcomers) or a
/// searchable full catalogue.
private struct ReplaceProductSheet: View {
    let slot: AnalysisGridSlot
    var hasPendingChange = false
    let suggestions: [Suggestion]
    let catalogue: [Product]
    let onSelect: (UUID) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isApplying = false

    private var filteredCatalogue: [Product] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return catalogue.filter { ($0.name ?? "").localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choosing a product adds it to the change request. The slot is rebuilt on the next refill tour.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if hasPendingChange {
                        Label {
                            Text("This slot already has a pending change. Choosing a product replaces it.")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if !suggestions.isEmpty {
                    Section(String(localized: "Suggestions")) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                apply(suggestion.productId)
                            } label: {
                                HStack {
                                    ProductImage(imagePath: suggestion.imagePath, size: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(suggestion.name).foregroundStyle(.primary)
                                        Text(suggestion.kind == .bestseller
                                             ? String(localized: "Fleet bestseller")
                                             : String(localized: "Never sold — test candidate"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                Section(String(localized: "Search catalogue")) {
                    if !filteredCatalogue.isEmpty {
                        ForEach(filteredCatalogue) { product in
                            Button {
                                apply(product.id)
                            } label: {
                                HStack {
                                    ProductImage(imagePath: product.imagePath, size: 32)
                                    Text(product.name ?? String(localized: "Unnamed")).foregroundStyle(.primary)
                                }
                            }
                        }
                    } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(String(localized: "No matches")).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: String(localized: "Search products"))
            .navigationTitle(String(localized: "Replace Product"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
            .disabled(isApplying)
            .overlay {
                if isApplying { ProgressView() }
            }
        }
    }

    private func apply(_ productId: UUID) {
        isApplying = true
        Task {
            await onSelect(productId)
            isApplying = false
            dismiss()
        }
    }
}
