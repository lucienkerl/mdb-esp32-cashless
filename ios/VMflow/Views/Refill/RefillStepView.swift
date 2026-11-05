import SwiftUI

/// Refill step: shows the current machine being refilled with editable fill amounts.
/// Designed for one-handed use with large touch targets.
struct RefillStepView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    @State private var showMachinePicker = false
    @State private var selectedProduct: ProductSelection?
    /// Machine whose "note for next tour" sheet is open.
    @State private var noteMachine: NoteTarget?

    struct NoteTarget: Identifiable {
        let id: UUID
        let name: String
    }

    struct ProductSelection: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
    }

    var body: some View {
        if let machine = viewModel.currentMachine {
            VStack(spacing: 0) {
                // Machine Header with Progress
                machineHeader(machine)

                ScrollView {
                    VStack(spacing: 12) {
                        // Change note: rebuild these slots first. They are
                        // not part of the normal refill below.
                        let hasRebuild = viewModel.machineHasRebuild(machine.id)
                        let hasTourTrays = machine.trays.contains { $0.isInTour }
                        // The normal refill comes after the rebuild — one
                        // thing at a time at the machine.
                        let showsRefill = !hasRebuild || rebuildDecided(machine)
                        if hasRebuild {
                            RefillRebuildSection(viewModel: viewModel, machineId: machine.id)
                            if hasTourTrays && showsRefill {
                                Text("Now refill")
                                    .font(.caption.weight(.semibold))
                                    .textCase(.uppercase)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4)
                                    .padding(.top, 4)
                            }
                        }

                        // Refill All Button
                        if showsRefill && (hasTourTrays || !hasRebuild) {
                            Button {
                                HapticFeedback.medium.fire()
                                viewModel.fillAllTrays(machineId: machine.id)
                            } label: {
                                Label("Fill All to Capacity", systemImage: "arrow.up.to.line")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                        }

                        // Tray list — show everything that's part of this tour,
                        // regardless of fillAmount. Reducing fillAmount to 0
                        // keeps the card visible so the user can bring it back.
                        if showsRefill {
                            ForEach(machine.trays.filter { $0.isInTour }) { refillTray in
                                refillTrayCard(refillTray, machineId: machine.id)
                            }
                        }

                        // Trays that are genuinely full (deficit == 0), not unpacked ones
                        let fullTrays = machine.trays.filter { $0.fillAmount == 0 && $0.deficit == 0 }
                        if showsRefill && !fullTrays.isEmpty {
                            DisclosureGroup {
                                ForEach(fullTrays) { tray in
                                    fullTrayRow(tray)
                                }
                            } label: {
                                Text(fullTrays.count == 1 ? String(localized: "1 tray already full") : String(localized: "\(fullTrays.count) trays already full"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 120) // Space for bottom buttons
                }
                .dataRefreshable {
                    // Explicit way to pull the latest tray stock — the
                    // Supabase realtime websocket may have missed sales
                    // that happened while the app was suspended
                    // (driving between machines, phone locked).
                    await viewModel.refreshFromRealtime()
                }

                // Bottom Action Bar
                bottomActionBar(machine)
            }
            .task(id: machine.id) {
                // Build the rebuild cards from live stock when the machine
                // comes up (no-op without a change note, or when already built).
                await viewModel.prepareRebuild(machineId: machine.id)
            }
            .sheet(item: $selectedProduct) { sel in
                ProductDetailSheet(
                    productId: sel.id,
                    fallbackName: sel.name,
                    fallbackImagePath: sel.imagePath,
                    fallbackSellprice: sel.sellprice
                )
            }
            .sheet(item: $noteMachine) { target in
                MachineTourNoteSheet(viewModel: viewModel, machineId: target.id, machineName: target.name)
            }
        } else {
            // No more machines - should transition to summary
            VStack {
                ProgressView()
                Text("Finishing up...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Machine Header

    private func machineHeader(_ machine: RefillMachine) -> some View {
        VStack(spacing: 8) {
            // Progress
            HStack {
                Text("Machine \(viewModel.machineProgress.current) of \(viewModel.machineProgress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                let toRefill = machine.trays.filter { $0.fillAmount > 0 }.count
                let rebuildCount = machine.changeRequest?.items.count ?? 0
                Text(toRefill == 0 && rebuildCount > 0
                     ? RefillChangeNoteCard.rebuildCountLabel(rebuildCount)
                     : (toRefill == 1 ? String(localized: "1 tray to refill") : String(localized: "\(toRefill) trays to refill")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: geo.size.width * progressFraction)
                        .animation(.spring(duration: 0.3), value: progressFraction)
                }
            }
            .frame(height: 4)

            // Machine Name — tappable to switch
            Button {
                showMachinePicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(machine.machine.displayName)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                    if viewModel.remainingMachines.count > 1 {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.remainingMachines.count <= 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
        .sheet(isPresented: $showMachinePicker) {
            machinePicker
        }
    }

    // MARK: - Machine Picker Sheet

    private var machinePicker: some View {
        NavigationStack {
            List {
                ForEach(viewModel.remainingMachines) { machine in
                    let isCurrent = machine.id == viewModel.currentMachine?.id
                    Button {
                        viewModel.selectMachine(machine.id)
                        showMachinePicker = false
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.machine.displayName)
                                    .font(.body.weight(isCurrent ? .bold : .regular))
                                    .foregroundStyle(.primary)

                                let traysToRefill = machine.trays.filter { $0.fillAmount > 0 }.count
                                let totalDeficit = machine.trays.reduce(0) { $0 + $1.fillAmount }
                                Text("\(traysToRefill) trays · \(totalDeficit) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if isCurrent {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMachinePicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var progressFraction: Double {
        let progress = viewModel.machineProgress
        guard progress.total > 0 else { return 0 }
        return Double(progress.current - 1) / Double(progress.total)
    }

    /// Open `ProductDetailSheet` for the tray's assigned product. No-op when
    /// the slot is unassigned (no `productId`).
    private func presentProductDetail(for tray: Tray) {
        guard let pid = tray.productId else { return }
        selectedProduct = ProductSelection(
            id: pid,
            name: tray.products?.name ?? tray.productName,
            imagePath: tray.products?.imagePath,
            sellprice: tray.products?.sellprice
        )
    }

    // MARK: - Refill Tray Card

    private func refillTrayCard(_ refillTray: RefillTray, machineId: UUID) -> some View {
        let soldDuringTour = viewModel.staleStockTrayIds.contains(refillTray.tray.id)

        return VStack(spacing: 12) {
            // Product info
            HStack(spacing: 12) {
                // Slot indicator
                Text("\(refillTray.tray.itemNumber)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(refillTray.tray.isEmpty ? Color.red : .orange))

                Button {
                    presentProductDetail(for: refillTray.tray)
                } label: {
                    HStack(spacing: 12) {
                        ProductImage(imagePath: refillTray.tray.products?.imagePath, size: 44)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(refillTray.tray.productName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)

                                if soldDuringTour {
                                    // Mini badge: a sale happened on this tray after
                                    // the tour started. User should notice before
                                    // committing their pre-planned fillAmount.
                                    Label("Sold during tour", systemImage: "cart.badge.minus")
                                        .labelStyle(.iconOnly)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("Stock changed since tour start")
                                }
                            }

                            // Current -> Target + Price
                            HStack(spacing: 4) {
                                Text("\(refillTray.tray.currentStock)")
                                    .foregroundStyle(soldDuringTour ? .orange : .red)
                                    .contentTransition(.numericText())
                                    .animation(.spring(duration: 0.3), value: refillTray.tray.currentStock)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(refillTray.targetStock)")
                                    .foregroundStyle(.green)
                                    .contentTransition(.numericText())
                                    .animation(.spring(duration: 0.3), value: refillTray.targetStock)
                                Text("/ \(refillTray.tray.capacity)")
                                    .foregroundStyle(.secondary)

                                if let price = refillTray.tray.formattedSellprice {
                                    Spacer()
                                    Text(price)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()
            }

            // Stock visualization
            HStack(spacing: 8) {
                // Before
                StockBar(
                    current: refillTray.tray.currentStock,
                    capacity: refillTray.tray.capacity,
                    showLabel: false,
                    height: 8
                )
                .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // After
                StockBar(
                    current: refillTray.targetStock,
                    capacity: refillTray.tray.capacity,
                    showLabel: false,
                    height: 8
                )
                .frame(maxWidth: .infinity)
            }

            // Fill amount control - LARGE touch targets!
            HStack(spacing: 16) {
                // Decrease
                Button {
                    HapticFeedback.light.fire()
                    viewModel.adjustFillAmount(
                        machineId: machineId,
                        trayId: refillTray.id,
                        amount: refillTray.fillAmount - 1
                    )
                } label: {
                    Image(systemName: "minus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.fill.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(refillTray.fillAmount <= 0)

                // Amount display
                VStack(spacing: 2) {
                    Text("+\(refillTray.fillAmount)")
                        .font(.title.bold())
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.2), value: refillTray.fillAmount)
                    Text("items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 70)

                // Increase
                Button {
                    HapticFeedback.light.fire()
                    viewModel.adjustFillAmount(
                        machineId: machineId,
                        trayId: refillTray.id,
                        amount: refillTray.fillAmount + 1
                    )
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.blue.opacity(0.12)))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(refillTray.fillAmount >= refillTray.tray.capacity - refillTray.tray.currentStock)

                Spacer()

                // Fill to capacity
                Button {
                    HapticFeedback.medium.fire()
                    viewModel.fillTrayToCapacity(machineId: machineId, trayId: refillTray.id)
                } label: {
                    Text("Max")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(.blue))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(refillTray.fillAmount >= refillTray.tray.capacity - refillTray.tray.currentStock)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    // MARK: - Full Tray Row

    private func fullTrayRow(_ refillTray: RefillTray) -> some View {
        HStack(spacing: 10) {
            Text("\(refillTray.tray.itemNumber)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.green))

            Text(refillTray.tray.productName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bottom Action Bar

    /// The change note (if any) is fully decided — required before confirming.
    private func rebuildDecided(_ machine: RefillMachine) -> Bool {
        guard viewModel.machineHasRebuild(machine.id) else { return true }
        return viewModel.currentRebuildMachineId == machine.id && viewModel.rebuildReady
    }

    /// Slots of the change note not yet marked done / not possible.
    private var openRebuildCount: Int {
        viewModel.currentRebuild.filter { $0.action == nil }.count
    }

    private func bottomActionBar(_ machine: RefillMachine) -> some View {
        let decided = rebuildDecided(machine)
        return VStack(spacing: 0) {
            Divider()
            if !decided {
                Text("Finish the rebuild first (\(openRebuildCount) open)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .background(.bar)
            }
            HStack(spacing: 12) {
                // More actions: skip the machine, note for the next tour
                Menu {
                    Button {
                        Task { await viewModel.skipMachine(machineId: machine.id) }
                    } label: {
                        Label("Skip machine", systemImage: "forward.end")
                    }
                    .disabled(viewModel.isSaving)

                    Button {
                        noteMachine = NoteTarget(id: machine.id, name: machine.machine.displayName)
                    } label: {
                        Label("Note for next tour", systemImage: "square.and.pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .accessibilityLabel(Text("More actions"))

                Spacer()

                // Confirm button
                Button {
                    HapticFeedback.success.fire()
                    Task {
                        await viewModel.confirmRefill(machineId: machine.id)
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    } else {
                        Label("Confirm Refill", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSaving || !decided)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

#Preview {
    NavigationStack {
        RefillStepView(viewModel: RefillWizardViewModel())
    }
}
