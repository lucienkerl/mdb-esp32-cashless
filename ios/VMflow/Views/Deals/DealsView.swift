import SwiftUI

/// Main deals view showing matched retailer offers for company products.
/// Deals are deduplicated per (retailer, offer_id) and filtered by the user's
/// archive / pin state. Native iOS swipe-actions on each row give one-tap
/// pin and archive.
struct DealsView: View {
    @StateObject private var viewModel = DealsViewModel()
    @State private var selectedDeal: DedupedDeal?

    var body: some View {
        Group {
            if viewModel.settingsLoading && viewModel.deals.isEmpty {
                ProgressView()
            } else if !viewModel.dealsEnabled {
                disabledState
            } else {
                dealsList
            }
        }
        .navigationTitle("Deals")
        .task {
            await viewModel.loadAll()
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
        .sheet(item: $selectedDeal) { deal in
            DealDetailSheet(deal: deal, viewModel: viewModel)
                .presentationDetents([.large])
        }
    }

    // MARK: - Disabled State

    private var disabledState: some View {
        VStack(spacing: 20) {
            Image(systemName: "tag.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Deals Disabled")
                .font(.title2.weight(.bold))

            Text("Enable deal search in Settings to automatically find retailer offers matching your products.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            NavigationLink {
                SettingsView()
            } label: {
                Label("Open Settings", systemImage: "gearshape.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Deals List

    private var dealsList: some View {
        List {
            // Active / Archived picker
            Picker("List mode", selection: $viewModel.listMode) {
                ForEach(DealsViewModel.ListMode.allCases, id: \.self) { mode in
                    if mode == .archived && viewModel.archivedCount > 0 {
                        Text("\(mode.label) (\(viewModel.archivedCount))").tag(mode)
                    } else {
                        Text(mode.label).tag(mode)
                    }
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)

            // KPI Header
            if viewModel.avgDiscount > 0 {
                kpiHeader
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            // Grouping Picker
            Picker("Group by", selection: $viewModel.groupBy) {
                ForEach(DealsViewModel.GroupMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            if viewModel.isLoading && viewModel.deals.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading deals...")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if viewModel.filteredDeals.isEmpty {
                emptyResults
            } else {
                ForEach(viewModel.groupedDeals) { group in
                    Section {
                        ForEach(group.deals) { deal in
                            DealCard(deal: deal, isNew: viewModel.isNew(deal), pill: ekPill(for: deal), ekPrice: ekPriceLabel(for: deal))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedDeal = deal
                                }
                                // Re-runs when the row turns "new" while already on
                                // screen (new-keys RPC can land after the first render).
                                .task(id: viewModel.isNew(deal)) { viewModel.markSeen(deal) }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    pinSwipeButton(for: deal)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    archiveSwipeButton(for: deal)
                                }
                                .listRowBackground(deal.primary.validityStatus == .upcoming
                                                   ? Color.orange.opacity(0.08) : nil)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            if let icon = headerIcon(for: group.kind) {
                                Image(systemName: icon)
                                    .font(.caption)
                                    .foregroundStyle(headerColor(for: group.kind))
                            }
                            Text(group.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(headerColor(for: group.kind))
                            if let sub = group.sublabel {
                                Text(sub)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Text("\(group.deals.count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if viewModel.listMode == .active && !viewModel.suppressedActiveDeals.isEmpty {
                    Section {
                        ForEach(viewModel.suppressedActiveDeals) { deal in
                            DealCard(deal: deal, isNew: false,
                                     pill: .init(text: String(localized: "likely mismatch"), color: .red),
                                     ekPrice: ekPriceLabel(for: deal))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedDeal = deal
                                }
                        }
                    } header: {
                        Text("\(viewModel.suppressedActiveDeals.count) " + String(localized: "hidden — above your highest cost"))
                    }
                }
            }

            if viewModel.fromCache {
                HStack {
                    Spacer()
                    Label("Loaded from cache", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $viewModel.searchText, prompt: "Search deals...")
        .dataRefreshable {
            await viewModel.fetchUserStates()
            await viewModel.fetchDeals(forceRefresh: true)
            await viewModel.fetchNewDealKeys()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await viewModel.fetchUserStates()
                        await viewModel.fetchDeals(forceRefresh: true)
                        await viewModel.fetchNewDealKeys()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }
    }

    // MARK: - Section header styling

    private func headerIcon(for kind: DealsViewModel.DealGroup.Kind) -> String? {
        switch kind {
        case .pinned: return "pin.fill"
        case .validNow: return "checkmark.circle.fill"
        case .upcoming: return "calendar.badge.clock"
        case .expired: return "xmark.circle"
        case .plain: return nil
        }
    }

    private func headerColor(for kind: DealsViewModel.DealGroup.Kind) -> Color {
        switch kind {
        case .pinned: return .accentColor
        case .validNow: return .green
        case .upcoming: return .orange
        case .expired: return .secondary
        case .plain: return .primary
        }
    }

    // MARK: - EK pill

    private func ekPill(for deal: DedupedDeal) -> DealCard.Pill? {
        let ek = viewModel.dealEk(deal)
        guard let v = ek.bestVerdict else { return nil }
        let pct = ek.bestDeltaPct.map { abs(Int($0.rounded())) }
        switch v {
        case .goodBest, .good:
            let suffix = String(localized: "below your cost")
            return .init(text: pct.map { "\($0)% \(suffix)" } ?? suffix, color: .green)
        case .similar:
            return .init(text: String(localized: "≈ your cost"), color: .orange)
        case .worse:
            let suffix = String(localized: "above your cost")
            return .init(text: pct.map { "\($0)% \(suffix)" } ?? suffix, color: .red)
        default:
            return nil
        }
    }

    /// The usual EK to show on the card — the cheapest matched product's üblicher
    /// EK (see DealsViewModel.dealEk). Nil when no matched product has EK data.
    private func ekPriceLabel(for deal: DedupedDeal) -> String? {
        guard let gross = viewModel.dealEk(deal).usualEkGross else { return nil }
        return String(format: String(localized: "Cost %.2f \u{20AC}"), gross)
    }

    // MARK: - Swipe actions

    @ViewBuilder
    private func pinSwipeButton(for deal: DedupedDeal) -> some View {
        if deal.pinned {
            Button {
                Task { await viewModel.unpin(deal) }
            } label: {
                Label("Unpin", systemImage: "pin.slash.fill")
            }
            .tint(.gray)
        } else {
            Button {
                Task { await viewModel.pin(deal) }
            } label: {
                Label("Pin", systemImage: "pin.fill")
            }
            .tint(Color.accentColor)
        }
    }

    @ViewBuilder
    private func archiveSwipeButton(for deal: DedupedDeal) -> some View {
        if deal.archived {
            Button {
                Task { await viewModel.unarchive(deal) }
            } label: {
                Label("Restore", systemImage: "tray.and.arrow.up.fill")
            }
            .tint(.blue)
        } else {
            Button {
                Task { await viewModel.archive(deal) }
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .tint(.orange)
        }
    }

    // MARK: - KPI Header

    private var kpiHeader: some View {
        HStack(spacing: 12) {
            kpiBadge(
                value: "-\(viewModel.avgDiscount)%",
                label: "Avg",
                icon: "percent",
                color: .green
            )
        }
    }

    private func kpiBadge(value: String, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty Results

    private var emptyResults: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.listMode == .archived ? "archivebox" : "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(viewModel.listMode == .archived
                 ? String(localized: "No archived deals", comment: "Empty state title on the Deals screen when the Archived list has no items")
                 : String(localized: "No deals found", comment: "Empty state title on the Deals screen when the Active list has no items"))
                .font(.subheadline.weight(.medium))
            if !viewModel.searchText.isEmpty {
                Text("Try a different search term.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.listMode == .archived {
                Text("Archive deals you're not interested in to keep the list focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Try refreshing or check your ZIP code in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}

#Preview {
    NavigationStack {
        DealsView()
    }
}
