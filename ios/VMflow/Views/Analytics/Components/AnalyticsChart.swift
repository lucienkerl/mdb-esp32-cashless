import SwiftUI
import Charts

/// Single data point for the analytics time-series chart.
struct AnalyticsChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

/// Generic time-series chart wrapper. Renders bars + an average rule.
///
/// TODO Phase 5b: add `chartScrollableAxes(.horizontal)` and
/// `chartXVisibleDomain(length: 30 * 86400)` for windowed scrolling.
struct AnalyticsChart: View {
    let points: [AnalyticsChartPoint]
    let title: String?
    let yAxisLabel: String?

    init(points: [AnalyticsChartPoint], title: String? = nil, yAxisLabel: String? = nil) {
        self.points = points
        self.title = title
        self.yAxisLabel = yAxisLabel
    }

    private var avg: Double {
        points.isEmpty ? 0 : points.map(\.value).reduce(0, +) / Double(points.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal)
            }
            if points.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart {
                    ForEach(points) { p in
                        BarMark(
                            x: .value("Date", p.date, unit: .day),
                            y: .value(yAxisLabel ?? "Value", p.value)
                        )
                        .foregroundStyle(Color.accentColor)
                        .cornerRadius(4)
                    }
                    if avg > 0 {
                        RuleMark(y: .value("Avg", avg))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(minHeight: 240)
                .padding(.horizontal)
            }
        }
    }
}

#Preview {
    let cal = Calendar.current
    let now = Date()
    let pts: [AnalyticsChartPoint] = (0..<14).map { i in
        AnalyticsChartPoint(
            date: cal.date(byAdding: .day, value: -i, to: now) ?? now,
            value: Double.random(in: 40...180)
        )
    }
    return AnalyticsChart(points: pts.reversed(), title: "Revenue (14 days)", yAxisLabel: "EUR")
        .padding()
}
