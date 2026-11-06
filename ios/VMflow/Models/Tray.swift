import Foundation

/// Machine tray/slot configuration. Maps to the `machine_trays` table.
/// Includes nested `products(...)` relation data.
struct Tray: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let machineId: UUID
    let itemNumber: Int
    let productId: UUID?
    let capacity: Int
    let currentStock: Int
    let minStock: Int
    let fillWhenBelow: Int
    let products: TrayProduct?

    enum CodingKeys: String, CodingKey {
        case id, capacity, products
        case machineId = "machine_id"
        case itemNumber = "item_number"
        case productId = "product_id"
        case currentStock = "current_stock"
        case minStock = "min_stock"
        case fillWhenBelow = "fill_when_below"
    }

    init(id: UUID, machineId: UUID, itemNumber: Int, productId: UUID?, capacity: Int, currentStock: Int, minStock: Int, fillWhenBelow: Int, products: TrayProduct?) {
        self.id = id
        self.machineId = machineId
        self.itemNumber = itemNumber
        self.productId = productId
        self.capacity = capacity
        self.currentStock = currentStock
        self.minStock = minStock
        self.fillWhenBelow = fillWhenBelow
        self.products = products
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Product display name, falling back to the slot number.
    var productName: String {
        products?.name ?? String(localized: "Slot \(itemNumber)")
    }

    /// Whether the product assigned to this tray is discontinued.
    var isDiscontinued: Bool {
        products?.discontinued ?? false
    }

    /// Product sell price (EUR), formatted for display. `nil` when no product
    /// is assigned or the product has no price set.
    var formattedSellprice: String? {
        guard let price = products?.sellprice else { return nil }
        return String(format: "%.2f \u{20AC}", price)
    }

    /// Stock fill ratio (0.0 to 1.0).
    var fillRatio: Double {
        guard capacity > 0 else { return 0 }
        return Double(currentStock) / Double(capacity)
    }

    /// How many units are needed to fill to capacity.
    var deficit: Int {
        max(0, capacity - currentStock)
    }

    /// Whether this tray is empty.
    var isEmpty: Bool {
        currentStock == 0
    }

    /// Whether stock is at or below min_stock threshold.
    var isBelowMinStock: Bool {
        minStock > 0 && currentStock <= minStock
    }

    /// Whether stock is at or below the soft fill_when_below threshold.
    var isBelowFillThreshold: Bool {
        fillWhenBelow > 0 && currentStock <= fillWhenBelow
    }

    /// Stock health for this individual tray.
    var stockHealth: StockHealth {
        if isEmpty { return .critical }
        if isBelowMinStock { return .low }
        return .ok
    }
}

/// Lets the fleet-wide stock classification in `MachineStockHealth` work on
/// real trays without the pure logic depending on this model.
extension Tray: SlottedStockTray {}

/// Payload for creating or updating a tray.
struct TrayUpsert: Encodable {
    let machineId: UUID
    let itemNumber: Int
    let productId: UUID?
    let capacity: Int
    let currentStock: Int
    let minStock: Int
    let fillWhenBelow: Int

    enum CodingKeys: String, CodingKey {
        case capacity
        case machineId = "machine_id"
        case itemNumber = "item_number"
        case productId = "product_id"
        case currentStock = "current_stock"
        case minStock = "min_stock"
        case fillWhenBelow = "fill_when_below"
    }

    /// Custom encoder that always emits `product_id`, including as explicit
    /// `null` when unset. Swift's synthesized `encode(to:)` uses
    /// `encodeIfPresent` for optional properties, which omits the field
    /// entirely — and PostgREST treats omitted fields as "don't change", so
    /// clearing a tray's product via UPDATE would silently fail.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machineId, forKey: .machineId)
        try container.encode(itemNumber, forKey: .itemNumber)
        try container.encode(productId, forKey: .productId)
        try container.encode(capacity, forKey: .capacity)
        try container.encode(currentStock, forKey: .currentStock)
        try container.encode(minStock, forKey: .minStock)
        try container.encode(fillWhenBelow, forKey: .fillWhenBelow)
    }
}
