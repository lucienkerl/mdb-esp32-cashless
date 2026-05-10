import SwiftUI

/// 2D heatmap grid (e.g. hour-of-day × day-of-week). Cell intensity is normalised
/// against the maximum value in `cells`.
struct AnalyticsHeatmap: View {
    let title: String?
    /// Cells indexed by [row][col]. Use Double for intensity.
    let cells: [[Double]]
    let rowLabels: [String]
    let colLabels: [String]

    init(
        title: String? = nil,
        cells: [[Double]],
        rowLabels: [String],
        colLabels: [String]
    ) {
        self.title = title
        self.cells = cells
        self.rowLabels = rowLabels
        self.colLabels = colLabels
    }

    private var maxValue: Double {
        let flat = cells.flatMap { $0 }
        return max(1.0, flat.max() ?? 1.0)
    }

    private func intensity(_ value: Double) -> Double {
        min(1.0, value / maxValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.headline)
            }
            // Column header
            HStack(spacing: 1) {
                Text("").frame(width: 36)
                ForEach(Array(colLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            // Rows
            ForEach(Array(cells.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 1) {
                    Text(rowLabels[safe: rowIdx] ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.green.opacity(0.15 + intensity(value) * 0.65))
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    let rows = (0..<7).map { row in
        (0..<24).map { col in Double((row * col) % 9) }
    }
    let dows = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    let hours = (0..<24).map { String($0) }
    return AnalyticsHeatmap(title: "Hour × DoW", cells: rows, rowLabels: dows, colLabels: hours)
        .padding()
}
