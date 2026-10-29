import SwiftUI

// MARK: - Slot Badge Label

/// Format a list of slot numbers into a compact pill label.
///
/// - 1 slot: `"Slot 3"`
/// - 2–3 slots: `"Slot 3, 7"` / `"Slot 3, 7, 9"`
/// - 4+ slots: `"Slot 3, 7, 9 +2"` — first three + remainder count
///
/// The input is sorted ascending before rendering, so callers don't have to
/// pre-sort. Returns an empty string for an empty input; callers should
/// treat that as "no pill".
func slotBadgeLabel(_ slots: [Int]) -> String {
    let sorted = slots.sorted()
    guard !sorted.isEmpty else { return "" }
    if sorted.count <= 3 {
        return String(localized: "Slot \(sorted.map(String.init).joined(separator: ", "))")
    }
    let first = sorted.prefix(3).map(String.init).joined(separator: ", ")
    let extra = sorted.count - 3
    return String(localized: "Slot \(first) +\(extra)")
}

// MARK: - Replacement Product Picker

struct ReplacementProductPicker: View {
    let products: [Product]
    let selectedProductId: UUID?
    let existingSlotsByProduct: [UUID: [Int]]
    let machineLayout: MachineGridLayout
    /// Item/slot number of the tray being replaced, shown in the capacity
    /// callout. `nil` suppresses the slot number (capacity still shown).
    var targetSlotNumber: Int? = nil
    /// Capacity (number of units the spiral holds) of the tray being
    /// replaced. When non-nil, a callout is shown above the list so the
    /// user can judge whether a candidate product physically fits the
    /// current spiral size. `nil` hides the callout entirely.
    var targetSlotCapacity: Int? = nil
    /// Remaining warehouse stock for the given product, or `nil` when the
    /// caller has no warehouse context (e.g. previews, or no warehouse
    /// selected in the refill wizard). When non-nil the row shows a
    /// stock-count pill; a value of `0` additionally fades the row to mark
    /// it as a poor replacement candidate.
    var remainingStock: (UUID) -> Int? = { _ in nil }
    /// Category UUID of the product currently in the tray being replaced.
    /// `nil` if the tray is unassigned or the current product is uncategorized.
    /// When non-nil, that category is rendered first in each stock bucket.
    var currentCategoryId: UUID? = nil
    /// Category catalogue for name lookup. Empty array is valid — uncategorized
    /// products will still render; products whose `category` UUID is not
    /// present in the array fall back to the "Uncategorized" group.
    var categories: [ProductCategory] = []
    /// Products taken out of this machine within the cool-down, by product
    /// id. They stay pickable but are marked with the removal date and what
    /// they sold back then, and sort last in their group.
    var recentRemovals: [UUID: RecentRemoval] = [:]
    let onSelect: (UUID) -> Void

    @State private var searchText = ""
    @State private var highlightedProductId: UUID?

    // MARK: - Grouping types

    /// Top-level grouping by warehouse stock status.
    private enum StockStatus: String {
        case inStock
        case outOfStock
    }

    /// One stock bucket containing zero or more category groups.
    private struct StockBucket: Identifiable {
        let status: StockStatus
        let categories: [CategoryGroup]
        var id: String { status.rawValue }
        /// Total product count across all categories — shown in the mega-header.
        var totalCount: Int { categories.reduce(0) { $0 + $1.products.count } }
    }

    /// One category's products inside a stock bucket. `category == nil`
    /// represents the "Uncategorized" group rendered at the end.
    private struct CategoryGroup: Identifiable {
        let category: ProductCategory?
        let isCurrent: Bool
        let products: [Product]
        var id: String { category?.id.uuidString ?? "uncategorized" }
    }

    private func fuzzyMatch(query: String, target: String) -> Int? {
        var score = 0
        var targetIdx = target.startIndex
        var lastMatchIdx: String.Index?

        for ch in query {
            guard let found = target[targetIdx...].firstIndex(of: ch) else { return nil }
            let distance = target.distance(from: targetIdx, to: found)
            if lastMatchIdx != nil { score += distance }
            if lastMatchIdx == nil { score += distance }
            lastMatchIdx = found
            targetIdx = target.index(after: found)
        }
        return score
    }

