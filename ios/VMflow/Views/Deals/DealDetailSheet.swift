import SwiftUI
import Supabase

/// Detail sheet showing full deal information with hero image, pin/archive
/// actions, and the full list of matched products / keyword groups. Takes
/// a `DedupedDeal` so the "N matched products" case is rendered properly.
struct DealDetailSheet: View {
    let deal: DedupedDeal
    @ObservedObject var viewModel: DealsViewModel

    @Environment(\.dismiss) private var dismiss
    @StateObject private var stockModel = DealProductStockModel()
    @State private var selectedProduct: DealProductSelection?

    /// Resolve the current user-state for this deal from the view model so
    /// pin/archive taps immediately update the button labels — the `deal`
    /// captured at sheet-open time is a value-type snapshot and doesn't
    /// observe subsequent mutations.
    private var liveDeal: DedupedDeal {
        viewModel.dedupedDeals.first(where: { $0.key == deal.key }) ?? deal
    }

    private var primary: Deal { liveDeal.primary }

    /// Bundle of identifiers that opens `ProductDetailSheet` when tapped. Lets
    /// the sheet-with-item sheet presentation work for both matched-product
    /// rows and keyword-group linked products.
    struct DealProductSelection: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    heroImage

                    VStack(alignment: .leading, spacing: 16) {
                        if primary.validityStatus == .upcoming {
                            notYetValidNotice
                        }

                        titleSection

                        Divider()

                        userActions

                        Divider()

                        priceSection

                        Divider()

                        validitySection

                        if primary.requiresApp {
                            appRequirementNotice
                        }

                        if !deal.matchedKeywords.isEmpty {
                            Divider()
                            keywordsSection
                        }

                        if !deal.matchedProducts.isEmpty {
                            Divider()
                            productsSection
                        }

                        Divider()

                        externalLinks
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                await stockModel.load(productIds: allProductIds)
            }
            .sheet(item: $selectedProduct) { selection in
                ProductDetailSheet(
                    productId: selection.id,
                    fallbackName: selection.name,
                    fallbackImagePath: selection.imagePath,
                    fallbackSellprice: selection.sellprice
                )
            }
        }
    }

    /// All product UUIDs referenced by this deal — used to batch-fetch stock
    /// across matched products and keyword-group linked products in one pair
    /// of queries.
    private var allProductIds: [UUID] {
        var ids: Set<UUID> = []
        for p in deal.matchedProducts { ids.insert(p.id) }
        for kw in deal.matchedKeywords {
            for p in kw.linkedProducts {
                if let id = p.id { ids.insert(id) }
            }
        }
        return Array(ids)
    }

    // MARK: - Hero Image

    private var heroImage: some View {
        Group {
            let urlString = primary.imageUrlLarge ?? primary.imageUrl
            if let urlString,
               let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        heroPlaceholder
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                    @unknown default:
                        heroPlaceholder
                    }
                }
            } else {
                heroPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 250)
        .background(Color(.systemGray6))
    }

    private var heroPlaceholder: some View {
        Image(systemName: "tag.fill")
            .font(.system(size: 48))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 200)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if liveDeal.pinned {
                    Image(systemName: "pin.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                Text(primary.dealTitle)
                    .font(.title3.weight(.bold))
            }

            HStack(spacing: 6) {
                Image(systemName: "storefront.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(liveDeal.retailer)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - User actions (pin / archive)

    private var userActions: some View {
        HStack(spacing: 10) {
            pinButton
            archiveButton
        }
    }

    // Split into separate @ViewBuilder properties so each branch can carry
    // its own .buttonStyle — a ternary returning different ButtonStyle
    // concrete types (.bordered vs .borderedProminent) doesn't compile.

    @ViewBuilder
    private var pinButton: some View {
        if liveDeal.pinned {
            Button {
                Task { await viewModel.unpin(liveDeal) }
            } label: {
                pinLabel
            }
            .buttonStyle(.bordered)
            .tint(Color.accentColor)
        } else {
            Button {
                Task { await viewModel.pin(liveDeal) }
            } label: {
                pinLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
        }
    }

    private var pinLabel: some View {
        Label(
            liveDeal.pinned ? "Unpin" : "Pin to top",
            systemImage: liveDeal.pinned ? "pin.slash.fill" : "pin.fill"
        )
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var archiveButton: some View {
        Button {
            if liveDeal.archived {
                Task { await viewModel.unarchive(liveDeal) }
            } else {
                Task { await viewModel.archive(liveDeal) }
                dismiss()
            }
        } label: {
            Label(
                liveDeal.archived ? "Restore" : "Archive",
                systemImage: liveDeal.archived ? "tray.and.arrow.up.fill" : "archivebox.fill"
            )
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(liveDeal.archived ? .blue : .orange)
    }

    // MARK: - Price

    private var priceSection: some View {
        HStack(spacing: 12) {
            if let price = primary.formattedDealPrice {
                Text(price)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.green)
            }

            if let regular = primary.formattedRegularPrice {
                Text(regular)
                    .font(.title3)
                    .strikethrough()
                    .foregroundStyle(.secondary)
            }

            if let discount = primary.formattedDiscount {
                Text(discount)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.green))
            }
        }
    }

    // MARK: - Validity

    private var validitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text("Validity")
                    .font(.subheadline.weight(.medium))
            }

            HStack(spacing: 8) {
                if let from = primary.formattedValidFrom {
                    Text(from)
                        .font(.subheadline)
                }

                if primary.validFrom != nil && primary.validUntil != nil {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let until = primary.formattedValidUntil {
                    Text(until)
                        .font(.subheadline)
                }

                Spacer()

                validityStatusBadge
            }
        }
    }

    /// Explicit callout for deals that only start later — the whole point is
    /// that nobody drives to the store for a price that isn't live yet.
    private var notYetValidNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(Deal.ValidityStatus.upcoming.label)
                    .font(.subheadline.weight(.semibold))
                if let from = primary.validFromDate, let rel = primary.startsInLabel {
                    Text(String(format: String(localized: "This offer only starts on %@ (%@). The store won't have this price before then."),
                                Deal.longDay(from), rel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.4)))
    }

    @ViewBuilder
    private var validityStatusBadge: some View {
        let status = primary.validityStatus
        Text(status.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(validityColor(status))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(validityColor(status).opacity(0.12)))
    }

    // MARK: - App Requirement

    private var appRequirementNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.badge.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Requires Loyalty App")
                    .font(.subheadline.weight(.medium))
                Text("This deal may require the retailer's loyalty app or membership card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.08)))
    }

    // MARK: - Matched Keywords

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(.secondary)
                Text("Matched Keyword Groups")
                    .font(.subheadline.weight(.medium))
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(deal.matchedKeywords.enumerated()), id: \.offset) { _, kw in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(kw.label ?? kw.terms?.first ?? "Keyword")
                                .font(.subheadline.weight(.medium))
                            if let term = primary.matchedTerm, !term.isEmpty {
                                Text("matched via \"\(term)\"")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if kw.linkedProducts.isEmpty {
                            Text("No products linked to this group yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            ForEach(Array(kw.linkedProducts.enumerated()), id: \.offset) { _, p in
                                if let name = p.name {
                                    Button {
                                        if let pid = p.id {
                                            selectedProduct = DealProductSelection(
                                                id: pid, name: name,
                                                imagePath: p.imagePath,
                                                sellprice: p.sellprice
                                            )
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text("• \(name)")
                                                .font(.caption)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Spacer()
                                            if let pid = p.id {
                                                stockBadges(for: pid, compact: true)
                                            }
                                            if p.id != nil {
                                                Image(systemName: "chevron.right")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(p.id == nil)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
        }
    }

    // MARK: - Matched Products

    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cube.box.fill")
                    .foregroundStyle(.secondary)
                Text(deal.matchedProducts.count == 1 ? "Matched Product" : "\(deal.matchedProducts.count) Matched Products")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(primary.formattedConfidence)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(confidenceColor)
            }

            VStack(spacing: 8) {
                ForEach(deal.matchedProducts) { p in
                    Button {
                        selectedProduct = DealProductSelection(
                            id: p.id, name: p.name,
                            imagePath: p.imagePath,
                            sellprice: p.sellprice
                        )
                    } label: {
                        HStack(spacing: 12) {
                            ProductImage(imagePath: p.imagePath, size: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                if let price = p.sellprice {
                                    Text(String(format: "%.2f \u{20AC}", price))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                stockBadges(for: p.id, compact: false)
                                if let ekLine = ekComparisonLine(for: p) {
                                    Text(ekLine).font(.caption2).foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(Int(p.confidence * 100))%")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(confidenceColor(for: p.confidence))
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
        }
    }

    // MARK: - Stock badges

    @ViewBuilder
    private func stockBadges(for productId: UUID, compact: Bool) -> some View {
        let totals = stockModel.totals[productId]
        HStack(spacing: 6) {
            stockBadge(
                icon: "building.2.fill",
                value: totals?.warehouseQty ?? 0,
                color: .blue,
                loaded: totals != nil,
                compact: compact
            )
            stockBadge(
                icon: "shippingbox.fill",
                value: totals?.trayStock ?? 0,
                capacity: totals?.trayCapacity,
                color: .green,
                loaded: totals != nil,
                compact: compact
            )
        }
    }

    private func stockBadge(
        icon: String,
        value: Int,
        capacity: Int? = nil,
        color: Color,
        loaded: Bool,
        compact: Bool
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(compact ? .system(size: 8) : .caption2)
            Group {
                if !loaded {
                    Text("—")
                } else if let capacity, capacity > 0 {
                    Text("\(value)/\(capacity)")
                } else {
                    Text("\(value)")
                }
            }
            .font((compact ? Font.system(size: 9) : Font.caption2).weight(.semibold))
            .monospacedDigit()
        }
        .foregroundStyle(value > 0 ? color : Color.secondary)
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(
            Capsule().fill((value > 0 ? color : Color.gray).opacity(0.12))
        )
    }

    // MARK: - External Links

    private var externalLinks: some View {
        VStack(spacing: 10) {
            if let urlString = primary.sourceUrl, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("View Prospekt", systemImage: "newspaper")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            if let urlString = primary.externalUrl, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("View All Offers", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private func ekComparisonLine(for p: DedupedDeal.MatchedProduct) -> String? {
        guard let summary = viewModel.ekSummaries[p.id], summary.ekCount > 0,
              let usual = summary.newestGross else { return nil }
        let dealGross = deal.primary.dealPrice ?? 0
        var line = String(format: String(localized: "Offer %.2f \u{20AC} vs usual cost %.2f \u{20AC}"), dealGross, usual)
        if let md = PurchaseComparison.marginDelta(sellpriceGross: p.sellprice, dealGross: dealGross, summary: summary) {
            line += " · " + String(format: String(localized: "Margin %.0f%% → %.0f%%"), md.currentPct, md.dealPct)
        }
        return line
    }

    private var confidenceColor: Color {
        confidenceColor(for: primary.confidence)
    }

    private func confidenceColor(for value: Double) -> Color {
        switch Deal.ConfidenceLevel(value: value) {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .orange
        }
    }

    private func validityColor(_ status: Deal.ValidityStatus) -> Color {
        switch status {
        case .upcoming: return .orange
        case .active: return .green
        case .expiring: return .orange
        case .expired: return .gray
        }
    }
}

// MARK: - Stock loader

/// Aggregates warehouse + machine-tray stock for a set of product ids so the
/// deal detail can show inline inventory next to each matched product. One
/// round-trip per table keeps this cheap even when a brand-wide deal matches
/// a dozen SKUs.
@MainActor
final class DealProductStockModel: ObservableObject {
    struct Totals: Equatable {
        var warehouseQty: Int = 0
        var trayStock: Int = 0
        var trayCapacity: Int = 0
    }

    @Published var totals: [UUID: Totals] = [:]

    private var client: SupabaseClient { SupabaseService.shared.client }

    func load(productIds: [UUID]) async {
        let missing = productIds.filter { totals[$0] == nil }
        guard !missing.isEmpty else { return }

        // Seed zero totals so the view stops showing the "not yet loaded"
        // placeholder for products that legitimately have no inventory.
        var next = totals
        for id in missing { next[id] = Totals() }

        let ids = missing.map { $0.uuidString }

        async let warehouseRows: [BatchRow] = (try? await client
            .from("warehouse_stock_batches")
            .select("product_id, quantity")
            .in("product_id", values: ids)
            .gt("quantity", value: 0)
            .execute()
            .value) ?? []

        async let trayRows: [TrayStockRow] = (try? await client
            .from("machine_trays")
            .select("product_id, current_stock, capacity")
            .in("product_id", values: ids)
            .execute()
            .value) ?? []

        let (wRows, tRows) = await (warehouseRows, trayRows)

        for row in wRows {
            guard let pid = row.productId else { continue }
            var t = next[pid] ?? Totals()
            t.warehouseQty += row.quantity
            next[pid] = t
        }
        for row in tRows {
            guard let pid = row.productId else { continue }
            var t = next[pid] ?? Totals()
            t.trayStock += row.currentStock
            t.trayCapacity += row.capacity
            next[pid] = t
        }

        totals = next
    }

    private struct BatchRow: Decodable {
        let productId: UUID?
        let quantity: Int

        enum CodingKeys: String, CodingKey {
            case productId = "product_id"
            case quantity
        }
    }

    private struct TrayStockRow: Decodable {
        let productId: UUID?
        let currentStock: Int
        let capacity: Int

        enum CodingKeys: String, CodingKey {
            case productId = "product_id"
            case currentStock = "current_stock"
            case capacity
        }
    }
}
