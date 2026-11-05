import SwiftUI

/// Refill step, at the machine: rebuild the slots of the change note — one
/// slot at a time. The open slot is shown big (slot number, old → new) with
/// the hand movements in the order they are done: take out, change spiral,
/// fill in, set price / age. Amounts are prefilled (taken out = live stock,
/// filled in = the fill plan) and only changed by tapping the number. One big
/// "Slot N done" closes the slot, "Not possible today" leaves it for a later
/// tour. Decided slots collapse into a short list where they can be reopened.
/// Nothing is booked until the machine is confirmed (`apply_slot_change`);
/// leftovers ride along in the van and are booked back on the summary step.
struct RefillRebuildSection: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let machineId: UUID

    /// Which count is being edited (slot item id + field).
    @State private var editing: EditTarget?
    /// Hand movements ticked off — a guide for the refiller only; the age
    /// setting is the one tick that is recorded (and required).
    @State private var ticked: Set<TaskKey> = []

    private struct EditTarget: Equatable {
        let itemId: UUID
        let field: Field
    }

    private enum Field: Hashable {
        case removed
        case filled
    }

    private struct TaskKey: Hashable {
        let itemId: UUID
        let task: Int
    }

    private var isPrepared: Bool { viewModel.currentRebuildMachineId == machineId }
    private var slots: [RebuildSlot] { viewModel.currentRebuild }
    private var openSlot: RebuildSlot? { slots.first { $0.action == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                progressHeader

                if let slot = openSlot {
                    focusCard(slot)
                }

                let decided = slots.filter { $0.action != nil }
                if !decided.isEmpty {
                    decidedList(decided)
                }

                // Without a warehouse nothing was deducted, so nothing is
                // booked back.
                if openSlot == nil && viewModel.selectedWarehouseId != nil {
                    Label("Take removed goods with you – they are booked back at the end of the tour.", systemImage: "shippingbox")
                        .font(.subheadline)
                        .foregroundStyle(Color.rebuildViolet)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.rebuildVioletFill.opacity(0.12)))
                }
            }
        }
    }

    // MARK: - Progress

    private var progressHeader: some View {
        let position = (slots.firstIndex { $0.action == nil } ?? slots.count) + 1
        return HStack(spacing: 10) {
            if openSlot != nil {
                Label {
                    Text("Rebuild · slot \(position) of \(slots.count)")
                } icon: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .foregroundStyle(Color.rebuildViolet)
            } else {
                Label("Rebuild done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            HStack(spacing: 4) {
                ForEach(slots) { slot in
                    Capsule()
                        .fill(segmentColor(slot))
                        .frame(height: 6)
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 4)
    }

    private func segmentColor(_ slot: RebuildSlot) -> Color {
        switch slot.action {
        case .done: return .green
        case .skip: return Color(.systemGray3)
        case nil:
            return slot.id == openSlot?.id
                ? Color.rebuildVioletFill
                : Color.rebuildVioletFill.opacity(0.25)
        }
    }

    // MARK: - Focus Card (the open slot)

    private func focusCard(_ slot: RebuildSlot) -> some View {
        let item = slot.item
        var steps: [AnyView] = []
        var number = 0
        func next() -> Int { number += 1; return number }

        if item.fromProductId != nil {
            let n = next()
            steps.append(AnyView(taskRow(
                slot: slot, index: n,
                title: Text("Take out \(item.fromName ?? "")"),
                subtitle: Text("Into the van"),
                count: (value: slot.removed, field: .removed, max: nil)
            )))
        }
        if item.changesCapacity {
            let n = next()
            steps.append(AnyView(taskRow(
                slot: slot, index: n,
                title: Text("Change spiral"),
                subtitle: Text(verbatim: "\(item.fromCapacity) → \(item.toCapacity)")
            )))
        }
        if item.toProductId != nil {
            let n = next()
            steps.append(AnyView(taskRow(
                slot: slot, index: n,
                title: Text("Put in \(item.toName ?? "")"),
                subtitle: Text("\(slot.moved) from other slots · \(slot.fromVan) from the box"),
                count: (value: slot.filled, field: .filled, max: viewModel.maxRebuildFilled(itemId: item.id))
            )))
        }
        if item.changesPrice, let price = item.toPrice {
            let n = next()
            steps.append(AnyView(taskRow(
                slot: slot, index: n,
                title: Text("Set price"),
                subtitle: Text("Selection \(item.itemNumber)"),
                trailing: AnyView(pill(Text(verbatim: String(format: "%.2f \u{20AC}", price)), color: .blue)),
                isTicked: slot.priceSet,
                onTick: { viewModel.setRebuildPriceSet(itemId: item.id, value: !slot.priceSet) }
            )))
        }
        if item.changesAge {
            let n = next()
            steps.append(AnyView(taskRow(
                slot: slot, index: n,
                title: Text("Change age setting"),
                subtitle: Text(verbatim: item.ageChangeLabel),
                trailing: AnyView(pill(Text(verbatim: SlotChangeRequestItem.ageLabel(item.toMinAge)), color: .red)),
                isTicked: slot.ageSet,
                onTick: { viewModel.setRebuildAgeSet(itemId: item.id, value: !slot.ageSet) }
            )))
        }

        return VStack(spacing: 12) {
            hero(item)

            VStack(spacing: 0) {
                ForEach(steps.indices, id: \.self) { i in
                    if i > 0 { Divider().padding(.leading, 54) }
                    steps[i]
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))

            let skipped = viewModel.skippedSourceSlots(itemId: item.id)
            if !skipped.isEmpty && slot.filled < item.toCapacity {
                Label {
                    Text(skipped.count == 1
                         ? String(localized: "Slot \(skipped[0]) is not rebuilt today, so this slot gets fewer units.")
                         : String(localized: "Slots \(skipped.map { String($0) }.joined(separator: ", ")) are not rebuilt today, so this slot gets fewer units."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            if slot.needsAgeConfirmation {
                Text("Confirm the age setting first")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            } else if item.fromProductId != nil || item.toProductId != nil {
                Text("Tap a number if it is not right.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            Button {
                HapticFeedback.success.fire()
                editing = nil
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.setRebuildAction(itemId: item.id, action: .done)
                }
            } label: {
                Label("Slot \(item.itemNumber) done", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(slot.needsAgeConfirmation)

            Button {
                HapticFeedback.light.fire()
                editing = nil
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.setRebuildAction(itemId: item.id, action: .skip)
                }
            } label: {
                Text("Not possible today")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func hero(_ item: SlotChangeRequestItem) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text("Slot")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .opacity(0.75)
                Text(verbatim: "\(item.itemNumber)")
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .frame(width: 68, height: 68)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.label).opacity(0.88)))

            HStack(spacing: 8) {
                productTile(imagePath: item.fromImagePath, name: item.fromName, isOld: true, hasProduct: item.fromProductId != nil)
                Image(systemName: "arrow.right")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.rebuildViolet)
                productTile(imagePath: item.toImagePath, name: item.toName, isOld: false, hasProduct: item.toProductId != nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
    }

    private func productTile(imagePath: String?, name: String?, isOld: Bool, hasProduct: Bool) -> some View {
        VStack(spacing: 4) {
            if hasProduct {
                ProductImage(imagePath: imagePath, size: 52)
                    .opacity(isOld ? 0.5 : 1)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
            }
            Text(hasProduct ? (name ?? "") : String(localized: "Empty"))
                .font(.caption.weight(isOld ? .regular : .semibold))
                .foregroundStyle(isOld ? Color.secondary : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 110)
    }

    // MARK: - Task Row

    private func taskRow(
        slot: RebuildSlot,
        index: Int,
        title: Text,
        subtitle: Text,
        count: (value: Int, field: Field, max: Int?)? = nil,
        trailing: AnyView? = nil,
        isTicked: Bool? = nil,
        onTick: (() -> Void)? = nil
    ) -> some View {
        let key = TaskKey(itemId: slot.id, task: index)
        let done = isTicked ?? ticked.contains(key)
        let isEditing = count.map { editing == EditTarget(itemId: slot.id, field: $0.field) } ?? false

        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    HapticFeedback.light.fire()
                    if let onTick {
                        onTick()
                    } else if ticked.contains(key) {
                        ticked.remove(key)
                    } else {
                        ticked.insert(key)
                    }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(done ? Color.green : Color.clear)
                            Circle()
                                .strokeBorder(done ? Color.green : Color(.systemGray3), lineWidth: 2)
                            if done {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text(verbatim: "\(index)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            title
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            subtitle
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let count {
                    Button {
                        HapticFeedback.light.fire()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let target = EditTarget(itemId: slot.id, field: count.field)
                            editing = editing == target ? nil : target
                        }
                    } label: {
                        Text(verbatim: "\(count.value)")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.rebuildViolet)
                            .frame(minWidth: 52, minHeight: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.rebuildVioletFill.opacity(isEditing ? 0.25 : 0.13))
                            )
                    }
                    .buttonStyle(.plain)
                }
                if let trailing {
                    trailing
                }
            }

            if let count, isEditing {
                stepper(value: count.value, max: count.max) { newValue in
                    switch count.field {
                    case .removed: viewModel.setRebuildRemoved(itemId: slot.id, value: newValue)
                    case .filled: viewModel.setRebuildFilled(itemId: slot.id, value: newValue)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
    }

    private func stepper(value: Int, max: Int?, onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                HapticFeedback.light.fire()
                onChange(value - 1)
            } label: {
                Image(systemName: "minus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.fill.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(value <= 0)

            Text(verbatim: "\(value)")
                .font(.title2.bold())
                .monospacedDigit()
                .frame(minWidth: 44)

            Button {
                HapticFeedback.light.fire()
                onChange(value + 1)
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.12)))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .disabled(max.map { value >= $0 } ?? false)
        }
        .padding(.leading, 40)
    }

    private func pill(_ text: Text, color: Color) -> some View {
        text
            .font(.headline)
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
    }

    // MARK: - Decided Slots

    private func decidedList(_ decided: [RebuildSlot]) -> some View {
        VStack(spacing: 0) {
            ForEach(decided) { slot in
                if slot.id != decided.first?.id {
                    Divider().padding(.leading, 62)
                }
                decidedRow(slot)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
    }

    private func decidedRow(_ slot: RebuildSlot) -> some View {
        let item = slot.item
        let isDone = slot.action == .done

        return HStack(spacing: 12) {
            SlotNumberBadge(number: item.itemNumber, muted: !isDone, size: 36)

            if isDone, item.toProductId != nil {
                ProductImage(imagePath: item.toImagePath, size: 36)
            } else if !isDone, item.fromProductId != nil {
                ProductImage(imagePath: item.fromImagePath, size: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isDone {
                    Text(item.toName ?? String(localized: "Left empty"))
                        .font(.body.weight(.semibold))
                    if item.toProductId != nil {
                        Text("\(slot.filled) filled in")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(item.fromName ?? String(localized: "Empty")) stays")
                        .font(.body.weight(.semibold))
                    Text("Comes up again on the next tour")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button("Change") {
                HapticFeedback.light.fire()
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.setRebuildAction(itemId: item.id, action: nil)
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)

            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
