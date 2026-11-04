import SwiftUI

/// Packing step: a machine's change note ("Änderungsvermerk") as one compact
/// violet banner — "Rebuild 3 slots · 12, 14, 23". Tapping it opens
/// `RefillChangeNoteSheet`, where the refiller can leave single slots out
/// for this tour (default: all in). The goods for accepted slots sit in the
/// normal packing list below, marked with the same violet ⇄.
struct RefillChangeNoteCard: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let machine: RefillMachine
    /// Show the machine name — the "All" chip lists the notes of several machines.
    var showsMachineName: Bool = true

    @State private var showsSheet = false

    private var items: [SlotChangeRequestItem] { machine.changeRequest?.items ?? [] }

    private var accepted: [SlotChangeRequestItem] {
        items.filter { viewModel.isRebuildAccepted($0.id) }
    }

    var body: some View {
        Button {
            HapticFeedback.light.fire()
            showsSheet = true
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
                        .foregroundStyle(accepted.isEmpty ? Color.secondary : Color.rebuildViolet)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.rebuildVioletFill.opacity(accepted.isEmpty ? 0.2 : 0.5), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsSheet) {
            RefillChangeNoteSheet(viewModel: viewModel, machineId: machine.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// "Rebuild 3 slots · 12, 14, 23" — or "Not this tour" when every slot
    /// was left out.
    private var summaryLine: String {
        guard !accepted.isEmpty else { return String(localized: "Not this tour") }
        let numbers = accepted.map { String($0.itemNumber) }.joined(separator: ", ")
        return "\(Self.rebuildCountLabel(accepted.count)) · \(numbers)"
    }

    static func rebuildCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "Rebuild 1 slot")
            : String(localized: "Rebuild \(count) slots")
    }
}

// MARK: - Details Sheet

/// The slots of one machine's change note with a switch each, plus what to
/// take along. Declined slots stay open server-side for a later tour.
struct RefillChangeNoteSheet: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let machineId: UUID
    @Environment(\.dismiss) private var dismiss

    private var machine: RefillMachine? {
        viewModel.machines.first { $0.id == machineId }
    }

    private var items: [SlotChangeRequestItem] { machine?.changeRequest?.items ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let acceptedCount = items.filter { viewModel.isRebuildAccepted($0.id) }.count
                    Text(verbatim: acceptedCount == 0
                         ? String(localized: "Not this tour")
                         : RefillChangeNoteCard.rebuildCountLabel(acceptedCount))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.rebuildViolet)

                    ForEach(items) { item in
                        slotRow(item)
                    }

                    takeAlong
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(machine?.machine.displayName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func slotRow(_ item: SlotChangeRequestItem) -> some View {
        let accepted = viewModel.isRebuildAccepted(item.id)

        return HStack(spacing: 12) {
            SlotNumberBadge(number: item.itemNumber, muted: !accepted)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if item.fromProductId != nil {
                        ProductImage(imagePath: item.fromImagePath, size: 26)
                            .opacity(0.5)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if item.toProductId != nil {
                        ProductImage(imagePath: item.toImagePath, size: 32)
                    }
                    Text(item.toName ?? String(localized: "Leave empty"))
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                }
                if accepted {
                    SlotChangeTags(item: item)
                } else {
                    Text("Not this time · comes up again next tour")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { viewModel.isRebuildAccepted(item.id) },
                set: { newValue in
                    guard newValue != viewModel.isRebuildAccepted(item.id) else { return }
                    HapticFeedback.light.fire()
                    viewModel.toggleRebuildItem(machineId: machineId, itemId: item.id)
                }
            ))
            .labelsHidden()
            .tint(.green)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .opacity(accepted ? 1 : 0.6)
    }

    /// "Take along: 10× Club-Mate, 2 spirals for 10".
    @ViewBuilder
    private var takeAlong: some View {
        let needs = viewModel.rebuildNeeds(machineId: machineId)
        let accepted = items.filter { viewModel.isRebuildAccepted($0.id) }
        let goods: [String] = {
            var seen: Set<UUID> = []
            var out: [String] = []
            for item in accepted {
                guard let pid = item.toProductId, !seen.contains(pid) else { continue }
                seen.insert(pid)
                let qty = viewModel.rebuildQuantity(machineId: machineId, productId: pid)
                let need = needs[pid] ?? 0
                guard need > 0 else { continue }
                out.append("\(qty)× \(item.toName ?? "")")
            }
            return out
        }()
        let spirals: [String] = {
            let byCapacity = Dictionary(grouping: accepted.filter(\.changesCapacity), by: \.toCapacity)
            return byCapacity.keys.sorted().map { capacity in
                let count = byCapacity[capacity]?.count ?? 0
                return count == 1
                    ? String(localized: "1 spiral for \(capacity)")
                    : String(localized: "\(count) spirals for \(capacity)")
            }
        }()
        let parts = goods + spirals
        if !parts.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(Color.rebuildViolet)
                (Text("Take along:") + Text(verbatim: " ") + Text(verbatim: parts.joined(separator: ", ")).bold())
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        }
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
