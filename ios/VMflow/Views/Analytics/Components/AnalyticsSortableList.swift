import SwiftUI

/// Column descriptor for `AnalyticsSortableList`.
struct AnalyticsListColumn<Row>: Identifiable {
    let id = UUID()
    let key: String
    let label: String
    let value: (Row) -> String
    /// Comparable value used for sorting this column.
    let comparable: (Row) -> Double
}

/// Generic sortable list with tap-to-drill rows. Header taps cycle sort key + direction.
///
/// TODO Phase 5b: add `swipeActions` for inline drill-through actions.
struct AnalyticsSortableList<Row: Identifiable>: View {
    let title: String?
    let rows: [Row]
    let columns: [AnalyticsListColumn<Row>]
    let onDrill: ((Row) -> Void)?

    @State private var sortKey: String = ""
    @State private var sortAscending: Bool = false

    init(
        title: String? = nil,
        rows: [Row],
        columns: [AnalyticsListColumn<Row>],
        onDrill: ((Row) -> Void)? = nil
    ) {
        self.title = title
        self.rows = rows
        self.columns = columns
        self.onDrill = onDrill
    }

    private var sortedRows: [Row] {
        guard let col = columns.first(where: { $0.key == sortKey }) else { return rows }
        return rows.sorted { a, b in
            sortAscending
                ? col.comparable(a) < col.comparable(b)
                : col.comparable(a) > col.comparable(b)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(LocalizedStringKey(title))
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            // Header row
            HStack(spacing: 12) {
                ForEach(columns) { col in
                    Button {
                        if sortKey == col.key {
                            sortAscending.toggle()
                        } else {
                            sortKey = col.key
                            sortAscending = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(LocalizedStringKey(col.label))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if sortKey == col.key {
                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)

            // Rows
            ForEach(sortedRows) { row in
                HStack(spacing: 12) {
                    ForEach(columns) { col in
                        Text(col.value(row))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { onDrill?(row) }
                Divider()
            }
        }
    }
}

#Preview {
    struct DemoRow: Identifiable {
        let id = UUID()
        let name: String
        let revenue: Double
        let sales: Int
    }
    let rows: [DemoRow] = [
        .init(name: "Machine A", revenue: 1280.5, sales: 327),
        .init(name: "Machine B", revenue: 942.1, sales: 211),
        .init(name: "Machine C", revenue: 1487.0, sales: 401)
    ]
    let cols: [AnalyticsListColumn<DemoRow>] = [
        .init(key: "name", label: "Machine", value: { $0.name }, comparable: { _ in 0 }),
        .init(key: "rev", label: "Revenue", value: { String(format: "%.2f", $0.revenue) }, comparable: { $0.revenue }),
        .init(key: "sales", label: "Sales", value: { String($0.sales) }, comparable: { Double($0.sales) })
    ]
    return AnalyticsSortableList(title: "Top machines", rows: rows, columns: cols, onDrill: { _ in })
}
