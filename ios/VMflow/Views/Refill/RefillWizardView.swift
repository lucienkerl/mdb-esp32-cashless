import SwiftUI

/// Container for the multi-step refill wizard with step indicator and smooth transitions.
struct RefillWizardView: View {
    @StateObject private var viewModel = RefillWizardViewModel()
    @EnvironmentObject private var realtime: RealtimeService
    @Environment(\.scenePhase) private var scenePhase
    @State private var showResumeAlert = false
    /// "New Tour" on a saved tour whose slot change leftovers were not
    /// booked back yet asks once more.
    @State private var confirmDiscardLeftovers = false

    /// Bumps whenever a sale is inserted, a tray is mutated, or warehouse
    /// stock changes. Used to refresh the packing list so new sales that push
    /// a tray below threshold (new product card) or enlarge an existing
    /// deficit (bigger `totalQuantity`) show up live while the user is
    /// checking off machines.
    private var realtimeVersion: Int {
        realtime.salesVersion + realtime.traysVersion + realtime.warehouseVersion
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step Indicator
            stepIndicator
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(.bar)

            Divider()

            // Step Content
            Group {
                switch viewModel.currentStep {
                case .review:
                    ReviewStepView(viewModel: viewModel)
                case .packing:
                    PackingStepView(viewModel: viewModel)
                case .refill:
                    RefillStepView(viewModel: viewModel)
                case .summary:
                    RefillSummaryView(viewModel: viewModel)
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.spring(duration: 0.35), value: viewModel.currentStep)
        }
        .navigationTitle("Refill Tour")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // `.task` re-fires on every return to the Refill tab (TabView drives
            // appear/disappear). Run the resume-vs-load decision only on the
            // first entry — re-running it mid-tour would re-offer "Resume Tour?"
            // and overwrite live stock with the saved tour-start snapshot.
            guard viewModel.beginInitialLoadIfNeeded() else { return }
            // Check for a saved tour before loading fresh data
            viewModel.checkForSavedTour()
            if viewModel.hasSavedTour {
                showResumeAlert = true
            } else {
                await viewModel.loadData()
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.machines.isEmpty && !viewModel.hasSavedTour {
                ProgressView("Loading machines...")
            }
        }
        .alert("Resume Tour?", isPresented: $showResumeAlert) {
            Button("Resume") { resumeSavedTour() }
            Button("New Tour", role: .destructive) {
                if RefillWizardViewModel.savedTourHasUnreturnedLeftovers {
                    confirmDiscardLeftovers = true
                } else {
                    startNewTour()
                }
            }
        } message: {
            Text("You have an unfinished refill tour. Would you like to continue where you left off?")
        }
        .alert("Leftover goods have not been booked back yet. Finish anyway?", isPresented: $confirmDiscardLeftovers) {
            Button("Finish anyway", role: .destructive) { startNewTour() }
            Button("Resume", role: .cancel) { resumeSavedTour() }
        }
        .alert("Slot change withdrawn", isPresented: .init(
            get: { viewModel.rebuildWithdrawnNotice != nil },
            set: { if !$0 { viewModel.rebuildWithdrawnNotice = nil } }
        )) {
            Button("OK") { viewModel.rebuildWithdrawnNotice = nil }
        } message: {
            Text(viewModel.rebuildWithdrawnNotice ?? "")
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
        .onChange(of: realtimeVersion) { _, _ in
            // Dispatcher picks the right per-step refresh (packing: rebuild
            // list; refill: display-only stock update). Review/summary
            // intentionally do nothing.
            Task { await viewModel.refreshFromRealtime() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // When the app returns from background, the Supabase realtime
            // websocket was disconnected. postgres_changes events that fired
            // during suspension are NOT replayed on reconnect — so a sale
            // that happened while the user drove to the machine would stay
            // invisible. Pull fresh DB state directly on resume.
            guard newPhase == .active else { return }
            Task { await viewModel.refreshFromRealtime() }
        }
    }

    /// Restore the snapshot, then immediately pull live tray stock so the
    /// resumed tour reflects sales that happened while away (the snapshot
    /// holds tour-start stock) and re-flags the "sold during tour" badges
    /// against the live baseline.
    private func resumeSavedTour() {
        if viewModel.resumeTour() {
            Task { await viewModel.refreshFromRealtime() }
        }
    }

    private func startNewTour() {
        RefillWizardViewModel.clearSavedTour()
        viewModel.hasSavedTour = false
        Task { await viewModel.loadData() }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(RefillStep.allCases, id: \.rawValue) { step in
                stepBubble(step)

                if step != RefillStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < viewModel.currentStep.rawValue ? Color.blue : Color(.systemGray4))
                        .frame(height: 2)
                        .animation(.easeInOut, value: viewModel.currentStep)
                }
            }
        }
    }

    /// Whether the user can navigate back to a given step by tapping its bubble.
    private func canNavigateTo(_ step: RefillStep) -> Bool {
        // Can only go backward to already-completed steps
        guard step.rawValue < viewModel.currentStep.rawValue else { return false }
        // Review is only tappable if there are/were replacements to review
        if step == .review { return !viewModel.replacements.isEmpty }
        // Packing is tappable from refill (before tour is confirmed)
        if step == .packing && viewModel.currentStep == .refill { return true }
        return false
    }

    private func stepBubble(_ step: RefillStep) -> some View {
        let isActive = step == viewModel.currentStep
        let isComplete = step.rawValue < viewModel.currentStep.rawValue
        let tappable = canNavigateTo(step)

        return Button {
            guard tappable else { return }
            viewModel.navigateToStep(step)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(isComplete ? Color.blue : (isActive ? Color.blue : Color(.systemGray4)))
                        .frame(width: 36, height: 36)

                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: step.icon)
                            .font(.caption)
                            .foregroundStyle(isActive ? .white : .secondary)
                    }
                }

                Text(step.title)
                    .font(.caption2.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3), value: viewModel.currentStep)
    }
}

#Preview {
    NavigationStack {
        RefillWizardView()
    }
}
