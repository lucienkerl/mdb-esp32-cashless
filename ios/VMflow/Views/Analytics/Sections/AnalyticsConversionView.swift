// ios/VMflow/Views/Analytics/Sections/AnalyticsConversionView.swift
import SwiftUI
import Charts

struct AnalyticsConversionView: View {
    @EnvironmentObject var filter: AnalyticsFilter
    @StateObject private var viewModel = AnalyticsConversionViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Fleet-avg ratio = total sales / total pax (used for scatter reference line).
    private var fleetAvgRatio: Double? {
        guard let m = viewModel.data?.machines else { return nil }
        let totalPax = m.reduce(0) { $0 + $1.pax }
        let totalSales = m.reduce(0) { $0 + $1.sales }
        return totalPax > 0 ? Double(totalSales) / Double(totalPax) : nil
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
                    // KPIs — 4th cell is weighted avg revenue/visitor across machines (weighted by pax)
                    let weightedRPV: Double = {
                        var sumRev = 0.0
                        var sumPax = 0
                        for m in data.machines {
                            if let rpv = m.revenuePerVisitor, m.pax > 0 {
                                sumRev += rpv * Double(m.pax)
                                sumPax += m.pax
                            }
                        }
                        return sumPax > 0 ? sumRev / Double(sumPax) : 0
                    }()

                    AnalyticsKPIGroup(kpis: [
                        AnalyticsKPI(
                            label: "Footfall",
                            value: Double(data.kpis.footfall),
                            format: .number,
                            icon: "figure.walk",
                            color: .blue
                        ),
                        AnalyticsKPI(
                            label: "Conversion",
                            value: data.kpis.conversionPct ?? 0,
                            format: .percent,
                            icon: "checkmark.circle",
                            color: .green
                        ),
                        AnalyticsKPI(
                            label: "Empty passes",
                            value: Double(data.kpis.emptyPasses),
                            format: .number,
                            icon: "xmark.circle",
                            color: .orange
                        ),
                        AnalyticsKPI(
                            label: "Avg €/visitor",
                            value: weightedRPV,
                            format: .currency,
                            icon: "eurosign.circle",
                            color: .purple
                        )
                    ])

                    // Scatter: pax (x) vs sales (y) with fleet-avg reference line
                    if !data.machines.isEmpty {
                        scatterSection(machines: data.machines)
                    }

                    // Heatmap (iPad) or bar list (iPhone)
                    if sizeClass == .regular {
                        heatmapSection(machines: data.machines, hourHeatmap: data.hourHeatmap)
                    } else {
                        conversionBarList(machines: data.machines)
                    }

                    // Per-machine sortable table
                    if !data.machines.isEmpty {
                        AnalyticsSortableList(
                            title: "By machine",
                            rows: data.machines,
                            columns: [
                                AnalyticsListColumn(
                                    key: "name",
                                    label: "Name",
                                    value: { $0.name },
                                    comparable: { _ in 0 }
                                ),
                                AnalyticsListColumn(
                                    key: "pax",
                                    label: "Pax",
                                    value: { String($0.pax) },
                                    comparable: { Double($0.pax) }
                                ),
                                AnalyticsListColumn(
                                    key: "sales",
                                    label: "Sales",
                                    value: { String($0.sales) },
                                    comparable: { Double($0.sales) }
                                ),
                                AnalyticsListColumn(
                                    key: "conv",
                                    label: "Conv %",
                                    value: { String(format: "%.1f%%", $0.conversionPct) },
                                    comparable: { $0.conversionPct }
                                ),
                                AnalyticsListColumn(
                                    key: "rpv",
                                    label: "€/Visitor",
                                    value: { row in
                                        row.revenuePerVisitor.map { $0.formatted(.currency(code: "EUR")) } ?? "—"
                                    },
                                    comparable: { $0.revenuePerVisitor ?? 0 }
                                )
                            ]
                        )
                    } else {
                        Text("No machines for this filter")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
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

    // MARK: - Scatter

    @ViewBuilder
    private func scatterSection(machines: [AnalyticsConversionData.MachineRow]) -> some View {
        let maxPax = max(1, machines.map(\.pax).max() ?? 1)
        let refRatio = fleetAvgRatio
        VStack(alignment: .leading, spacing: 6) {
            Text("Pax × sales (per machine)")
                .font(.headline)
                .padding(.horizontal)
            Chart {
                ForEach(machines) { m in
                    PointMark(
                        x: .value("Pax", m.pax),
                        y: .value("Sales", m.sales)
                    )
                    .foregroundStyle(.blue.opacity(0.6))
                    .symbolSize(60)
                }
                if let ratio = refRatio {
                    // Reference line through origin with slope = fleet-avg ratio.
                    // Two LineMark points span x = 0..maxPax; Charts connects them.
                    LineMark(
                        x: .value("Pax", 0),
                        y: .value("Sales", 0)
                    )
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    LineMark(
                        x: .value("Pax", maxPax),
                        y: .value("Sales", Double(maxPax) * ratio)
                    )
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .frame(height: 220)
            .padding(.horizontal)
        }
    }

    // MARK: - Heatmap (iPad)

    @ViewBuilder
    private func heatmapSection(
        machines: [AnalyticsConversionData.MachineRow],
        hourHeatmap: [String: [Double?]]
    ) -> some View {
        // Pick top-10 machines by sales for legibility
        let topMachines = Array(machines.sorted { $0.sales > $1.sales }.prefix(10))
        let cells: [[Double]] = topMachines.map { m in
            // Postgres emits lowercase UUID strings; Swift uppercases — try both.
            let arr = hourHeatmap[m.id.uuidString.lowercased()]
                ?? hourHeatmap[m.id.uuidString]
                ?? []
            // Pad/truncate to 24, replace null with 0 (no signal == no activity for v1).
            return (0..<24).map { h in
                (h < arr.count ? (arr[h] ?? 0) : 0)
            }
        }
        let rowLabels: [String] = topMachines.map { String($0.name.prefix(12)) }
        let colLabels: [String] = (0..<24).map { String(format: "%02d", $0) }
        if !cells.isEmpty {
            AnalyticsHeatmap(
                title: "Conversion by machine × hour",
                cells: cells,
                rowLabels: rowLabels,
                colLabels: colLabels
            )
        }
    }

    // MARK: - Bar list (iPhone)

    @ViewBuilder
    private func conversionBarList(machines: [AnalyticsConversionData.MachineRow]) -> some View {
        let sorted = machines.sorted { $0.conversionPct > $1.conversionPct }
        let maxConv = max(1.0, sorted.first?.conversionPct ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversion by machine")
                .font(.headline)
                .padding(.horizontal)
            ForEach(sorted.prefix(10)) { m in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(m.name).font(.subheadline).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", m.conversionPct))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor)
                            .frame(
                                width: max(4, geo.size.width * m.conversionPct / maxConv),
                                height: 6
                            )
                    }
                    .frame(height: 6)
                }
                .padding(.horizontal)
            }
        }
    }
}
