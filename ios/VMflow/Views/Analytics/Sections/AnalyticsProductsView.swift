// ios/VMflow/Views/Analytics/Sections/AnalyticsProductsView.swift
import SwiftUI

struct AnalyticsProductsView: View {
    @EnvironmentObject var filter: AnalyticsFilter
    @StateObject private var viewModel = AnalyticsProductsViewModel()
    @StateObject private var productsVM = ProductsViewModel()

    @State private var searchTerm = ""
    @State private var selectedStatuses: Set<String> = []
    @State private var slowOnly = false
    @State private var selectedCategoryIds: Set<UUID> = []
    @State private var selectedProduct: AnalyticsProductsData.ProductRow?

    private let statuses = ["active", "slow", "dead", "discontinued"]

    private var filteredRows: [AnalyticsProductsData.ProductRow] {
        var rows = viewModel.data?.products ?? []

        let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let q = trimmed.lowercased()
            rows = rows.filter { $0.name.lowercased().contains(q) }
        }
        if !selectedStatuses.isEmpty {
            rows = rows.filter { selectedStatuses.contains($0.status) }
        }
        if slowOnly {
            rows = rows.filter { $0.status == "slow" }
        }
        if !selectedCategoryIds.isEmpty {
            rows = rows.filter { row in
                guard let cid = row.categoryId else { return false }
                return selectedCategoryIds.contains(cid)
            }
        }
        return rows.sorted { $0.revenue > $1.revenue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.isLoading && viewModel.data == nil {
                    ProgressView().padding()
                } else if let error = viewModel.error {
                    Text(error).foregroundStyle(.red).padding()
                }

                if let data = viewModel.data {
                    AnalyticsKPIGroup(kpis: [
                        AnalyticsKPI(
                            label: "Active",
                            value: Double(data.kpis.activeCount),
                            format: .number,
                            icon: "cube.box.fill",
                            color: .green
                        ),
                        AnalyticsKPI(
                            label: "Slow movers",
                            value: Double(data.kpis.slowMoverCount),
                            format: .number,
                            icon: "tortoise.fill",
                            color: .yellow
                        ),
                        AnalyticsKPI(
                            label: "Discontinued",
                            value: Double(data.kpis.discontinuedCount),
                            format: .number,
                            icon: "xmark.circle.fill",
                            color: .gray
                        ),
                        AnalyticsKPI(
                            label: "Categories",
                            value: Double(data.kpis.categoriesWithSales),
                            format: .number,
                            icon: "tag.fill",
                            color: .blue
                        )
                    ])

                    // Status filter pills + slow-only toggle
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(statuses, id: \.self) { status in
                                    Button {
                                        if selectedStatuses.contains(status) {
                                            selectedStatuses.remove(status)
                                        } else {
                                            selectedStatuses.insert(status)
                                        }
                                    } label: {
                                        Text(LocalizedStringKey(status.capitalized))
                                            .font(.subheadline)
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(selectedStatuses.contains(status) ? Color.accentColor.opacity(0.2) : Color.clear)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(selectedStatuses.contains(status) ? Color.accentColor : .primary)
                                }
                            }
                            .padding(.horizontal)
                        }
                        Toggle("Slow movers only", isOn: $slowOnly)
                            .padding(.horizontal)
                            .font(.subheadline)
                    }

                    // Product cards
                    LazyVStack(spacing: 8) {
                        ForEach(filteredRows) { row in
                            Button {
                                selectedProduct = row
                            } label: {
                                productCard(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)

                    if filteredRows.isEmpty {
                        Text("No products match the filter")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }
            .padding(.vertical)
        }
        .searchable(text: $searchTerm, prompt: "Search products")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Category") {
                        if productsVM.categories.isEmpty {
                            Text("No categories")
                        } else {
                            ForEach(productsVM.categories) { cat in
                                Button {
                                    if selectedCategoryIds.contains(cat.id) {
                                        selectedCategoryIds.remove(cat.id)
                                    } else {
                                        selectedCategoryIds.insert(cat.id)
                                    }
                                } label: {
                                    // cat.name is user-generated content, do not localize.
                                    if selectedCategoryIds.contains(cat.id) {
                                        Label { Text(cat.name) } icon: { Image(systemName: "checkmark") }
                                    } else {
                                        Text(cat.name)
                                    }
                                }
                            }
                        }
                    }
                    Section("Status") {
                        ForEach(statuses, id: \.self) { status in
                            Button {
                                if selectedStatuses.contains(status) {
                                    selectedStatuses.remove(status)
                                } else {
                                    selectedStatuses.insert(status)
                                }
                            } label: {
                                if selectedStatuses.contains(status) {
                                    Label {
                                        Text(LocalizedStringKey(status.capitalized))
                                    } icon: {
                                        Image(systemName: "checkmark")
                                    }
                                } else {
                                    Text(LocalizedStringKey(status.capitalized))
                                }
                            }
                        }
                    }
                    if !selectedCategoryIds.isEmpty || !selectedStatuses.isEmpty || slowOnly {
                        Section {
                            Button(role: .destructive) {
                                selectedCategoryIds.removeAll()
                                selectedStatuses.removeAll()
                                slowOnly = false
                            } label: {
                                Label("Clear sub-filters", systemImage: "xmark.circle")
                            }
                        }
                    }
                } label: {
                    Image(systemName: hasSubFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .refreshable { await viewModel.load() }
        .task {
            viewModel.bind(filter: filter)
            async let load: () = viewModel.load()
            async let cats: () = productsVM.loadCategories()
            _ = await (load, cats)
        }
        .sheet(item: $selectedProduct) { product in
            ProductDetailSheet(
                productId: product.id,
                fallbackName: product.name,
                fallbackImagePath: product.imagePath,
                fallbackSellprice: nil
            )
        }
    }

    private var hasSubFilters: Bool {
        !selectedCategoryIds.isEmpty || !selectedStatuses.isEmpty || slowOnly
    }

    @ViewBuilder
    private func productCard(row: AnalyticsProductsData.ProductRow) -> some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: row.imagePath, size: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(row.status.capitalized))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(statusColor(row.status).opacity(0.15))
                        .foregroundStyle(statusColor(row.status))
                        .clipShape(Capsule())
                    Text("\(row.units) units")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f/day", row.velocity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.revenue.formatted(.currency(code: "EUR")))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Text(String(format: "%.1f%%", row.mixPct))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "active":       return .green
        case "slow":         return .yellow
        case "dead":         return .red
        case "discontinued": return .gray
        default:             return .gray
        }
    }
}