    // MARK: - Stock buckets pipeline

    /// Visible product structure for the picker body. Computed on every
    /// re-render — depends only on `searchText`, `products`, `remainingStock`,
    /// `existingSlotsByProduct`, `currentCategoryId`, and `categories`. Pure,
    /// no side effects.
    ///
    /// Pipeline:
    /// 1. Filter by search (existing fuzzyMatch, keep score)
    /// 2. Partition by stock (nil or >0 = inStock, ==0 = outOfStock)
    /// 3. Group by category within each bucket (current first, others A-Z, uncategorized last)
    /// 4. Sort within each (stock × category) group: not-in-machine first,
    ///    already-in-machine next, recently removed last, then fuzzy score
    ///    (search-active only), then alphabetical
    private var stockBuckets: [StockBucket] {
        // Step 1: filter by search
        let scored: [(Product, Int?)]
        if searchText.isEmpty {
            scored = products.map { ($0, nil) }
        } else {
            let query = searchText.lowercased()
            scored = products.compactMap { product -> (Product, Int?)? in
                guard let name = product.name?.lowercased() else { return nil }
                guard let s = fuzzyMatch(query: query, target: name) else { return nil }
                return (product, s)
            }
        }

        // Step 2: partition by stock
        var inStock: [(Product, Int?)] = []
        var outOfStock: [(Product, Int?)] = []
        for entry in scored {
            if remainingStock(entry.0.id) == 0 {
                outOfStock.append(entry)
            } else {
                inStock.append(entry)
            }
        }

        // Step 3+4 for each bucket
        let inStockGroups = groupByCategory(inStock)
        let outOfStockGroups = groupByCategory(outOfStock)

        return [
            StockBucket(status: .inStock, categories: inStockGroups),
            StockBucket(status: .outOfStock, categories: outOfStockGroups)
        ].filter { !$0.categories.isEmpty }
    }

