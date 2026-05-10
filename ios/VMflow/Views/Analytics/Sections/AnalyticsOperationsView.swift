// ios/VMflow/Views/Analytics/Sections/AnalyticsOperationsView.swift
import SwiftUI

struct AnalyticsOperationsView: View {
    @EnvironmentObject var filter: AnalyticsFilter
    @StateObject private var viewModel = AnalyticsOperationsViewModel()

    /// Stockout data foundation timestamp — must match
    /// `Docker/supabase/migrations/20260509000000_analytics_stockout_events.sql`.
    /// Filters whose `from` is earlier than this show only partial data.
    private static let stockoutDataAvailableFrom: Date = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: "2026-05-09T00:00:00Z") ?? .distantPast
    }()

    @State private var expandedTourDays: Set<String> = []

    private var showPreMigrationBanner: Bool {
        filter.from < Self.stockoutDataAvailableFrom
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Pre-migration banner.
                if showPreMigrationBanner {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Stockout data available from 09.05.2026 — earlier filters show incomplete data.")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                }

                if viewModel.isLoading && viewModel.data == nil {
                    ProgressView().padding()
                } else if let error = viewModel.error {
                    Text(error).foregroundStyle(.red).padding()
                }

                if let data = viewModel.data {
                    AnalyticsKPIGroup(kpis: [
                        AnalyticsKPI(
                            label: "Stockout hours",
                            value: data.kpis.stockoutHours,
                            format: .number,
                            icon: "exclamationmark.triangle.fill",
                            color: .red
                        ),
                        AnalyticsKPI(
                            label: "Lost revenue",
                            value: data.kpis.lostRevenue,
                            format: .currency,
                            icon: "eurosign.circle",
                            color: .orange
                        ),
                        AnalyticsKPI(
                            label: "Refill tours",
                            value: Double(data.kpis.refillTourCount),
                            format: .number,
                            icon: "arrow.clockwise.circle.fill",
                            color: .blue
                        ),
                        AnalyticsKPI(
                            label: "Avg cover days",
                            value: data.kpis.avgStockCoverDays ?? 0,
                            format: .number,
                            icon: "calendar.badge.clock",
                            color: .green
                        )
                    ])

                    stockoutSection(events: data.stockoutEvents)
                    refillToursSection(tours: data.refillTours)
                    stockCoverSection(rows: data.stockCover)
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

    // MARK: - Stockouts

    @ViewBuilder
    private func stockoutSection(events: [AnalyticsOperationsData.StockoutEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stockout events")
                .font(.headline)
                .padding(.horizontal)

            if events.isEmpty {
                Text("No stockouts in this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                // Sort by lost_revenue desc, cap at 50
                let sorted = events
                    .sorted { $0.lostRevenueEstimated > $1.lostRevenueEstimated }
                    .prefix(50)

                VStack(spacing: 6) {
                    ForEach(Array(sorted), id: \.id) { ev in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ev.productName ?? "#\(ev.itemNumber)")
                                    .font(.subheadline)
                                Text(ev.machineName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(stockoutTimestamp(startedAt: ev.startedAt, endedAt: ev.endedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(formatDuration(ev.durationSeconds))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(ev.lostRevenueEstimated.formatted(.currency(code: "EUR")))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.red)
                                    .monospacedDigit()
                            }
                        }
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        // TODO Phase 6b: "Plan tour" / "Mark resolved" actions.
                        // Needs persistence model + List wrapping (.swipeActions only renders inside List).
                    }
                }
                .padding(.horizontal)

                if events.count > 50 {
                    Text("Showing top \(50) of \(events.count) events.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Refill tours (collapsible per day)

    @ViewBuilder
    private func refillToursSection(tours: [AnalyticsOperationsData.RefillTour]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Refill tours")
                .font(.headline)
                .padding(.horizontal)

            if tours.isEmpty {
                Text("No refill tours in this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                let groups: [(day: String, items: [AnalyticsOperationsData.RefillTour])] = {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.timeZone = TimeZone(secondsFromGMT: 0)

                    var byDay: [String: [AnalyticsOperationsData.RefillTour]] = [:]
                    for t in tours {
                        byDay[f.string(from: t.startedAt), default: []].append(t)
                    }
                    return byDay
                        .map { (day: $0.key, items: $0.value.sorted { $0.startedAt > $1.startedAt }) }
                        .sorted { $0.day > $1.day }
                }()

                VStack(spacing: 6) {
                    ForEach(groups, id: \.day) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedTourDays.contains(group.day) },
                                set: { isExpanded in
                                    if isExpanded { expandedTourDays.insert(group.day) }
                                    else { expandedTourDays.remove(group.day) }
                                }
                            )
                        ) {
                            VStack(spacing: 6) {
                                ForEach(group.items) { t in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(t.userDisplay ?? "—")
                                                .font(.subheadline)
                                            Text("\(t.startedAt.formatted(date: .omitted, time: .shortened)) · \(t.durationMinutes)m · \(t.machinesCount) machines")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Text("\(t.unitsAdded) units")
                                            .font(.caption.monospacedDigit())
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        } label: {
                            HStack {
                                Text(group.day)
                                    .font(.subheadline.bold())
                                Spacer()
                                let unitsSum = group.items.reduce(0) { $0 + $1.unitsAdded }
                                Text("\(group.items.count) tours · \(unitsSum) units")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Stock cover

    @ViewBuilder
    private func stockCoverSection(rows: [AnalyticsOperationsData.StockCoverRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stock cover days")
                .font(.headline)
                .padding(.horizontal)
            Text("Red < 3 days. Yellow < 7.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if rows.isEmpty {
                Text("No tray data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                // Sort ascending by cover_days (nil = last); cap top 50.
                let sorted = rows.sorted { a, b in
                    let aD = a.coverDays ?? .infinity
                    let bD = b.coverDays ?? .infinity
                    return aD < bD
                }.prefix(50)

                VStack(spacing: 6) {
                    ForEach(Array(sorted), id: \.id) { row in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.productName ?? "#\(row.itemNumber)")
                                    .font(.subheadline)
                                Text(row.machineName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(row.currentStock) / \(String(format: "%.2f", row.velocity))/d")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                Text(coverDaysLabel(row.coverDays))
                                    .font(.subheadline.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(coverDaysColor(row.coverDays))
                            }
                        }
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal)

                if rows.count > 50 {
                    Text("Showing top \(50) of \(rows.count) trays.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        let h = Int(seconds / 3600)
        let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        return "\(h)h \(m)m"
    }

    /// Localized timestamp + optional "ongoing" suffix for stockout events.
    private func stockoutTimestamp(startedAt: Date, endedAt: Date?) -> String {
        let formatted = startedAt.formatted(date: .abbreviated, time: .shortened)
        guard endedAt == nil else { return formatted }
        return "\(formatted) — \(String(localized: "ongoing"))"
    }

    private func coverDaysLabel(_ d: Double?) -> String {
        guard let d else { return "—" }
        return String(format: "%.1f d", d)
    }

    private func coverDaysColor(_ d: Double?) -> Color {
        guard let d else { return .secondary }
        if d < 3 { return .red }
        if d < 7 { return .yellow }
        return .primary
    }
}
