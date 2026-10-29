import SwiftUI

/// Bottom sheet for editing a tray's configuration: slot number, product, capacity, stock, thresholds.
struct TrayEditSheet: View {
    let machineId: UUID
    let tray: Tray?  // nil = creating new tray
    let products: [Product]
    let onSave: (Int, UUID?, Int, Int, Int, Int) async -> Void
    let onDelete: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var slotNumber: Int
    @State private var selectedProductId: UUID?
    @State private var capacity: Int
    @State private var currentStock: Int
    @State private var minStock: Int
    @State private var fillWhenBelow: Int
    @State private var isSaving = false
    @State private var showDeleteConfirm = false

    init(
        machineId: UUID,
        tray: Tray?,
        products: [Product],
        onSave: @escaping (Int, UUID?, Int, Int, Int, Int) async -> Void,
        onDelete: (() async -> Void)? = nil
    ) {
        self.machineId = machineId
        self.tray = tray
        self.products = products
        self.onSave = onSave
        self.onDelete = onDelete

        _slotNumber = State(initialValue: tray?.itemNumber ?? 1)
        _selectedProductId = State(initialValue: tray?.productId)
        _capacity = State(initialValue: tray?.capacity ?? 10)
        _currentStock = State(initialValue: tray?.currentStock ?? 0)
        _minStock = State(initialValue: tray?.minStock ?? 0)
        _fillWhenBelow = State(initialValue: tray?.fillWhenBelow ?? 0)
    }

    var isNew: Bool { tray == nil }

    var body: some View {
        NavigationStack {
            Form {
                // Slot Number
                Section("Slot") {
                    LabeledStepperField(label: "Slot Number", value: $slotNumber, range: 0...999)
                }

                // Product
                Section("Product") {
                    NavigationLink {
                        ProductPickerView(
                            products: products,
                            selectedProductId: $selectedProductId
                        )
                    } label: {
                        HStack {
                            Text("Product")
                            Spacer()
                            if let id = selectedProductId,
                               let product = products.first(where: { $0.id == id }) {
                                ProductImage(imagePath: product.imagePath, size: 28)
                                Text(product.name ?? String(localized: "Unnamed"))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("None")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Capacity & Stock
                Section("Stock") {
                    LabeledStepperField(label: "Capacity", value: $capacity, range: 1...999)
                    LabeledStepperField(label: "Current Stock", value: $currentStock, range: 0...capacity)
                    StockBar(
                        current: currentStock,
                        capacity: capacity,
                        height: 10,
                        minStock: minStock,
                        fillWhenBelow: fillWhenBelow
                    )
                    .padding(.vertical, 4)
                    if minStock > 0 || fillWhenBelow > 0 {
                        HStack(spacing: 12) {
                            if minStock > 0 {
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.orange)
                                        .frame(width: 10, height: 3)
                                    Text("Min Stock")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if fillWhenBelow > 0 {
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.blue)
                                        .frame(width: 10, height: 3)
                                    Text("Fill Below")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Thresholds
                Section("Thresholds") {
                    LabeledStepperField(label: "Min Stock", value: $minStock, range: 0...capacity)
                    LabeledStepperField(label: "Fill When Below", value: $fillWhenBelow, range: 0...capacity)
                }

                // Delete
                if !isNew, let onDelete {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("Delete Tray", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Tray" : "Edit Tray \(slotNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await onSave(slotNumber, selectedProductId, capacity, currentStock, minStock, fillWhenBelow)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .confirmationDialog("Delete Tray", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await onDelete?()
                        dismiss()
                    }
                }
            } message: {
                Text("Are you sure you want to delete slot \(slotNumber)?")
            }
        }
    }
}

// MARK: - Batch Add Sheet

/// Sheet for batch-adding sequential tray slots.
struct BatchAddTraySheet: View {
    let machineId: UUID
    let onSave: (Int, Int, Int) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var startSlot = 1
    @State private var count = 5
    @State private var capacity = 10
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Range") {
                    LabeledStepperField(label: "Start Slot", value: $startSlot, range: 0...999)
                    LabeledStepperField(label: "Number of Slots", value: $count, range: 1...50)

                    Text("Will create slots \(startSlot) through \(startSlot + count - 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Default Settings") {
                    LabeledStepperField(label: "Capacity", value: $capacity, range: 1...999)
                }
            }
            .navigationTitle("Batch Add Trays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(count) Trays") {
                        isSaving = true
                        Task {
                            await onSave(startSlot, count, capacity)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

// MARK: - Product Picker

/// Full-screen picker for selecting a product with fuzzy search.
struct ProductPickerView: View {
    let products: [Product]
    @Binding var selectedProductId: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    /// Fuzzy-filtered products: matches if every character of the query appears in order in the name.
    private var filteredProducts: [Product] {
        guard !searchText.isEmpty else { return products }
        let query = searchText.lowercased()
        return products
            .compactMap { product -> (Product, Int)? in
                guard let name = product.name?.lowercased() else { return nil }
                if let score = fuzzyMatch(query: query, target: name) {
                    return (product, score)
                }
                return nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Returns a match score (lower = better) if query fuzzy-matches target, nil otherwise.
    /// Each character of query must appear in target in order. Score favours consecutive and early matches.
    private func fuzzyMatch(query: String, target: String) -> Int? {
        var score = 0
        var targetIdx = target.startIndex
        var lastMatchIdx: String.Index?

        for ch in query {
            guard let found = target[targetIdx...].firstIndex(of: ch) else { return nil }
            let distance = target.distance(from: targetIdx, to: found)
            // Penalise gaps between matched characters
            if lastMatchIdx != nil { score += distance }
            // Bonus: no penalty for match at very start of string
            if lastMatchIdx == nil { score += distance }
            lastMatchIdx = found
            targetIdx = target.index(after: found)
        }
        return score
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Button {
                    selectedProductId = nil
                    dismiss()
                } label: {
                    HStack {
                        Text("None")
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedProductId == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }

            ForEach(filteredProducts) { product in
                Button {
                    selectedProductId = product.id
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        ProductImage(imagePath: product.imagePath, size: 36)
                        Text(product.name ?? String(localized: "Unnamed"))
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedProductId == product.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }

            if !searchText.isEmpty && filteredProducts.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            }
        }
        .searchable(text: $searchText, prompt: "Search products")
        .navigationTitle("Select Product")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    TrayEditSheet(
        machineId: UUID(),
        tray: nil,
        products: [],
        onSave: { _, _, _, _, _, _ in }
    )
}