    /// Group a stock-bucket's products by category, sort categories
    /// (current → alphabetical → uncategorized), and sort products within
    /// each category. Pure function.
    private func groupByCategory(_ scored: [(Product, Int?)]) -> [CategoryGroup] {
        // Index categories by UUID for fast name lookup. `reduce(into:)`
        // is crash-safe if `categories` ever contains duplicate IDs (later
        // value wins) — unlike `Dictionary(uniqueKeysWithValues:)` which
        // traps at runtime.
        let categoryById: [UUID: ProductCategory] = categories.reduce(into: [:]) {
            $0[$1.id] = $1
        }

        // Bucket products by category UUID; nil category → uncategorized bucket
        var byCategoryId: [UUID?: [(Product, Int?)]] = [:]
        for entry in scored {
            let key = entry.0.category
            byCategoryId[key, default: []].append(entry)
        }

        // Sort products within each category bucket using the multi-key sort:
        // (placement rank, fuzzyScore?, alphabetical). Rank: 0 = not in the
        // machine, 1 = already in another slot, 2 = recently removed from it.
        func sortKey(_ entry: (Product, Int?)) -> (Int, Int, String) {
            let rank: Int
            if recentRemovals[entry.0.id] != nil {
                rank = 2
            } else if existingSlotsByProduct[entry.0.id]?.isEmpty == false {
                rank = 1
            } else {
                rank = 0
            }
            let score = entry.1 ?? 0
            let name = entry.0.name ?? ""
            // Treat empty/nil name as last by prepending a high-codepoint marker
            let nameKey = name.isEmpty ? "\u{FFFF}" : name.lowercased()
            return (rank, score, nameKey)
        }
        for key in byCategoryId.keys {
            byCategoryId[key]?.sort { a, b in
                let ka = sortKey(a)
                let kb = sortKey(b)
                if ka.0 != kb.0 { return ka.0 < kb.0 }
                if ka.1 != kb.1 { return ka.1 < kb.1 }
                return ka.2.localizedCaseInsensitiveCompare(kb.2) == .orderedAscending
            }
        }

        // Build CategoryGroup list with ordering: current → A-Z → uncategorized last
        var orderedGroups: [CategoryGroup] = []

        // 1. Current category (if any and has products)
        if let curId = currentCategoryId,
           let curCat = categoryById[curId],
           let entries = byCategoryId[curId], !entries.isEmpty {
            orderedGroups.append(
                CategoryGroup(category: curCat, isCurrent: true, products: entries.map(\.0))
            )
        }

        // 2. Other named categories alphabetically
        let otherCategoryIds = byCategoryId.keys
            .compactMap { $0 } // drop the nil key (uncategorized)
            .filter { $0 != currentCategoryId }
        let sortedOthers = otherCategoryIds
            .compactMap { id -> (UUID, ProductCategory)? in
                guard let cat = categoryById[id] else { return nil }
                return (id, cat)
            }
            .sorted { $0.1.name.localizedCaseInsensitiveCompare($1.1.name) == .orderedAscending }
        for (id, cat) in sortedOthers {
            guard let entries = byCategoryId[id], !entries.isEmpty else { continue }
            orderedGroups.append(
                CategoryGroup(category: cat, isCurrent: false, products: entries.map(\.0))
            )
        }

        // 3. Unknown-category-UUID products: products whose category UUID was
        //    set but doesn't exist in `categories`. Fold into the uncategorized
        //    bucket as a safe fallback. We deliberately DON'T filter out
        //    `k == currentCategoryId` here — if the current product's category
        //    UUID also isn't in the catalogue (rare race), those products
        //    would otherwise be dropped entirely. They land in uncategorized.
        let unknownCategoryEntries: [(Product, Int?)] = byCategoryId
            .filter { key, _ in
                guard let k = key else { return false }
                return categoryById[k] == nil
            }
            .flatMap { $0.value }

        #if DEBUG
        if !unknownCategoryEntries.isEmpty {
            let ids = Set(unknownCategoryEntries.compactMap { $0.0.category })
            print("[RefillWizard] unknown category UUID(s) in picker: \(ids)")
        }
        #endif

        // 4. Uncategorized group (nil category) + any unknown-category fallback
        var uncategorizedEntries: [(Product, Int?)] = byCategoryId[nil] ?? []
        uncategorizedEntries.append(contentsOf: unknownCategoryEntries)
        if !uncategorizedEntries.isEmpty {
            // Re-sort the merged uncategorized bucket
            uncategorizedEntries.sort { a, b in
                let ka = sortKey(a)
                let kb = sortKey(b)
                if ka.0 != kb.0 { return ka.0 < kb.0 }
                if ka.1 != kb.1 { return ka.1 < kb.1 }
                return ka.2.localizedCaseInsensitiveCompare(kb.2) == .orderedAscending
            }
            orderedGroups.append(
                CategoryGroup(category: nil, isCurrent: false, products: uncategorizedEntries.map(\.0))
            )
        }

        return orderedGroups
    }

    // MARK: - Header row helpers

