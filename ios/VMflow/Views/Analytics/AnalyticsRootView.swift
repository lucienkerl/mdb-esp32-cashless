// ios/VMflow/Views/Analytics/AnalyticsRootView.swift
import SwiftUI

enum AnalyticsSection: String, CaseIterable, Identifiable {
  case overview, sales, products, machines, conversion, operations
  var id: String { rawValue }
  var label: String {
    switch self {
    case .overview:   "Overview"
    case .sales:      "Sales"
    case .products:   "Products"
    case .machines:   "Machines"
    case .conversion: "Conversion"
    case .operations: "Operations"
    }
  }
  var icon: String {
    switch self {
    case .overview:   "chart.bar.fill"
    case .sales:      "eurosign.circle.fill"
    case .products:   "cube.box.fill"
    case .machines:   "storefront.fill"
    case .conversion: "figure.walk.motion"
    case .operations: "gauge.with.dots.needle.bottom.50percent"
    }
  }
}

struct AnalyticsRootView: View {
  @StateObject private var filter = AnalyticsFilter.defaultValue
  @State private var selectedSection: AnalyticsSection? = .overview
  @State private var filterSheetPresented = false
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    Group {
      if sizeClass == .regular {
        // iPad / Mac: NavigationSplitView with section list
        NavigationSplitView {
          List(selection: $selectedSection) {
            ForEach(AnalyticsSection.allCases) { section in
              Label(section.label, systemImage: section.icon).tag(section)
            }
          }
          .navigationTitle("Analytics")
        } detail: {
          sectionView
            .navigationTitle(selectedSection?.label ?? "Analytics")
            .toolbar {
              ToolbarItem(placement: .topBarTrailing) {
                Button {
                  filterSheetPresented = true
                } label: {
                  Image(systemName: "line.3.horizontal.decrease.circle")
                }
              }
            }
        }
      } else {
        // iPhone: single screen with horizontal section picker
        VStack(spacing: 0) {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(AnalyticsSection.allCases) { section in
                Button {
                  selectedSection = section
                } label: {
                  Label(section.label, systemImage: section.icon)
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(selectedSection == section ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSection == section ? Color.accentColor : .primary)
              }
            }
            .padding(.horizontal)
          }
          .padding(.vertical, 8)
          .background(.bar)

          sectionView
        }
        .navigationTitle("Analytics")
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              filterSheetPresented = true
            } label: {
              Image(systemName: "line.3.horizontal.decrease.circle")
            }
          }
        }
      }
    }
    .environmentObject(filter)
    .sheet(isPresented: $filterSheetPresented) {
      AnalyticsFilterSheet()
        .environmentObject(filter)
        .presentationDetents([.medium, .large])
    }
  }

  @ViewBuilder
  private var sectionView: some View {
    switch selectedSection ?? .overview {
    case .overview:   AnalyticsOverviewView()
    case .sales:      AnalyticsSalesView()
    case .products:   AnalyticsProductsView()
    case .machines:   AnalyticsMachinesView()
    case .conversion: Text("Conversion — coming soon").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .operations: Text("Operations — coming soon").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
