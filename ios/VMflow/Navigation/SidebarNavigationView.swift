import SwiftUI

/// iPad / Mac sidebar navigation using NavigationSplitView.
/// All items from the "More" tab are promoted to first-class sidebar entries.
struct SidebarNavigationView: View {
    @State private var selectedItem: SidebarItem? = .dashboard
    @StateObject private var notificationService = NotificationService.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedItem) {
                ForEach(SidebarItem.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.label, systemImage: item.icon)
                            .badge(badgeCount(for: item))
                    }
                }
            }
            .navigationTitle("VMflow")
        } detail: {
            if let item = selectedItem {
                detailView(for: item)
            } else {
                ContentUnavailableView(
                    "Select an Item",
                    systemImage: "sidebar.left",
                    description: Text("Choose an item from the sidebar.")
                )
            }
        }
        // Deep-link routing from notifications
        .onChange(of: notificationService.pendingDeepLink) { _, link in
            guard let link else { return }
            switch link {
            case .inbox:
                selectedItem = .inbox
            }
            notificationService.pendingDeepLink = nil
        }
    }

    // MARK: - Detail View Router

    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        switch item {
        case .dashboard:
            NavigationStack {
                DashboardView(onNavigate: { selectedItem = $0 })
            }
        case .machines:
            MachinesSplitView()
        case .refill:
            NavigationStack {
                RefillWizardView()
            }
        case .inbox:
            NavigationStack {
                InboxView()
            }
        case .analytics:
            NavigationStack {
                AnalyticsRootView()
            }
        case .cashBook:
            NavigationStack {
                CashBookView()
            }
        case .products:
            NavigationStack {
                ProductsView()
            }
        case .warehouse:
            NavigationStack {
                WarehouseView()
            }
        case .deals:
            NavigationStack {
                DealsView()
            }
        case .settings:
            NavigationStack {
                SettingsView()
            }
        }
    }

    private func badgeCount(for item: SidebarItem) -> Int {
        switch item {
        case .inbox: notificationService.openInboxCount
        default: 0
        }
    }
}
