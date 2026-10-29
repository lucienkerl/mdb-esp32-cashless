import SwiftUI

/// Two-tab view for managing Products and Categories.
struct ProductsView: View {
    @StateObject private var viewModel = ProductsViewModel()
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                Text("Products").tag(0)
                Text("Categories").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if selectedTab == 0 {
                ProductsTabView(viewModel: viewModel)
            } else {
                CategoriesTabView(viewModel: viewModel)
            }
        }
        .navigationTitle("Products")
        .task {
            await viewModel.loadAll()
        }
        .alert("Error", isPresented: .constant(viewModel.error != nil)) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }
}

// MARK: - Products Tab

struct ProductsTabView: View {
    @ObservedObject var viewModel: ProductsViewModel
    @State private var showAddSheet = false
    @State private var detailProduct: Product?
    @State private var productPendingDelete: Product?

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.products.isEmpty {
                ProgressView("Loading products...")
                    .frame(maxHeight: .infinity)
            } else if viewModel.filteredProducts.isEmpty {
                emptyState
            } else {
                productList
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search products")
        .dataRefreshable {
            await viewModel.loadAll()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ProductEditSheet(
                product: nil,
                categories: viewModel.categories,
                viewModel: viewModel,
                onSave: { name, price, categoryId, discontinued in
                    return await viewModel.createProduct(name: name, sellprice: price, categoryId: categoryId, discontinued: discontinued)
                },
                onUploadImage: { productId, data in
                    await viewModel.uploadProductImage(productId: productId, imageData: data)
                },
                onDeleteImage: { productId, path in
                    await viewModel.deleteProductImage(productId: productId, imagePath: path)
                },
                onDelete: nil
            )
        }
        // Tapping a row always opens the stats sheet; editing lives behind the
        // pencil in that sheet's toolbar. It edits through its own view model,
        // so refresh the list on dismiss to pick up renames/deletions.
        .sheet(item: $detailProduct, onDismiss: {
            Task { await viewModel.loadAll() }
        }) { product in
            ProductDetailSheet(
                productId: product.id,
                fallbackName: product.name ?? "",
                fallbackImagePath: product.imagePath,
                fallbackSellprice: product.sellprice
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cube.box")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Products")
                .font(.title3.bold())
            Text("Add your first product to get started.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAddSheet = true
            } label: {
                Label("Add Product", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private var productList: some View {
        List {
            ForEach(viewModel.filteredProducts) { product in
                ProductRow(
                    product: product,
                    categoryName: viewModel.categoryName(for: product.category)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    detailProduct = product
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        productPendingDelete = product
                    } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .confirmationDialog(
            Text("Delete Product", comment: "Confirmation dialog title before deleting a product"),
            isPresented: Binding(
                get: { productPendingDelete != nil },
                set: { if !$0 { productPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", comment: "Confirm product deletion button"), role: .destructive) {
                if let product = productPendingDelete {
                    Task { await viewModel.deleteProduct(id: product.id) }
                }
                productPendingDelete = nil
            }
            Button(String(localized: "Cancel", comment: "Cancel product deletion button"), role: .cancel) {
                productPendingDelete = nil
            }
        } message: {
            if let product = productPendingDelete {
                Text(product.name ?? "")
            }
        }
    }
}

// MARK: - Product Row

struct ProductRow: View {
    let product: Product
    let categoryName: String?

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: product.imagePath, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(product.name ?? String(localized: "Unnamed"))
                        .font(.body)
                        .lineLimit(1)

                    if product.discontinued == true {
                        Image(systemName: "archivebox.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let catName = categoryName {
                    Text(catName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let price = product.sellprice {
                Text(String(format: "%.2f \u{20AC}", price))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Categories Tab

struct CategoriesTabView: View {
    @ObservedObject var viewModel: ProductsViewModel
    @State private var showAddAlert = false
    @State private var newCategoryName = ""
    @State private var selectedCategory: CategorySelection?
    @State private var categoryPendingDelete: ProductCategory?

    /// Navigation payload for pushing into a category's product list. `.unassigned`
    /// isn't backed by a real `product_category` row — it's a synthetic bucket for
    /// products with `category == nil`, purely so they're still browsable here.
    enum CategorySelection: Identifiable, Hashable {
        case category(ProductCategory)
        case unassigned
        var id: String {
            switch self {
            case .category(let c): return c.id.uuidString
            case .unassigned: return "unassigned"
            }
        }
    }

    var body: some View {
        Group {
            if viewModel.categories.isEmpty && !viewModel.isLoading {
                categoriesEmptyState
            } else {
                categoryList
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newCategoryName = ""
                    showAddAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New Category", isPresented: $showAddAlert) {
            TextField("Category name", text: $newCategoryName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                guard !newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                Task {
                    await viewModel.createCategory(name: newCategoryName.trimmingCharacters(in: .whitespaces))
                }
            }
        } message: {
            Text("Enter a name for the new category.")
        }
        .navigationDestination(item: $selectedCategory) { selection in
            CategoryProductsView(selection: selection, viewModel: viewModel)
        }
    }

    private var categoriesEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Categories")
                .font(.title3.bold())
            Text("Categories help you organize your products.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                newCategoryName = ""
                showAddAlert = true
            } label: {
                Label("Add Category", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    /// Products with no category, so they're still findable somewhere in this tab.
    private var unassignedCount: Int {
        viewModel.products.filter { $0.category == nil }.count
    }

    private var categoryList: some View {
        List {
            ForEach(viewModel.categories) { category in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(.body)
                        Text("\(viewModel.productCount(for: category.id)) products")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedCategory = .category(category)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        let count = viewModel.productCount(for: category.id)
                        if count > 0 {
                            viewModel.error = String(
                                localized: "\(category.name) has \(count) product(s). Remove products from this category first.",
                                comment: "Error shown when trying to delete a category that still has products assigned to it"
                            )
                        } else {
                            categoryPendingDelete = category
                        }
                    } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                }
            }

            if unassignedCount > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unassigned")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Text("\(unassignedCount) products")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedCategory = .unassigned
                }
            }
        }
        .listStyle(.plain)
        .confirmationDialog(
            Text("Delete Category", comment: "Confirmation dialog title before deleting a category"),
            isPresented: Binding(
                get: { categoryPendingDelete != nil },
                set: { if !$0 { categoryPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", comment: "Confirm category deletion button"), role: .destructive) {
                if let category = categoryPendingDelete {
                    Task { await viewModel.deleteCategory(id: category.id) }
                }
                categoryPendingDelete = nil
            }
            Button(String(localized: "Cancel", comment: "Cancel category deletion button"), role: .cancel) {
                categoryPendingDelete = nil
            }
        } message: {
            if let category = categoryPendingDelete {
                Text(category.name)
            }
        }
    }
}

// MARK: - Category Products (drill-down)

/// Products within one category (or the synthetic "Unassigned" bucket). Tapping
/// a product opens its stats, same as the Products tab. The pencil — only shown
/// for a real category — renames it; there's nothing to rename for "Unassigned".
private struct CategoryProductsView: View {
    let selection: CategoriesTabView.CategorySelection
    @ObservedObject var viewModel: ProductsViewModel
    @State private var detailProduct: Product?
    @State private var showEditAlert = false
    @State private var editName = ""

    /// Re-resolved from the live category list (not the value captured at
    /// navigation time) so a rename is reflected immediately in this view's
    /// own title and toolbar.
    private var category: ProductCategory? {
        guard case .category(let c) = selection else { return nil }
        return viewModel.categories.first { $0.id == c.id } ?? c
    }

    /// `Product.category` and `category?.id` are both `UUID?`, so this one
    /// comparison covers both a real category (matches its id) and Unassigned
    /// (category is nil, matches products whose category is also nil).
    private var products: [Product] {
        viewModel.products.filter { $0.category == category?.id }
    }

    var body: some View {
        Group {
            if products.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "cube.box")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Products")
                        .font(.title3.bold())
                    Spacer()
                }
                .padding()
            } else {
                List {
                    ForEach(products) { product in
                        ProductRow(product: product, categoryName: nil)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                detailProduct = product
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(category?.name ?? String(localized: "Unassigned"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let category {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editName = category.name
                        showEditAlert = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel(String(localized: "Edit Category"))
                }
            }
        }
        .alert(String(localized: "Edit Category"), isPresented: $showEditAlert) {
            TextField(String(localized: "Category name"), text: $editName)
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Save")) {
                guard let category else { return }
                let trimmed = editName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                Task { await viewModel.updateCategory(id: category.id, name: trimmed) }
            }
        } message: {
            Text(String(localized: "Update the category name."))
        }
        .sheet(item: $detailProduct, onDismiss: {
            Task { await viewModel.loadAll() }
        }) { product in
            ProductDetailSheet(
                productId: product.id,
                fallbackName: product.name ?? "",
                fallbackImagePath: product.imagePath,
                fallbackSellprice: product.sellprice
            )
        }
    }
}

#Preview {
    NavigationStack {
        ProductsView()
    }
}
