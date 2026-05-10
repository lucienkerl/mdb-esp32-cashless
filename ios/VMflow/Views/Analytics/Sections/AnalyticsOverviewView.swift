// ios/VMflow/Views/Analytics/Sections/AnalyticsOverviewView.swift
import SwiftUI
import Charts

struct AnalyticsOverviewView: View {
    @EnvironmentObject var filter: AnalyticsFilter
    @StateObject private var viewModel = AnalyticsOverviewViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Realtime hint banner
                if viewModel.hasNewData {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Neue Daten verfügbar")
                        Spacer()
                        Button("Aktualisieren") {
                            Task { await viewModel.load() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                }

                // Loading / error states
                if viewModel.isLoading && viewModel.data == nil {
                    ProgressView().padding()
                } else if let error = viewModel.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding()
                }

                // Data
                if let data = viewModel.data {
                    AnalyticsKPIGroup(kpis: [
                        AnalyticsKPI(
                            label: "Revenue",
                            value: data.kpis.revenue,
                            deltaPct: data.kpisCompare.flatMap { compare in
                                compare.revenue > 0
                                    ? (data.kpis.revenue - compare.revenue) / compare.revenue * 100
                                    : nil
                            },
                            format: .currency,
                            icon: "eurosign.circle.fill",
                            color: .blue
                        ),
                        AnalyticsKPI(
                            label: "Units",
                            value: Double(data.kpis.units),
                            deltaPct: data.kpisCompare.flatMap { compare in
                                compare.units > 0
                                    ? Double(data.kpis.units - compare.units) / Double(compare.units) * 100
                                    : nil
                            },
                            format: .number,
                            icon: "cart.fill",
                            color: .green
                        ),
                        AnalyticsKPI(
                            label: "Avg basket",
                            value: data.kpis.avgBasket,
                            deltaPct: nil,
                            format: .currency,
                            icon: "basket.fill",
                            color: .orange
                        ),
                        AnalyticsKPI(
                            label: "Conversion",
                            value: data.kpis.conversionPct ?? 0,
                            deltaPct: nil,
                            format: .percent,
                            icon: "figure.walk.motion",
                            color: .purple
                        )
                    ])

                    // Daily revenue chart
                    let chartPoints = data.dailySeries.compactMap { p -> AnalyticsChartPoint? in
                        guard let date = AnalyticsOverviewView.dateFormatter.date(from: p.date) else { return nil }
                        return AnalyticsChartPoint(date: date, value: p.revenue)
                    }
                    AnalyticsChart(
                        points: chartPoints,
                        title: "Daily revenue",
                        yAxisLabel: "Revenue"
                    )

                    // Top products
                    if !data.topProducts.isEmpty {
                        AnalyticsSortableList(
                            title: "Top products",
                            rows: data.topProducts,
                            columns: [
                                AnalyticsListColumn(
                                    key: "name",
                                    label: "Name",
                                    value: { $0.name },
                                    comparable: { _ in 0 }
                                ),
                                AnalyticsListColumn(
                                    key: "units",
                                    label: "Units",
                                    value: { String($0.units) },
                                    comparable: { Double($0.units) }
                                ),
                                AnalyticsListColumn(
                                    key: "revenue",
                                    label: "Revenue",
                                    value: { $0.revenue.formatted(.currency(code: "EUR")) },
                                    comparable: { $0.revenue }
                                )
                            ]
                        )
                    }

                    // Top machines
                    if !data.topMachines.isEmpty {
                        AnalyticsSortableList(
                            title: "Top machines",
                            rows: data.topMachines,
                            columns: [
                                AnalyticsListColumn(
                                    key: "name",
                                    label: "Name",
                                    value: { $0.name },
                                    comparable: { _ in 0 }
                                ),
                                AnalyticsListColumn(
                                    key: "revenue",
                                    label: "Revenue",
                                    value: { $0.revenue.formatted(.currency(code: "EUR")) },
                                    comparable: { $0.revenue }
                                )
                            ]
                        )
                    }
                }
            }
            .padding(.vertical)
        }
        .refreshable { await viewModel.load() }
        .task {
            viewModel.bind(filter: filter)
            viewModel.subscribeRealtime()
            await viewModel.load()
        }
    }

    /// Static formatter for parsing 'YYYY-MM-DD' strings out of the jsonb response.
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
