// ios/VMflow/Views/Analytics/Sections/AnalyticsMachinesView.swift
import SwiftUI

struct AnalyticsMachinesView: View {
    @EnvironmentObject var filter: AnalyticsFilter
    @StateObject private var viewModel = AnalyticsMachinesViewModel()

    @State private var selectedForCompare: Set<UUID> = []
    @State private var compareSheetPresented = false

    private var canCompare: Bool {
        selectedForCompare.count >= 2 && selectedForCompare.count <= 4
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
                            icon: "storefront.fill",
                            color: .blue
                        ),
                        AnalyticsKPI(
                            label: "Best revenue",
                            value: data.kpis.bestRevenue ?? 0,
                            format: .currency,
                            icon: "crown.fill",
                            color: .yellow
                        ),
                        AnalyticsKPI(
                            label: "Avg conversion",
                            value: data.kpis.avgConversionPct ?? 0,
                            format: .percent,
                            icon: "figure.walk.motion",
                            color: .green
                        ),
                        AnalyticsKPI(
                            label: "Stockout hrs",
                            value: data.kpis.totalStockoutHours,
                            format: .number,
                            icon: "exclamationmark.triangle.fill",
                            color: .red
                        )
                    ])

                    if let bestName = data.kpis.bestMachineName {
                        Text("Best machine: \(bestName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }

                    // Compare toolbar
                    HStack {
                        Text("\(selectedForCompare.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Compare") {
                            compareSheetPresented = true
                        }
                        .disabled(!canCompare)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Clear") {
                            selectedForCompare.removeAll()
                        }
                        .disabled(selectedForCompare.isEmpty)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal)

                    // Machine cards
                    LazyVStack(spacing: 8) {
                        ForEach(data.machines) { row in
                            machineCard(row: row)
                        }
                    }
                    .padding(.horizontal)

                    if data.machines.isEmpty {
                        Text("No machines for this filter")
                            .foregroundStyle(.secondary)
                            .padding()
                    }

                    // TODO Phase 6b: MapKit bubble map (iPad only)
                }
            }
            .padding(.vertical)
        }
        .refreshable { await viewModel.load() }
        .task {
            viewModel.bind(filter: filter)
            await viewModel.load()
        }
        .sheet(isPresented: $compareSheetPresented) {
            let selected = (viewModel.data?.machines ?? []).filter {
                selectedForCompare.contains($0.id)
            }
            AnalyticsCompareView(machines: selected)
        }
    }

    @ViewBuilder
    private func machineCard(row: AnalyticsMachinesData.MachineRow) -> some View {
        HStack(spacing: 12) {
            // Online indicator
            Circle()
                .fill(row.currentOnline ? Color.green : Color.gray)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(row.units) units")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let conv = row.conversionPct {
                        Text(String(format: "%.1f%%", conv))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let gap = row.lastSaleGapMinutes {
                        Text(formatGap(gap))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Text(row.revenue.formatted(.currency(code: "EUR")))
                .font(.subheadline.bold())
                .monospacedDigit()

            // Compare checkbox
            Button {
                if selectedForCompare.contains(row.id) {
                    selectedForCompare.remove(row.id)
                } else if selectedForCompare.count < 4 {
                    selectedForCompare.insert(row.id)
                }
            } label: {
                Image(systemName: selectedForCompare.contains(row.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(selectedForCompare.contains(row.id)
                                     ? Color.accentColor
                                     : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!selectedForCompare.contains(row.id) && selectedForCompare.count >= 4)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func formatGap(_ minutes: Int) -> String {
        if minutes < 60 {
            return String(localized: "\(minutes)m ago")
        }
        if minutes < 1440 {
            return String(localized: "\(minutes / 60)h ago")
        }
        return String(localized: "\(minutes / 1440)d ago")
    }
}
