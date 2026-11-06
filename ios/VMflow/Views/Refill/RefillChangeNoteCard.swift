import SwiftUI

/// Packing step: a machine's change note ("Änderungsvermerk") as one violet
/// banner — "Rebuild 3 slots · 12, 14, 23", plus the spirals to take along
/// (the only thing not on the packing list). It opens in place (no modal) and
/// is information only: every planned rebuild is packed (warehouse stock was
/// checked when it was planned), its goods are ticked into the box in the
/// packing list like any other goods, and a slot that can't be done is
/// skipped at the machine ("Not possible today").
struct RefillChangeNoteCard: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let machine: RefillMachine
    /// Show the machine name — the "All" chip lists the notes of several machines.
    var showsMachineName: Bool = true

    @State private var isExpanded = false

    private var items: [SlotChangeRequestItem] {
        (machine.changeRequest?.items ?? []).sorted { $0.itemNumber < $1.itemNumber }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                HapticFeedback.light.fire()
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    RebuildIcon()

                    VStack(alignment: .leading, spacing: 2) {
                        if showsMachineName {
                            Text(machine.machine.displayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(verbatim: summaryLine)
                            .font(.subheadline)
                            .foregroundStyle(Color.rebuildViolet)
                            .fixedSize(horizontal: false, vertical: true)
                        // The one thing not on the packing list: spirals.
                        if let extras = extrasLine {
                            Label {
                                Text(verbatim: extras)
                            } icon: {
                                Image(systemName: "shippingbox")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(items) { item in
                    Divider()
                    slotRow(item)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.rebuildVioletFill.opacity(0.5), lineWidth: 1.5)
        )
    }

    /// "Rebuild 3 slots · 12, 14, 23".
    private var summaryLine: String {
        let numbers = items.map { String($0.itemNumber) }.joined(separator: ", ")
        return "\(Self.rebuildCountLabel(items.count)) · \(numbers)"
    }

    /// Besides the goods (in the packing list): spirals to take along —
    /// "Take along: 2× 8-spiral" (de: "Mitnehmen: 2× 8er-Spirale").
    private var extrasLine: String? {
        let byCapacity = Dictionary(grouping: items.filter(\.changesCapacity), by: \.toCapacity)
        guard !byCapacity.isEmpty else { return nil }
        let spirals = byCapacity.keys.sorted().map { capacity -> String in
            let count = byCapacity[capacity]?.count ?? 0
            return String(localized: "\(count)× spiral for \(capacity)")
        }
        return "\(String(localized: "Take along:")) \(spirals.joined(separator: ", "))"
    }

    /// Slot number, old product (dimmed) over the new one, both in full, and
    /// what else changes (spiral, price, age).
    private func slotRow(_ item: SlotChangeRequestItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SlotNumberBadge(number: item.itemNumber, size: 40)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if item.fromProductId != nil {
                        ProductImage(imagePath: item.fromImagePath, size: 26)
                            .opacity(0.5)
                    }
                    Text(item.fromName ?? String(localized: "Empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if item.toProductId != nil {
                        ProductImage(imagePath: item.toImagePath, size: 26)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3]))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                    }
                    Text(item.toName ?? String(localized: "Empty the slot"))
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                SlotChangeTags(item: item)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    static func rebuildCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "Rebuild 1 slot")
            : String(localized: "Rebuild \(count) slots")
    }
}

// MARK: - Shared Pieces

/// Violet ⇄ in a soft circle: the one symbol for "slot rebuild".
struct RebuildIcon: View {
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Color.rebuildViolet)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.rebuildVioletFill.opacity(0.15)))
    }
}

/// Dark square with the slot number, readable from arm's length.
struct SlotNumberBadge: View {
    let number: Int
    var muted: Bool = false
    var size: CGFloat = 44

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: size * 0.4, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22).fill(muted ? Color.gray : Color(.label).opacity(0.88)))
    }
}

/// Small tags for what changes besides the product: spiral, price, age.
struct SlotChangeTags: View {
    let item: SlotChangeRequestItem

    var body: some View {
        HStack(spacing: 6) {
            if item.changesCapacity {
                tag(Text("Spiral \(item.toCapacity)"), color: .orange)
            }
            if item.changesPrice, let price = item.toPrice {
                tag(Text(verbatim: String(format: "%.2f \u{20AC}", price)), color: .blue)
            }
            if item.changesAge {
                tag(Text(verbatim: SlotChangeRequestItem.ageLabel(item.toMinAge)), color: .red)
            }
        }
    }

    private func tag(_ text: Text, color: Color) -> some View {
        text
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.13)))
    }
}

// MARK: - Age Restriction Labels

extension SlotChangeRequestItem {
    /// "18+" / "no age limit" (de: "ab 18" / "ohne Altersgrenze").
    static func ageLabel(_ minAge: Int?) -> String {
        guard let minAge else { return String(localized: "no age limit") }
        return String(localized: "\(minAge)+")
    }

    /// The change spelled out, e.g. "no age limit → 18+".
    var ageChangeLabel: String {
        "\(Self.ageLabel(fromMinAge)) → \(Self.ageLabel(toMinAge))"
    }
}

// MARK: - Rebuild Accent

extension Color {
    /// Violet of slot rebuild goods in the packing list (text / icons) —
    /// the PWA's violet-700 in light mode, violet-300 in dark mode.
    static let rebuildViolet = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.769, green: 0.710, blue: 0.992, alpha: 1)
            : UIColor(red: 0.427, green: 0.157, blue: 0.851, alpha: 1)
    })
    /// Violet-500, for tinted backgrounds and borders (use with opacity).
    static let rebuildVioletFill = Color(red: 0.545, green: 0.361, blue: 0.965)
}
