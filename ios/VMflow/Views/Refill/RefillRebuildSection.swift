import SwiftUI

/// Refill step, at the machine: the slots of the change note as a short list,
/// one row per slot, ticked off like the products when packing. A row shows
/// the slot, the new product (instead of the old one), what to watch for
/// (spiral, price, age) and the units going in. One tap on the circle marks
/// the slot done; a slot with a new price or age limit asks once that it was
/// set on the machine. Tapping the row opens the amounts (taken out / filled
/// in) and "Not possible today". Nothing is booked until the machine is
/// confirmed (`apply_slot_change`); leftovers ride along in the van and are
/// booked back on the summary step.
struct RefillRebuildSection: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let machineId: UUID

    /// The slot whose amounts are open.
    @State private var expanded: UUID?
    /// The slot whose price / age setting is being confirmed before "done".
    @State private var confirming: RebuildSlot?

    private var isPrepared: Bool { viewModel.currentRebuildMachineId == machineId }
    private var slots: [RebuildSlot] { viewModel.currentRebuild }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isPrepared {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 12)
            } else if viewModel.withdrawnRebuildMachines.contains(machineId) {
                Label {
                    Text("The slot change was withdrawn in the meantime. Don't rebuild anything here; the goods packed for it go back to the warehouse at the end of the tour.")
                } icon: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
            } else if !slots.isEmpty {
                Label("Rebuild", systemImage: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.rebuildViolet)
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(slots) { slot in
                        if slot.id != slots.first?.id {
                            Divider().padding(.leading, 60)
                        }
                        row(slot)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            }
        }
        .confirmationDialog(
            confirming.map { String(localized: "Slot \($0.item.itemNumber)") } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { slot in
            Button("Yes, set on the machine") {
                HapticFeedback.success.fire()
                if slot.needsPriceConfirmation { viewModel.setRebuildPriceSet(itemId: slot.id, value: true) }
                if slot.needsAgeConfirmation { viewModel.setRebuildAgeSet(itemId: slot.id, value: true) }
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.setRebuildAction(itemId: slot.id, action: .done)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { slot in
            Text(confirmationMessage(slot))
        }
    }

    // MARK: - Row

    private func row(_ slot: RebuildSlot) -> some View {
        let item = slot.item
        let isDone = slot.action == .done
        let isSkipped = slot.action == .skip
        let isOpen = expanded == slot.id

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                tick(slot)

                Button {
                    HapticFeedback.light.fire()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded = isOpen ? nil : slot.id
                    }
                } label: {
                    HStack(spacing: 10) {
                        SlotNumberBadge(number: item.itemNumber, muted: isSkipped, size: 34)

                        if isSkipped {
                            if item.fromProductId != nil {
                                ProductImage(imagePath: item.fromImagePath, size: 40)
                            }
                        } else if item.toProductId != nil {
                            ProductImage(imagePath: item.toImagePath, size: 40)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            if isSkipped {
                                Text("\(item.fromName ?? String(localized: "Empty")) stays")
                                    .font(.subheadline.weight(.semibold))
                                Text("Comes up again on the next tour")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(item.toName ?? String(localized: "Empty the slot"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(isDone ? .secondary : .primary)
                                if item.fromProductId != nil {
                                    Text("instead of \(item.fromName ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                tags(slot)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !isSkipped && item.toProductId != nil {
                            Text(verbatim: "+\(slot.filled)")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.rebuildViolet)
                                .frame(minWidth: 48, minHeight: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.rebuildVioletFill.opacity(isOpen ? 0.25 : 0.13))
                                )
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isOpen {
                details(slot)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(isSkipped ? 0.7 : 1)
    }

    /// The big circle: open → done (asking for price / age first when they
    /// change), done or skipped → open again.
    private func tick(_ slot: RebuildSlot) -> some View {
        let isDone = slot.action == .done
        let isSkipped = slot.action == .skip
        return Button {
            HapticFeedback.light.fire()
            if slot.action != nil {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.setRebuildAction(itemId: slot.id, action: nil)
                }
            } else if slot.needsConfirmation {
                confirming = slot
            } else {
                HapticFeedback.success.fire()
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.setRebuildAction(itemId: slot.id, action: .done)
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isDone ? Color.green : Color.clear)
                Circle()
                    .strokeBorder(isDone ? Color.green : Color(.systemGray3), lineWidth: 2)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                } else if isSkipped {
                    Image(systemName: "minus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Slot \(slot.item.itemNumber) done"))
        .accessibilityAddTraits(isDone ? .isSelected : [])
    }

    /// What to watch for at this slot: new spiral, new price, new age limit.
    @ViewBuilder
    private func tags(_ slot: RebuildSlot) -> some View {
        let item = slot.item
        let price = item.changesPrice ? item.toPrice : nil
        if item.changesCapacity || price != nil || item.changesAge {
            HStack(spacing: 6) {
                if item.changesCapacity {
                    tag(Text("Spiral \(item.toCapacity)"), color: .orange)
                }
                if let price {
                    tag(Text(verbatim: String(format: "%.2f \u{20AC}", price)), color: .blue)
                }
                if item.changesAge {
                    tag(Text(verbatim: SlotChangeRequestItem.ageLabel(item.toMinAge)), color: .red)
                }
            }
            .padding(.top, 1)
        }
    }

    private func tag(_ text: Text, color: Color) -> some View {
        text
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.14)))
    }

    // MARK: - Details (amounts, not possible today)

    private func details(_ slot: RebuildSlot) -> some View {
        let item = slot.item
        return VStack(alignment: .leading, spacing: 8) {
            if slot.action != .skip {
                if item.fromProductId != nil {
                    amountRow(
                        title: Text("Take out \(item.fromName ?? "")"),
                        value: slot.removed,
                        max: nil
                    ) { viewModel.setRebuildRemoved(itemId: slot.id, value: $0) }
                }
                if item.toProductId != nil {
                    amountRow(
                        title: Text("Put in \(item.toName ?? "")"),
                        value: slot.filled,
                        max: viewModel.maxRebuildFilled(itemId: item.id)
                    ) { viewModel.setRebuildFilled(itemId: slot.id, value: $0) }
                    Text("\(slot.moved) from other slots · \(slot.fromVan) from the box")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                let skipped = viewModel.skippedSourceSlots(itemId: item.id)
                if !skipped.isEmpty && slot.filled < item.toCapacity {
                    Label {
                        Text(skipped.count == 1
                             ? String(localized: "Slot \(skipped[0]) is not rebuilt today, so this slot gets fewer units.")
                             : String(localized: "Slots \(skipped.map { String($0) }.joined(separator: ", ")) are not rebuilt today, so this slot gets fewer units."))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    HapticFeedback.light.fire()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.setRebuildAction(itemId: slot.id, action: .skip)
                        expanded = nil
                    }
                } label: {
                    Text("Not possible today")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Color.secondary)
            } else {
                Button {
                    HapticFeedback.light.fire()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.setRebuildAction(itemId: slot.id, action: nil)
                    }
                } label: {
                    Text("Rebuild after all")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.leading, 54)
    }

    private func amountRow(title: Text, value: Int, max: Int?, onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            title
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                HapticFeedback.light.fire()
                onChange(value - 1)
            } label: {
                Image(systemName: "minus")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.fill.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(value <= 0)

            Text(verbatim: "\(value)")
                .font(.title3.bold())
                .monospacedDigit()
                .frame(minWidth: 32)

            Button {
                HapticFeedback.light.fire()
                onChange(value + 1)
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.12)))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .disabled(max.map { value >= $0 } ?? false)
        }
    }

    // MARK: - Confirmation

    /// "Price at selection 12 set to 2.00 €" / "Age setting changed on the
    /// machine: 18+" — what the refiller confirms before the slot is done.
    private func confirmationMessage(_ slot: RebuildSlot) -> String {
        let item = slot.item
        var lines: [String] = []
        if slot.needsPriceConfirmation, let price = item.toPrice {
            lines.append(String(localized: "Price at selection \(item.itemNumber) set to") + " " + String(format: "%.2f \u{20AC}", price))
        }
        if slot.needsAgeConfirmation {
            lines.append(String(localized: "Age setting changed on the machine") + ": " + SlotChangeRequestItem.ageLabel(item.toMinAge))
        }
        return lines.joined(separator: "\n")
    }
}