    /// Mega-header rendered above an entire stock bucket. Only shown when
    /// both `stockBuckets` are present (i.e. some products are in stock AND
    /// some are out of stock). With only one bucket, the mega-header is
    /// suppressed and category sub-headers stand alone.
    @ViewBuilder
    private func stockMegaHeader(_ bucket: StockBucket) -> some View {
        let title: String = {
            switch bucket.status {
            case .inStock: return String(localized: "In Stock")
            case .outOfStock: return String(localized: "Out of Stock")
            }
        }()

        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(bucket.totalCount)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color(.systemGroupedBackground))
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(title), " + String(localized: "\(bucket.totalCount) product")
        )
        .accessibilityAddTraits(.isHeader)
    }

    /// Sub-header for one category within a stock bucket. Highlights the
    /// current category with accent color and an "· aktuell" suffix.
    @ViewBuilder
    private func categorySubHeader(_ group: CategoryGroup) -> some View {
        let name: String = group.category?.name ?? String(localized: "Uncategorized")
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(group.isCurrent ? Color.accentColor : .secondary)
            if group.isCurrent {
                Text(verbatim: "· ")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(String(localized: "current"))
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.lowercase)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.isCurrent ? String(localized: "\(name), current category") : name)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func stockPill(_ count: Int) -> some View {
        let isZero = count <= 0
        Text("\(count) in stock")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(isZero ? Color.gray.opacity(0.18) : Color.blue.opacity(0.15)))
            .foregroundStyle(isZero ? Color.secondary : Color.blue)
            .accessibilityLabel(
                isZero
                    ? String(localized: "Out of warehouse stock")
                    : String(localized: "\(count) units in warehouse stock")
            )
    }

    /// Callout above the list showing the target slot's capacity, so the
    /// user can gauge whether a candidate product fits the current spiral.
    @ViewBuilder
    private func capacityCallout(_ capacity: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                if let slot = targetSlotNumber {
                    Text("Slot \(slot) · holds \(capacity)")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text("Slot capacity: \(capacity)")
                        .font(.subheadline.weight(.semibold))
                }
                Text("Choose a product that fits this spiral size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Red pill plus a caption: "Removed 10 Oct 2026" / "3 sold in 14 days".
    @ViewBuilder
    private func removalInfo(_ removal: RecentRemoval) -> some View {
        let date = removal.removedAt.formatted(date: .abbreviated, time: .omitted)
        VStack(alignment: .leading, spacing: 2) {
            Text("Removed \(date)")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.15)))
                .foregroundStyle(.red)
            Group {
                if let days = removal.daysOffered {
                    Text("\(removal.unitsSold) sold in \(days) days")
                } else {
                    Text("\(removal.unitsSold) sold")
                }
            }
            .font(.caption2)
            .foregroundStyle(.red)
        }
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let capacity = targetSlotCapacity {
                    Section {
                        capacityCallout(capacity)
                    }
                }

                if machineLayout.rowCount > 0 {
                    Section(header: Text("Machine Layout").textCase(nil)) {
                        MachineLayoutGrid(layout: machineLayout) { tappedSlot in
                            handleGridTap(slot: tappedSlot, proxy: proxy)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }

                let buckets = stockBuckets
                let showMegaHeaders = buckets.count > 1

                Section {
                    if buckets.isEmpty, !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(buckets) { bucket in
                        if showMegaHeaders {
                            stockMegaHeader(bucket)
                        }
                        ForEach(bucket.categories) { group in
                            categorySubHeader(group)
                            ForEach(Array(group.products.enumerated()), id: \.element.id) { idx, product in
                                productRow(
                                    product: product,
                                    isLastInGroup: idx == group.products.count - 1
                                )
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search products")
            .navigationTitle("Select Replacement")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func handleGridTap(slot: MachineGridSlot, proxy: ScrollViewProxy) {
        guard let productId = slot.productId, !slot.isTarget else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(productId, anchor: .center)
        }
        highlightedProductId = productId
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if highlightedProductId == productId {
                withAnimation(.easeOut(duration: 0.4)) {
                    highlightedProductId = nil
                }
            }
        }
    }

    @ViewBuilder
    private func productRow(product: Product, isLastInGroup: Bool) -> some View {
        let stock = remainingStock(product.id)
        let outOfStock = stock == 0
        Button {
            onSelect(product.id)
        } label: {
            HStack(spacing: 12) {
                ProductImage(imagePath: product.imagePath, size: 36)
                    .opacity(outOfStock ? 0.45 : 1.0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name ?? String(localized: "Unnamed"))
                        .foregroundStyle(outOfStock ? .secondary : .primary)
                    if let removal = recentRemovals[product.id] {
                        removalInfo(removal)
                    }
                }
                if let stock {
                    stockPill(stock)
                }
                if let slots = existingSlotsByProduct[product.id], !slots.isEmpty {
                    Text(slotBadgeLabel(slots))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                        .accessibilityLabel(slots.count == 1
                            ? String(localized: "Already in slot \(slots.sorted().map(String.init).joined(separator: ", "))")
                            : String(localized: "Already in slots \(slots.sorted().map(String.init).joined(separator: ", "))"))
                }
                Spacer()
                if selectedProductId == product.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
        .id(product.id)
        .listRowBackground(
            highlightedProductId == product.id
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
        .listRowSeparator(isLastInGroup ? .hidden : .visible, edges: .bottom)
    }
}

// MARK: - Previews

#Preview("Picker with existing slots") {
    let sampleProducts: [Product] = (1...8).map { i in
        Product(
            id: UUID(),
            name: "Product \(i)",
            imagePath: nil,
            discontinued: false,
            sellprice: 2.50,
            category: nil
        )
    }

    // 1 slot, 3 slots, 6 slots — verify pill formatting at each threshold.
    let slots: [UUID: [Int]] = [
        sampleProducts[0].id: [3],
        sampleProducts[1].id: [1, 5, 9],
        sampleProducts[2].id: [2, 4, 6, 8, 10, 12],
    ]

    return NavigationStack {
        ReplacementProductPicker(
            products: sampleProducts,
            selectedProductId: nil,
            existingSlotsByProduct: slots,
            machineLayout: MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: []),
            onSelect: { _ in }
        )
    }
}

#Preview("Picker with grid (typical)") {
    let targetTrayId = UUID()
    let layout = MachineGridLayout(
        rowCount: 3,
        columnsPerRow: 10,
        slots: [
            MachineGridSlot(id: UUID(), itemNumber: 10, row: 0, column: 0, width: 2,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: UUID(), itemNumber: 12, row: 0, column: 2, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: targetTrayId, itemNumber: 15, row: 0, column: 5, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: true),
            MachineGridSlot(id: UUID(), itemNumber: 20, row: 1, column: 0, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: UUID(), itemNumber: 30, row: 2, column: 0, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
        ]
    )

    let products: [Product] = (1...12).map { i in
        Product(
            id: UUID(),
            name: "Product \(i)",
            imagePath: nil,
            discontinued: false,
            sellprice: 2.50,
            category: nil
        )
    }

    return NavigationStack {
        ReplacementProductPicker(
            products: products,
            selectedProductId: nil,
            existingSlotsByProduct: [:],
            machineLayout: layout,
            onSelect: { _ in }
        )
    }
}

#Preview("Picker with grouping (typical)") {
    let snacksId = UUID()
    let drinksId = UUID()
    let sweetsId = UUID()

    let categories: [ProductCategory] = [
        ProductCategory(id: snacksId, name: "Snacks", company: UUID()),
        ProductCategory(id: drinksId, name: "Drinks", company: UUID()),
        ProductCategory(id: sweetsId, name: "Sweets", company: UUID()),
    ]

    let mars = Product(id: UUID(), name: "Mars",
                       imagePath: nil, discontinued: false, sellprice: 2.5,
                       category: snacksId)
    let bounty = Product(id: UUID(), name: "Bounty",
                         imagePath: nil, discontinued: false, sellprice: 2.5,
                         category: snacksId)
    let kitkat = Product(id: UUID(), name: "Kitkat",
                         imagePath: nil, discontinued: false, sellprice: 2.5,
                         category: snacksId)
    let twix = Product(id: UUID(), name: "Twix",
                       imagePath: nil, discontinued: false, sellprice: 2.5,
                       category: snacksId)
    let snickers = Product(id: UUID(), name: "Snickers",
                           imagePath: nil, discontinued: false, sellprice: 2.5,
                           category: snacksId)
    let fanta = Product(id: UUID(), name: "Fanta",
                        imagePath: nil, discontinued: false, sellprice: 2.5,
                        category: drinksId)
    let cola = Product(id: UUID(), name: "Cola",
                       imagePath: nil, discontinued: false, sellprice: 2.5,
                       category: drinksId)
    let gummy = Product(id: UUID(), name: "Gummy Bears",
                        imagePath: nil, discontinued: false, sellprice: 2.5,
                        category: sweetsId)

    let products = [mars, bounty, kitkat, twix, snickers, fanta, cola, gummy]

    // Stock map: snickers + fanta are out of stock.
    let stockMap: [UUID: Int] = [
        mars.id: 12,
        bounty.id: 15,
        kitkat.id: 4,
        twix.id: 8,
        snickers.id: 0,
        fanta.id: 0,
        cola.id: 10,
        gummy.id: 3,
    ]

    // Twix is already in slot 23, Cola in slot 31.
    let existing: [UUID: [Int]] = [
        twix.id: [23],
        cola.id: [31],
    ]

    return NavigationStack {
        ReplacementProductPicker(
            products: products,
            selectedProductId: nil,
            existingSlotsByProduct: existing,
            machineLayout: MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: []),
            remainingStock: { stockMap[$0] },
            currentCategoryId: snacksId,
            categories: categories,
            onSelect: { _ in }
        )
    }
}
