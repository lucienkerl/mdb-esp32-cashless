// ios/VMflow/Views/Analytics/Sections/AnalyticsSalesView.swift
import SwiftUI

struct AnalyticsSalesView: View {
    @EnvironmentObject var filter: AnalyticsFilter
    @StateObject private var viewModel = AnalyticsSalesViewModel()

    private let dimensions = ["machine", "product", "category", "channel", "vat", "hour", "dow"]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Dimension picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(dimensions, id: \.self) { dim in
                            Button {
                                viewModel.dimension = dim
                            } label: {
                                Text(dim.capitalized)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(viewModel.dimension == dim ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(viewModel.dimension == dim ? Color.accentColor : .primary)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)

                // Loading / error states
                if viewModel.isLoading && viewModel.data == nil {
                    ProgressView().padding()
                } else if let error = viewModel.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding()
                }

                if let data = viewModel.data, !data.rows.isEmpty {
                    // KPI summary derived from the breakdown rows
                    let totalRevenue = data.rows.reduce(0.0) { $0 + $1.revenue }
                    let totalUnits   = data.rows.reduce(0)   { $0 + $1.units }
                    let salesCount   = data.rows.reduce(0)   { $0 + $1.count }
                    let avgBasket    = totalUnits > 0 ? totalRevenue / Double(totalUnits) : 0

                    AnalyticsKPIGroup(kpis: [
                        AnalyticsKPI(
                            label: "Revenue",
                            value: totalRevenue,
                            format: .currency,
                            icon: "eurosign.circle.fill",
                            color: .blue
                        ),
                        AnalyticsKPI(
                            label: "Units",
                            value: Double(totalUnits),
                            format: .number,
                            icon: "cart.fill",
                            color: .green
                        ),
                        AnalyticsKPI(
                            label: "Avg basket",
                            value: avgBasket,
                            format: .currency,
                            icon: "basket.fill",
                            color: .orange
                        ),
                        AnalyticsKPI(
                            label: "Sales count",
                            value: Double(salesCount),
                            format: .number,
                            icon: "bag.fill",
                            color: .purple
                        )
                    ])

                    // Visualisation: heatmap for hour/dow (1D — single row), otherwise bar list
                    if data.dimension == "hour" || data.dimension == "dow" {
                        heatmapStrip(rows: data.rows, dimension: data.dimension)
                    } else {
                        barList(rows: data.rows)
                    }

                    // Sortable breakdown table with drill-through
                    AnalyticsSortableList(
                        title: "Breakdown",
                        rows: data.rows,
                        columns: [
                            AnalyticsListColumn(
                                key: "label",
                                label: "Label",
                                value: { $0.label },
                                comparable: { _ in 0 }
                            ),
                            AnalyticsListColumn(
                                key: "revenue",
                                label: "Revenue",
                                value: { $0.revenue.formatted(.currency(code: "EUR")) },
                                comparable: { $0.revenue }
                            ),
                            AnalyticsListColumn(
                                key: "units",
                                label: "Units",
                                value: { String($0.units) },
                                comparable: { Double($0.units) }
                            ),
                            AnalyticsListColumn(
                                key: "share",
                                label: "Share",
                                value: { String(format: "%.1f%%", $0.shareRevenuePct) },
                                comparable: { $0.shareRevenuePct }
                            )
                        ],
                        onDrill: { row in onDrill(row: row, dimension: data.dimension) }
                    )
                } else if viewModel.data != nil {
                    Text("No data for this dimension")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(.vertical)
        }
        .refreshable { await viewModel.load() }
        .task {
            viewModel.bind(filter: filter)
            await viewModel.load()
        }
    }

    /// 1D heatmap rendered as a horizontal strip (single row of cells).
    @ViewBuilder
    private func heatmapStrip(rows: [AnalyticsSalesData.Row], dimension: String) -> some View {
        let cells = rows.map { $0.revenue }
        let labels = rows.map { $0.label }
        AnalyticsHeatmap(
            title: dimension == "hour" ? "Revenue by hour" : "Revenue by day-of-week",
            cells: [cells],          // single-row 2D array
            rowLabels: [""],
            colLabels: labels
        )
    }

    /// Simple horizontal bar list, sorted by revenue descending, top 10.
    @ViewBuilder
    private func barList(rows: [AnalyticsSalesData.Row]) -> some View {
        let sortedRows = rows.sorted { $0.revenue > $1.revenue }
        let maxRev = max(1.0, sortedRows.first?.revenue ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sortedRows.prefix(10)) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.label)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(row.revenue.formatted(.currency(code: "EUR")))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor)
                            .frame(width: max(4, geo.size.width * row.revenue / maxRev), height: 6)
                    }
                    .frame(height: 6)
                }
            }
        }
        .padding(.horizontal)
    }

    /// Drill-through: mutate the global filter based on the dimension's key shape.
    private func onDrill(row: AnalyticsSalesData.Row, dimension: String) {
        let keyStr = row.keyAsString
        switch dimension {
        case "machine":  filter.machines = [keyStr]
        case "category": filter.categories = [keyStr]
        case "channel":  filter.channels = [keyStr]
        case "vat":      if let d = Double(keyStr) { filter.vatRates = [d] }
        case "product":  break        // TODO Phase 5b: add product filter to AnalyticsFilter
        case "hour", "dow": break     // not drillable
        default: break
        }
    }
}
