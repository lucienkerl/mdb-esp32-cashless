import SwiftUI

/// Unified navigation item for both sidebar (iPad/Mac) and tab bar (iPhone).
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case dashboard
    case machines
    case refill
    case inbox
    case analytics
    case cashBook
    case products
    case warehouse
    case deals
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .machines: "Machines"
        case .refill: "Refill"
        case .inbox: "Inbox"
        case .analytics: "Analytics"
        case .cashBook: NSLocalizedString("cash_book_title", comment: "")
        case .products: "Products"
        case .warehouse: "Warehouse"
        case .deals: "Deals"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "chart.bar.fill"
        case .machines: "storefront.fill"
        case .refill: "arrow.clockwise.circle.fill"
        case .inbox: "tray.fill"
        case .analytics: "chart.xyaxis.line"
        case .cashBook: "banknote.fill"
        case .products: "cube.box.fill"
        case .warehouse: "shippingbox.fill"
        case .deals: "tag.fill"
        case .settings: "gearshape.fill"
        }
    }

    /// Corresponding compact tab (iPhone) — items not in the tab bar live under "More".
    var compactTab: AppTab? {
        switch self {
        case .dashboard: .dashboard
        case .machines: .machines
        case .refill: .refill
        case .inbox: .inbox
        case .analytics: nil
        default: nil  // cashBook, products, warehouse, deals, settings → More tab
        }
    }
}
