import SwiftUI

/// Renders a list of CashBookEntry rows with type badge,
/// amount, balance, optional difference subline, and machine name.
struct EntriesListSection: View {
    let entries: [CashBookEntry]
    let machineName: (UUID?) -> String?

    var body: some View {
        if entries.isEmpty {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ForEach(entries) { entry in
                row(for: entry)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: CashBookEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                typeBadge(entry.type, reversed: entry.isReversed)
                Spacer()
                Text(formatAmount(entry.amount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.amount >= 0 ? Color.green : Color.red)
                Text(entry.balanceAfter, format: .currency(code: "EUR"))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
            }

            HStack {
                Text(entry.createdAt, format: .dateTime.day().month(.twoDigits).hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                // The type badge above already conveys "Initial balance" in the
                // user's language; the raw description column for these rows is
                // a server-generated literal (historically German — see
                // 20260722000000_cash_book_initial_description_neutral.sql) that
                // would otherwise show up untranslated, so skip it here.
                if entry.type != .initial {
                    Text(entry.description ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Optional subline: difference (counted vs expected)
            if let counted = entry.countedAmount,
               let expected = entry.expectedAmount,
               abs(counted - expected) > 0.001 {
                Text(differenceText(diff: abs(counted - expected), counted: counted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Optional subline: machine name
            if let mid = entry.machineId, let name = machineName(mid) {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Optional subline: expense category + receipt
            if entry.type == .expense {
                HStack(spacing: 6) {
                    if let cat = entry.category {
                        let key: String = "cash_book_category_\(cat)"
                        Text(LocalizedStringKey(key))
                    }
                    if let ref = entry.receiptReference, !ref.isEmpty {
                        Text(verbatim: "· \(ref)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .opacity(entry.isReversed ? 0.5 : 1)
    }

    private func typeBadge(_ type: CashBookEntryType, reversed: Bool) -> some View {
        let (labelKey, color) = badgeStyle(for: type)
        return Text(labelKey)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func badgeStyle(for type: CashBookEntryType) -> (LocalizedStringKey, Color) {
        switch type {
        case .initial:    return ("cash_book_type_initial",    .gray)
        case .withdrawal: return ("cash_book_type_withdrawal", .red)
        case .correction: return ("cash_book_type_correction", .yellow)
        case .payout:     return ("cash_book_type_payout",     .blue)
        case .expense:    return ("cash_book_type_expense",    .orange)
        case .changeFloat: return ("cash_book_type_change_float", .purple)
        case .reversal:   return ("cash_book_type_reversal",   .orange)
        case .unknown:    return ("cash_book_type_unknown",    .gray)
        }
    }

    private func formatAmount(_ value: Double) -> String {
        let prefix = value >= 0 ? "+" : ""
        return prefix + (NumberFormatter.localizedString(from: value as NSNumber, number: .currency))
    }

    private func differenceText(diff: Double, counted: Double) -> String {
        let format = NSLocalizedString("cash_book_difference", comment: "")
        let diffStr = NumberFormatter.localizedString(from: diff as NSNumber, number: .currency)
        let countedStr = NumberFormatter.localizedString(from: counted as NSNumber, number: .currency)
        return String(format: format, diffStr, countedStr)
    }
}
