package xyz.vmflow.ui.refill

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.util.UUID
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import xyz.vmflow.data.AuthRepository
import xyz.vmflow.data.LeftoverDestination
import xyz.vmflow.data.PackedDeduction
import xyz.vmflow.data.PlannedChange
import xyz.vmflow.data.RebuildAction
import xyz.vmflow.data.RebuildLeftover
import xyz.vmflow.data.RebuildSlot
import xyz.vmflow.data.RebuildTick
import xyz.vmflow.data.RecentRemoval
import xyz.vmflow.data.RecentRemovalRepository
import xyz.vmflow.data.RefillRepository
import xyz.vmflow.data.RefillReviewLogic
import xyz.vmflow.data.RefillTourLogic
import xyz.vmflow.data.RefillTourStoreHolder
import xyz.vmflow.data.ReplacementSuggestion
import xyz.vmflow.data.SlotChange
import xyz.vmflow.data.SlotChangeApplyItem
import xyz.vmflow.data.SlotChangeRepository
import xyz.vmflow.data.TourLeftover
import xyz.vmflow.data.MachineTourNote
import xyz.vmflow.data.TourNoteRepository
import xyz.vmflow.data.TourNotes
import xyz.vmflow.data.TourStore
import xyz.vmflow.data.RebuiltSlotLine
import xyz.vmflow.data.TrayRepository
import xyz.vmflow.data.WarehouseRepository
import xyz.vmflow.models.CombinedPackingItem
import xyz.vmflow.models.PersistedTourState
import xyz.vmflow.models.Product
import xyz.vmflow.models.ProductCategory
import xyz.vmflow.models.RefillMachine
import xyz.vmflow.models.RefillStep
import xyz.vmflow.models.RefillTray
import xyz.vmflow.models.RefillTrayPayload
import xyz.vmflow.models.TourLogEntry
import xyz.vmflow.models.TrayApplicationResult
import xyz.vmflow.models.Warehouse

/**
 * Everything the refill wizard's steps read. One immutable snapshot,
 * same shape as [xyz.vmflow.ui.warehouse.WarehouseUiState].
 *
 * [packingList] is **stored**, not computed in a getter: the pack step reads
 * it on every frame and [RefillTourLogic.buildCombinedPackingList] groups,
 * allocates and locale-sorts. It is re-derived (see
 * `RefillViewModel.withPackingList`) whenever its inputs — [machines] or
 * [pickOrder] — change.
 *
 * @property machines the tour's machines: every machine with at least one
 *   refillable product group needing refill
 *   ([xyz.vmflow.data.RefillTourLogic.tourMachines], PWA `initTour`), most
 *   urgent first (critical, low, fill; then sold-out + low product count).
 *   Re-sorted at tour start and on resume.
 * @property warehouseStock `productId -> total units in the selected
 *   warehouse`. Empty before the first load, after a failed load, and for a
 *   warehouse that genuinely holds nothing. There is deliberately no
 *   separate "stock loaded" flag: every [RefillTourLogic] entry point that
 *   takes a `stockLoaded` argument short-circuits on
 *   `!stockLoaded || warehouseStock.isEmpty()`, so an empty map already
 *   behaves exactly like "not loaded" — callers pass
 *   `stockLoaded = warehouseStock.isNotEmpty()`. Use [RefillUiState.stockLoaded]
 *   rather than re-deriving that expression at each call site.
 * @property pickOrder `productId -> index` in warehouse walk order. Empty
 *   when the warehouse has no configured layout *or* when reading it failed;
 *   either way the packing list falls back to quantity-descending sorting.
 * @property packedItems `machineId -> productIds the driver packed for it`.
 * @property customQuantities `machineId -> productId -> pinned quantity`.
 * @property activeChip `null` = the "all machines" chip, otherwise a machineId.
 * @property currentMachineId the machine being refilled during
 *   [RefillStep.REFILL].
 * @property tourCompanyId the `company_id` for this tour's `activity_log`
 *   rows, resolved **once** when the tour starts (or resumes) rather than
 *   once per written row: [RefillRepository.writeTourActivity] otherwise
 *   resolves it through the `get-my-organization` edge function on every
 *   call, i.e. once per machine, each time *after* that machine's tray
 *   write has already committed. `null` means the resolution failed — the
 *   repository then falls back to resolving it itself, so a null here costs
 *   round trips, never audit rows.
 * @property error a raw, non-localized message — either an exception's own
 *   text, or (paired with [refillFailedAttempts]) the underlying cause of a
 *   booking that exhausted its retries. Never a sentence this ViewModel
 *   formulated itself: composing the user-facing text is the UI's job (see
 *   [refillFailedAttempts]).
 * @property failedDeductions the packed (machine, product, quantity) triples
 *   whose FIFO warehouse deduction did **not** go through at tour start.
 *   Empty on every healthy tour. Not an [error]: a failed deduction blocks
 *   nothing and the driver must not be gated on it — the goods are in the van
 *   either way. But it must not be invisible either, because the ledger now
 *   under-counts what physically left the warehouse and only a human can
 *   correct that, so the UI shows it once at tour start and again on the
 *   summary. Deliberately **not** part of the persisted tour snapshot: the
 *   deductions run exactly once, at tour start, so a resumed tour has no new
 *   ones to report and re-announcing the old ones after an app kill would be
 *   noise.
 * @property replacements the pre-tour review's slots — every tray whose
 *   product is discontinued and sold out, expired, unavailable in the
 *   warehouse, or missing entirely, each carrying the driver's decision
 *   (`replacementProductId` set, or `isSkipped`). Computed once per load by
 *   [RefillReviewLogic.buildReplacementSuggestions] while the review is still
 *   pending; left in place afterwards (iOS does the same) so the applied
 *   decisions stay inspectable.
 * @property availableProducts active (non-discontinued) products, the
 *   replacement picker's options. Also the lookup behind
 *   [RefillViewModel.categoryIdOfCurrentProduct] and the source of the new
 *   product's name for the swap's audit row.
 * @property productCategories categories for the picker's grouping UI only.
 *   Degrades to empty on a failed fetch — grouping is presentation, and an
 *   ungrouped picker still lets the driver pick.
 * @property isApplyingReplacements the review's write is in flight.
 *   Deliberately **not** [isSaving]: that flag gates the tour path's
 *   re-entrancy guards ([confirmRefill], [skipMachine]), and a review that
 *   borrowed it would be entangled with a state machine it runs before.
 * @property refillFailedAttempts set together with [error] when
 *   [confirmRefill] gives up after [MAX_REFILL_ATTEMPTS] failed
 *   `refill_machine_trays` calls; `null` in every other case, including when
 *   [error] carries a plain exception message. The UI (not this ViewModel)
 *   composes the localized "could not be saved after N attempts: …" sentence
 *   from this count plus [error] — this class must not format user-facing
 *   text itself, since it has no access to localized resources.
 */
data class RefillUiState(
    val isLoading: Boolean = true,
    val isSaving: Boolean = false,
    // PACKING, not REVIEW, and that is load-bearing: REVIEW is only ever
    // correct once `detectReplacements` has actually produced suggestions,
    // and every *failure* path of `performLoad` returns without ever getting
    // there. A REVIEW default therefore turned an ordinary offline entry into
    // a review screen with no cards, whose Continue button was enabled
    // (`allReplacementsHandled` is vacuously true over an empty list) and
    // whose one tap latched `reviewCompleted` — switching the review off for
    // the rest of this ViewModel's life, network or no network.
    //
    // This default was briefly REVIEW to stop the step indicator flashing
    // PACKING as current during the initial load. That is a rendering
    // problem and it is now solved where it belongs: `RefillWizardScreen`
    // does not render the step indicator while `isLoading`.
    val step: RefillStep = RefillStep.PACKING,
    val machines: List<RefillMachine> = emptyList(),
    val warehouses: List<Warehouse> = emptyList(),
    val selectedWarehouseId: String? = null,
    val warehouseStock: Map<String, Int> = emptyMap(),
    val pickOrder: Map<String, Int> = emptyMap(),
    val packedItems: Map<String, Set<String>> = emptyMap(),
    val customQuantities: Map<String, Map<String, Int>> = emptyMap(),
    val activeChip: String? = null,
    val packingList: List<CombinedPackingItem> = emptyList(),
    val replacements: List<ReplacementSuggestion> = emptyList(),
    val availableProducts: List<Product> = emptyList(),
    val productCategories: List<ProductCategory> = emptyList(),
    /**
     * `machineId -> productId -> removal`: products taken out of a machine
     * within the company's cool-down, marked and sorted last in the
     * replacement picker. Empty on a failed fetch — advice, never a blocker.
     */
    val recentRemovals: Map<String, Map<String, RecentRemoval>> = emptyMap(),
    val isApplyingReplacements: Boolean = false,
    val currentMachineId: String? = null,
    val tourId: String = "",
    val tourCompanyId: String? = null,
    val tourLog: List<TourLogEntry> = emptyList(),
    val hasSavedTour: Boolean = false,
    val error: String? = null,
    val refillFailedAttempts: Int? = null,
    val failedDeductions: List<PackedDeduction> = emptyList(),
    /**
     * Slot change requests (web `committedRebuild`): `machineId -> productId
     * -> units` the accepted change-note slots claim from the warehouse,
     * computed before (and therefore ahead of) every normal packing line.
     * Re-derived with [packingList]; only meaningful while packing — after
     * tour start each machine's [RefillMachine.rebuildPacked] is the truth.
     */
    val rebuildCommitted: Map<String, Map<String, Int>> = emptyMap(),
    /**
     * Packing step: `machineId -> productId -> rebuild units` the driver
     * dialled in (e.g. only half a spiral of a new product); missing = the
     * full need. Feeds [rebuildCommitted].
     */
    val rebuildCustomQuantities: Map<String, Map<String, Int>> = emptyMap(),
    /**
     * Packing step: `machineId -> productIds` whose rebuild-only line was
     * ticked as packed. Like a normal product, only ticked rebuild units are
     * booked ([isRebuildTaken]).
     */
    val rebuildTicks: Map<String, Set<String>> = emptyMap(),
    /**
     * Packing step: `machineId -> productId -> tick number` of the ticked
     * rebuild lines. Lines get warehouse stock in the order they were ticked
     * ("ticked = in the box", [SlotChange.commitRebuildInTickOrder]).
     */
    val rebuildTickSequence: Map<String, Map<String, Int>> = emptyMap(),
    val rebuildTickCounter: Int = 0,
    /** Machines whose change note was withdrawn in the office after the tour loaded it. Not persisted. */
    val withdrawnRebuildMachines: Set<String> = emptySet(),
    /**
     * One-shot: name of the machine whose change note turned out withdrawn
     * when slots were already marked rebuilt. Cleared by
     * [RefillViewModel.clearRebuildWithdrawnNotice].
     */
    val rebuildWithdrawnNotice: String? = null,
    /**
     * [warehouseStock] minus [rebuildCommitted]: the stock the normal packing
     * math ([RefillTourLogic]) may still hand out. Same keys as
     * [warehouseStock], so it is empty exactly when that is.
     */
    val packingStock: Map<String, Int> = emptyMap(),
    /** The machine [currentRebuild] belongs to; `null` when the current stop has no change note. */
    val rebuildMachineId: String? = null,
    /** At-machine rebuild cards of the current stop (web `currentRebuild`). Not persisted. */
    val currentRebuild: List<RebuildSlot> = emptyList(),
    /**
     * `productId -> YYYY-MM-DD` best-before suggestion for goods taken out of
     * the current stop's machine (last refill batch of that product into it).
     * Stored with the stop's [tourLeftovers] when the machine is quit.
     */
    val rebuildExpirySuggestions: Map<String, String> = emptyMap(),
    /**
     * Slot change leftovers riding in the van, `machineId -> per product`,
     * booked at the end of the tour ([RefillViewModel.returnTourLeftovers]).
     * Overwritten per machine on every successful quit, so a retry never
     * counts twice. Persisted with the tour.
     */
    val tourLeftovers: Map<String, List<TourLeftover>> = emptyMap(),
    /** [tourLeftovers] have been booked back. Persisted. */
    val leftoversReturned: Boolean = false,
    /** Summary: `productId -> unused (van) units` as counted at the warehouse; missing = computed. */
    val leftoverVanQty: Map<String, Int> = emptyMap(),
    /** Summary: `productId -> units taken out of machines` as counted; missing = computed. */
    val leftoverMachineQty: Map<String, Int> = emptyMap(),
    /** Summary: `productId -> destination` of left-over goods; missing = warehouse. */
    val leftoverDestinations: Map<String, LeftoverDestination> = emptyMap(),
    /**
     * Summary: `productId -> YYYY-MM-DD` best-before date the refiller set; an
     * empty string means explicitly "no date"; missing = the suggestion.
     */
    val leftoverExpiry: Map<String, String> = emptyMap(),
    /** `return_slot_change_leftovers` is in flight. */
    val isReturningLeftovers: Boolean = false,
    /** Raw message of the last failed return; the summary card shows it with a retry. */
    val leftoverReturnError: String? = null,
    /**
     * One-shot: how many review replacements were just queued into change
     * requests, for the "queued for the rebuild" snackbar. Cleared by
     * [RefillViewModel.clearQueuedReplacementNotice].
     */
    val queuedReplacementCount: Int? = null,
    /**
     * Open "notes for the next tour" shown at the top of the packing step
     * ([TourNotes.forPacking]). Loaded with the packing data; a failed load
     * leaves it empty and never blocks the tour. Stays until ticked off
     * ([RefillViewModel.completeTourNote]). Not persisted: only the packing
     * step reads it.
     */
    val tourNotes: List<MachineTourNote> = emptyList(),
    /** Last failure ticking a note off; shown under the notes card. */
    val tourNoteError: String? = null,
    /** The refill step's "note for next tour" dialog; `null` while closed. */
    val tourNoteEditor: TourNoteEditorState? = null,
)

/**
 * The "note for next tour" dialog of one machine. [initialText] is this
 * tour's existing open note of the machine, prefilled once [isLoading] ends.
 * [error] is a raw message; the dialog shows it inline.
 */
data class TourNoteEditorState(
    val machineId: String,
    val isLoading: Boolean = true,
    val initialText: String = "",
    val isSaving: Boolean = false,
    val error: String? = null
)

/**
 * Derived rather than stored: a genuinely empty warehouse and a warehouse
 * whose stock hasn't loaded yet are otherwise indistinguishable from a
 * plain boolean field, so it is computed from [RefillUiState.warehouseStock]
 * instead — matching iOS's guard `selectedWarehouseId != nil && !warehouseStock.isEmpty`.
 */
val RefillUiState.stockLoaded: Boolean
    get() = warehouseStock.isNotEmpty()

/**
 * Whether every review slot has a decision — a replacement product chosen or
 * an explicit skip. The gate on [RefillViewModel.applyReplacementsAndContinue].
 * **Vacuously true for an empty list** — so this must never be the gate on a
 * review that has no suggestions, or Continue is enabled over nothing. Three
 * things keep that from happening: [RefillViewModel.detectReplacements] routes
 * an empty result straight to [RefillStep.PACKING], every failure path of
 * [RefillViewModel.performLoad] lands on [RefillStep.PACKING] rather than
 * leaving the wizard wherever it was, and [RefillWizardScreen] renders a
 * `REVIEW` step with no suggestions as the pack step regardless. Ported from
 * iOS `allReplacementsHandled` (`RefillWizardViewModel.swift:1566-1568`).
 */
val RefillUiState.allReplacementsHandled: Boolean
    get() = replacements.all { it.replacementProductId != null || it.isSkipped }

/** Every slot of the current stop's change note is marked rebuilt or not rebuilt. */
val RefillUiState.rebuildReady: Boolean
    get() = currentRebuild.all { it.action != null }

/** The tour's slot change leftovers per product, summed over every machine (summary card). */
val RefillUiState.aggregatedTourLeftovers: List<TourLeftover>
    get() = SlotChange.aggregateTourLeftovers(tourLeftovers)

/** Leftover goods are in the van and not booked back yet — leaving the summary asks first. */
val RefillUiState.hasUnreturnedLeftovers: Boolean
    get() = !leftoversReturned && aggregatedTourLeftovers.isNotEmpty()

/**
 * The best-before date the summary shows and books for [productId]: what the
 * refiller set ("" = explicitly none), else the suggestion.
 */
fun RefillUiState.leftoverExpiryFor(leftover: TourLeftover): String? =
    if (leftover.productId in leftoverExpiry) leftoverExpiry[leftover.productId]?.takeIf { it.isNotBlank() }
    else leftover.suggestedExpiry

/** Rebuild units committed to a product across every machine (packing step). */
fun RefillUiState.rebuildCommittedTotal(productId: String): Int =
    rebuildCommitted.values.sumOf { it[productId] ?: 0 }

/** Units the accepted change-note slots of one machine need of a product from the warehouse. */
fun RefillUiState.rebuildNeed(machineId: String, productId: String): Int {
    val machine = machines.find { it.machine.id == machineId } ?: return 0
    val items = machine.acceptedChangeItems
    if (items.isEmpty()) return 0
    return SlotChange.rebuildPackNeeds(
        items,
        machine.trays.associate { it.tray.id to it.tray.currentStock }
    )[productId] ?: 0
}

/**
 * The driver takes one machine's rebuild units of a product along: its line
 * of the product is ticked ("ticked = in the box", [RefillViewModel.toggleLine]).
 * One line covers refill and rebuild units alike. Unticked units are not booked.
 */
fun RefillUiState.isRebuildTaken(machineId: String, productId: String): Boolean =
    rebuildTicks[machineId]?.contains(productId) == true

/**
 * Drives the refill wizard. This half of it loads machines/trays,
 * warehouses, the selected warehouse's stock and its physical pick order,
 * and owns the state contract above. Ported from iOS
 * `RefillWizardViewModel.loadData` (`RefillWizardViewModel.swift:1213-1380`)
 * and `loadWarehouseStock` (L1381-1441).
 *
 * The pack actions (Task 7), `startTour` (Task 8) and the
 * refill/skip/summary/resume actions (Task 9) are added to this class by
 * those tasks; they all read and write the same [RefillUiState].
 *
 * No unit tests: the arithmetic this class orchestrates lives in
 * [RefillTourLogic] and is tested there. Anything worth testing that shows
 * up in a later task belongs in `RefillTourLogic`, not in a mock harness
 * around this ViewModel.
 */
class RefillViewModel : ViewModel() {

    /** Held as a plain field rather than a constructor parameter. */
    private val tourStore: TourStore = RefillTourStoreHolder.instance

    private val _uiState = MutableStateFlow(RefillUiState())
    val uiState: StateFlow<RefillUiState> = _uiState.asStateFlow()

    /**
     * Entry gate. The wizard's load runs **once per ViewModel lifetime**,
     * not on every tab re-selection: the screen's `LaunchedEffect(Unit)`
     * re-fires whenever the composable re-enters composition while the
     * ViewModel (scoped to the nav entry) survives — and on iOS exactly that
     * reset the refill view in the middle of a tour, restoring tour-start
     * stock over live values.
     *
     * Re-armed only by a *failed* initial load that left no state behind
     * (see [rearmEntryGateUnlessTourInMemory]), so returning to the tab
     * retries instead of being permanently skipped, and never while a tour
     * is in memory. `reset()` (Task 9) re-arms it deliberately so the next
     * visit loads fresh.
     */
    private var didRunInitialLoad = false

    /**
     * Whether the pre-tour review has been dealt with in this wizard run.
     * Flow state, not display state — hence a plain field rather than a
     * [RefillUiState] property: no UI reads it, it only decides whether
     * [performLoad] recomputes the review's suggestions. Without it,
     * [applyReplacementsAndContinue]'s reload would rebuild the very
     * suggestions it just applied (the swapped-in products sit in empty
     * slots, i.e. `currentStock == 0`, and a product the warehouse doesn't
     * stock would come straight back as [xyz.vmflow.data.ReplacementReason.NO_STOCK])
     * and bounce the driver back into the review, forever.
     *
     * Only ever latched by an apply over a **non-empty** suggestion list —
     * see [applyReplacementsAndContinue]'s empty guard. A review that never
     * had anything to show has not happened, and must not be able to switch
     * itself off.
     *
     * Cleared by [reset] alongside [didRunInitialLoad] — the next wizard run
     * is a new tour and must review again. Mirrors iOS `reviewCompleted`
     * (`RefillWizardViewModel.swift`).
     */
    private var reviewCompleted = false

    /**
     * Every machine with trays from the last load — the pre-tour review's
     * input. [RefillUiState.machines] holds only the tour's machines
     * ([RefillTourLogic.tourMachines]). Flow state, like [reviewCompleted].
     */
    private var reviewMachines: List<RefillMachine> = emptyList()

    /** Call from the screen on entry. No-op after the first call — see [didRunInitialLoad]. */
    fun loadDataIfNeeded() {
        if (didRunInitialLoad) return
        didRunInitialLoad = true
        loadData()
    }

    /**
     * Machines + trays, warehouses, then the **first** warehouse's stock and
     * pick order (iOS auto-selects the first warehouse the same way).
     *
     * This is the *initial* load only — it overwrites [RefillUiState.machines]
     * wholesale, which is also where `isPacked`/`isRefilled`/`isSkipped` and
     * every tray's `fillAmount` live. Calling it mid-tour would silently
     * discard the driver's in-progress fills and pack state. It therefore
     * no-ops while a tour is in memory (see [isTourInMemory]) — it
     * deliberately does **not** double as a mid-tour pull-to-refresh. The
     * review step is *not* such a state: it holds no tour and its whole
     * purpose is to be followed by a reload. This app has no mid-tour
     * refresh at all:
     * iOS's step-specific `refreshDuringPacking`/`refreshDuringRefill`
     * (`RefillWizardViewModel.swift:1199-1211`) were not ported, and a
     * caller that wants one has to add them rather than reach for this
     * function.
     */
    fun loadData() {
        if (isTourInMemory(_uiState.value)) return
        viewModelScope.launch { performLoad() }
    }

    /**
     * [loadData]'s body, as a suspending function so
     * [applyReplacementsAndContinue] can **await** the reload before it
     * declares the review finished — iOS `await loadData()`
     * (`RefillWizardViewModel.swift:1605`). The entry guard stays on
     * [loadData]: the review's caller has already established that no tour is
     * running (it cannot be reached from the refill step), and it must not be
     * able to have its reload silently skipped.
     *
     * **Every failure return below lands on [RefillStep.PACKING]** — written
     * out explicitly rather than left to the default, because "wherever the
     * step happened to be" is exactly what made a failed load render an empty
     * review screen. Only [detectReplacements] may route to
     * [RefillStep.REVIEW], and only once it holds suggestions to show. The
     * pack step is the right landing place for a failed load: it renders its
     * own empty/retry affordances, and the re-armed entry gate means the next
     * visit loads again and can still route into the review.
     */
    private suspend fun performLoad() {
        val hasSavedTour = tourStore.hasSavedTour
        // `hasSavedTour = true` must only ever be written in the same
        // update as `isLoading = true`, never on its own — the resume
        // prompt in RefillWizardScreen is gated on `!isLoading` and
        // relies on that pairing to never fire mid-load, while `machines`
        // is about to be overwritten below.
        _uiState.update {
            it.copy(
                isLoading = true,
                error = null,
                refillFailedAttempts = null,
                hasSavedTour = hasSavedTour
            )
        }

        val machinesResult = RefillRepository.fetchRefillMachines()
            .map { machines -> withChangeRequests(machines) }
        machinesResult.fold(
            onSuccess = { machines ->
                // `withSyncedPackedState()` rather than `withPackingList()`:
                // `isPacked` is *derived* from `packedItems`, and replacing
                // `machines` wholesale drops it. `packedItems` survives a
                // reload, so without the re-derivation every tick and
                // quantity still renders as packed while the header counts
                // zero packed machines and `startTour()` hard-returns.
                // Defensive: nothing reaches this branch with a non-empty
                // `packedItems` today, and no future caller should be able
                // to break the invariant either.
                // The review looks at every machine; the tour only at the ones
                // with a refillable product needing refill, most urgent first
                // (PWA `initTour`).
                reviewMachines = machines
                _uiState.update {
                    it.copy(machines = RefillTourLogic.tourMachines(machines)).withSyncedPackedState()
                }
                // Alongside, never in the way: a failing load shows no notes.
                viewModelScope.launch { loadTourNotes() }
            },
            onFailure = { e ->
                _uiState.update {
                    it.copy(isLoading = false, step = RefillStep.PACKING, error = e.message)
                }
                rearmEntryGateUnlessTourInMemory()
            }
        )
        if (machinesResult.isFailure) return

        val warehousesResult = WarehouseRepository.fetchWarehouses()
        warehousesResult.fold(
            onSuccess = { warehouses ->
                _uiState.update { state ->
                    state.copy(
                        warehouses = warehouses,
                        selectedWarehouseId = state.selectedWarehouseId ?: warehouses.firstOrNull()?.id
                    )
                }
            },
            onFailure = { e ->
                // Machines did load, so the pack step can still render —
                // but without a warehouse there is no stock cap, so the
                // gate is re-armed to retry on the next entry (iOS does
                // the same: the whole `loadData` catch re-arms).
                _uiState.update {
                    it.copy(isLoading = false, step = RefillStep.PACKING, error = e.message)
                }
                rearmEntryGateUnlessTourInMemory()
            }
        )
        if (warehousesResult.isFailure) return

        _uiState.value.selectedWarehouseId?.let { loadWarehouseData(it) }

        // The review runs off the data just loaded (trays, warehouse totals)
        // and is what decides whether this load lands on REVIEW or PACKING —
        // hence last, and only while the review is still pending. A failure
        // here lands on PACKING and re-arms the gate, exactly like the
        // fetches above: iOS's equivalent fetches throw into `loadData`'s
        // catch, which also leaves the wizard at the pack step with an error.
        // `step` is set explicitly rather than left alone: a caller can reach
        // this while the wizard already sits at REVIEW, and the step must
        // never survive a load that failed to refresh the very suggestions
        // that step renders.
        if (!reviewCompleted && !detectReplacements()) {
            _uiState.update { it.copy(isLoading = false, step = RefillStep.PACKING) }
            rearmEntryGateUnlessTourInMemory()
            return
        }

        _uiState.update { it.copy(isLoading = false) }
    }

    /**
     * The open notes for the packing step. Errors are logged and leave the
     * list empty — the notes are a hint, never a gate on the tour.
     */
    private suspend fun loadTourNotes() {
        TourNoteRepository.fetchOpenNotes()
            .onSuccess { notes ->
                _uiState.update { state ->
                    // A tour that started meanwhile has already taken its notes.
                    if (state.tourId.isNotEmpty()) state
                    else state.copy(tourNotes = TourNotes.forPacking(notes, state.tourId))
                }
            }
            .onFailure { e -> Log.w(TAG, "Loading tour notes failed", e) }
    }

    /**
     * Attaches each machine's open slot change request ("Änderungsvermerk")
     * to the freshly loaded machines. A failing lookup never blocks a normal
     * tour — it degrades to "no change notes", as on the web.
     *
     * Declines the refiller already made in this wizard run survive the
     * reload (the review's queued replacements trigger one), so un-ticking a
     * slot is never silently undone. New items start accepted.
     */
    private suspend fun withChangeRequests(machines: List<RefillMachine>): List<RefillMachine> {
        val requests = SlotChangeRepository.fetchOpenRequests(machines.map { it.machine.id })
            .getOrDefault(emptyMap())
        val declined = _uiState.value.machines
            .flatMap { it.changeRequest?.items.orEmpty() }
            .filter { !it.accepted }
            .mapTo(HashSet()) { it.id }
        return machines.map { machine ->
            val request = requests[machine.machine.id] ?: return@map machine.copy(changeRequest = null)
            machine.copy(
                changeRequest = request.copy(
                    items = request.items.map { if (it.id in declined) it.copy(accepted = false) else it }
                )
            )
        }
    }

    /**
     * Switches the active warehouse and reloads its stock and pick order.
     * The selection is written immediately (the picker must react at once);
     * the fetched data is written only if the selection still matches when
     * the responses land — see [loadWarehouseData].
     */
    fun selectWarehouse(id: String) {
        if (_uiState.value.selectedWarehouseId == id) return
        _uiState.update { it.copy(selectedWarehouseId = id) }
        viewModelScope.launch { loadWarehouseData(id) }
    }

    /**
     * Retry path for the pack step's "no warehouse stock" banner. Re-fetches
     * the selected warehouse's stock totals and pick order — and nothing
     * else.
     *
     * Deliberately **not** [loadData]: that replaces [RefillUiState.machines]
     * wholesale, which is where `isPacked` lives, and reloading the machine
     * list is neither what failed nor what the driver needs. [selectWarehouse]
     * can't serve as the retry either — it early-returns for the
     * already-selected id — hence this separate entry point. The stale-
     * response guard lives in [loadWarehouseData] and still applies.
     *
     * With no warehouse selected — the *warehouses* fetch is what failed, or
     * the company has none — the warehouse list is fetched first, since there
     * would otherwise be nothing to load stock for. `machines` is never
     * touched on either path.
     */
    fun reloadWarehouseStock() {
        viewModelScope.launch {
            if (_uiState.value.selectedWarehouseId == null) {
                WarehouseRepository.fetchWarehouses().fold(
                    onSuccess = { warehouses ->
                        _uiState.update { state ->
                            state.copy(
                                warehouses = warehouses,
                                selectedWarehouseId = state.selectedWarehouseId
                                    ?: warehouses.firstOrNull()?.id
                            )
                        }
                    },
                    onFailure = { e -> _uiState.update { it.copy(error = e.message) } }
                )
            }
            val warehouseId = _uiState.value.selectedWarehouseId ?: return@launch
            loadWarehouseData(warehouseId)
        }
    }

    /** Clears a surfaced error after the UI has shown it (e.g. via a snackbar). */
    fun clearError() {
        _uiState.update { it.copy(error = null, refillFailedAttempts = null) }
    }

    /**
     * Loads one warehouse's stock totals and pick order concurrently, then
     * writes **both** into the state in a single update — and only if
     * [warehouseId] is still the selected warehouse.
     *
     * Without that check a slow response for a warehouse the user has since
     * switched away from would overwrite the newer warehouse's stock (and
     * its pick order, and therefore the packing list's sort order) with
     * stale numbers, silently mis-capping every packing quantity. Both
     * halves of the result — including any error from the stock fetch — are
     * discarded together, because a stale error is as misleading as stale
     * stock.
     *
     * A failing pick order is **not** an error the user sees: it degrades to
     * an empty map and the packing list sorts by quantity instead, matching
     * iOS `fetchOrderedProductIdsOrEmpty`.
     */
    private suspend fun loadWarehouseData(warehouseId: String) {
        val (stockResult, pickOrderResult) = coroutineScope {
            val stock = async { RefillRepository.fetchWarehouseStockTotals(warehouseId) }
            val pickOrder = async { RefillRepository.fetchPickOrder(warehouseId) }
            stock.await() to pickOrder.await()
        }

        if (_uiState.value.selectedWarehouseId != warehouseId) return

        val pickOrder = pickOrderResult.getOrDefault(emptyMap())

        stockResult.fold(
            onSuccess = { stock ->
                _uiState.update {
                    it.copy(warehouseStock = stock, pickOrder = pickOrder).withPackingList()
                }
            },
            onFailure = { e ->
                // Stock is what caps packing quantities, so a failure here
                // is user-visible (iOS surfaces it too). The pick order that
                // did arrive is still applied.
                _uiState.update {
                    it.copy(pickOrder = pickOrder, error = e.message).withPackingList()
                }
            }
        )
    }

    /**
     * Re-derives [RefillUiState.packingList] from the two inputs it depends
     * on. Every update that changes `machines` or `pickOrder` must go
     * through this — including the ones later tasks add.
     */
    private fun RefillUiState.withPackingList(): RefillUiState {
        val committed = computeRebuildCommitted()
        return copy(
            packingList = RefillTourLogic.buildCombinedPackingList(machines, pickOrder),
            rebuildCommitted = committed,
            packingStock = SlotChange.stockAfterRebuild(warehouseStock, committed)
        )
    }

    /**
     * Units the accepted change-note slots claim from the warehouse: the
     * ticked lines in the order they were ticked, each seeing the refills of
     * the other machines as taken ([SlotChange.commitRebuildInTickOrder]).
     * Needs are computed from the stock known now: stock that moves to
     * another slot of the same machine needs no warehouse stock
     * ([SlotChange.rebuildPackNeeds]).
     */
    private fun RefillUiState.computeRebuildCommitted(): Map<String, Map<String, Int>> {
        val ticks = mutableListOf<RebuildTick>()
        machines.forEachIndexed { index, machine ->
            val items = machine.acceptedChangeItems
            if (items.isEmpty()) return@forEachIndexed
            val id = machine.machine.id
            val needs = SlotChange.rebuildPackNeeds(items, machine.trays.associate { it.tray.id to it.tray.currentStock })
            for ((pid, need) in needs) {
                if (need <= 0 || !isRebuildTaken(id, pid)) continue
                ticks += RebuildTick(id, pid, need, rebuildTickSequence[id]?.get(pid) ?: Int.MAX_VALUE, index)
            }
        }
        val refills = HashMap<String, MutableMap<String, Int>>()
        for (machine in machines) {
            for (pid in packedItems[machine.machine.id].orEmpty()) {
                refills.getOrPut(pid) { HashMap() }[machine.machine.id] =
                    RefillTourLogic.packingQuantity(machine, pid, customQuantities)
            }
        }
        return SlotChange.commitRebuildInTickOrder(
            ticks = ticks,
            warehouseStock = warehouseStock,
            stockLoaded = stockLoaded,
            custom = rebuildCustomQuantities,
            refills = refills
        )
    }

    /**
     * Re-opens the entry gate after a failed load, unless a tour is already
     * in memory — a running tour must never be reloaded out from under the
     * driver.
     */
    private fun rearmEntryGateUnlessTourInMemory() {
        if (!isTourInMemory(_uiState.value)) didRunInitialLoad = false
    }

    /**
     * Whether a **tour** is in memory, i.e. whether the wizard holds state a
     * wholesale reload would destroy: the driver is at the refill or summary
     * step, or a tour id has already been minted. Shared by [loadData]'s
     * mid-tour guard, [rearmEntryGateUnlessTourInMemory] and [startTour]'s
     * re-entrancy guard so the three can't drift apart.
     *
     * Spelled out as an explicit step list rather than the shorter
     * `step != PACKING`, which is what it used to say. That form was
     * equivalent only as long as PACKING was the wizard's first step: with
     * [RefillStep.REVIEW] in front of it, "not at the pack step" is true
     * during the review too — and would turn [performLoad] into a no-op
     * exactly when [applyReplacementsAndContinue] needs it to pick up the
     * slots' new products. The review holds no tour: no id has been minted,
     * nothing is booked, and a reload is precisely what it wants.
     */
    private fun isTourInMemory(state: RefillUiState): Boolean =
        state.step == RefillStep.REFILL ||
            state.step == RefillStep.SUMMARY ||
            state.tourId.isNotEmpty()

    // ---------------------------------------------------------------------
    // Review step (Task 4). Detection lives in [RefillReviewLogic] (pure,
    // unit-tested); this section is orchestration only. Ported from iOS
    // `RefillWizardViewModel.swift` L1258-1351 (detection inside `loadData`),
    // L1547-1613 (the actions) and L473-479 (`currentCategoryId`).
    // ---------------------------------------------------------------------

    /**
     * Fetches the review's three remaining inputs — the picker's products and
     * categories, and the selected warehouse's raw batches for the expiry
     * rule — then publishes the suggestions and routes the wizard.
     *
     * Returns `false` when an input the review cannot do without failed, so
     * [performLoad] can surface the error and re-arm the entry gate. A failed
     * *category* fetch is not one of those: grouping is presentation, and an
     * ungrouped picker still lets the driver pick — so it degrades to an empty
     * list, the same treatment [loadWarehouseData] gives a failed pick order.
     * (iOS aborts its whole load on it; this is a deliberate divergence.)
     *
     * **No suggestions means no review**: the step goes straight to
     * [RefillStep.PACKING], as on iOS. A driver with nothing to replace must
     * never be shown an empty intermediate screen.
     */
    private suspend fun detectReplacements(): Boolean {
        val products = TrayRepository.fetchProducts().getOrElse { e ->
            _uiState.update { it.copy(error = e.message) }
            return false
        }
        val categories = RefillRepository.fetchProductCategories().getOrDefault(emptyList())

        // Batches, not the aggregated totals: the expiry rule needs every
        // batch's date, which the `productId -> total` map has thrown away.
        // Only fetched here, on the one load that computes the review.
        val warehouseId = _uiState.value.selectedWarehouseId
        val expired = if (warehouseId == null) {
            // No warehouse at all — iOS skips the expiry pass the same way.
            // Every other reason still applies.
            emptySet()
        } else {
            val batches = WarehouseRepository.fetchWarehouseStock(warehouseId).getOrElse { e ->
                _uiState.update { it.copy(error = e.message) }
                return false
            }
            RefillReviewLogic.expiredProductIds(batches = batches, today = todayIsoDate())
        }

        // Read after the awaits above, not before: `machines` and
        // `warehouseStock` were written by earlier steps of this same load.
        val state = _uiState.value
        // Every machine, not only the tour's: a sold-out discontinued product
        // in an otherwise fine machine still deserves a replacement.
        val suggestions = RefillReviewLogic.buildReplacementSuggestions(
            machines = reviewMachines.map { it.machine },
            traysByMachine = reviewMachines.associate { machine ->
                machine.machine.id to machine.trays.map { it.tray }
            },
            stockedProductIds = state.warehouseStock.filterValues { it > 0 }.keys,
            expiredProductIds = expired,
            // A failed or missing stock load leaves `warehouseStock` empty —
            // see [RefillUiState.stockLoaded] — and without this, the NO_STOCK
            // rule would fire for every empty slot in the fleet on one
            // transient failure. Use the shared extension rather than
            // re-deriving `warehouseStock.isNotEmpty()` here.
            stockLoaded = state.stockLoaded
        ).let { found ->
            // A slot that already has a pending change is handled by its
            // change note during the tour — suggesting a second replacement
            // for it would only overwrite the office's plan.
            val pendingTrayIds = reviewMachines
                .flatMap { it.changeRequest?.items.orEmpty() }
                .mapTo(HashSet()) { it.trayId }
            found.filter { it.trayId !in pendingTrayIds }
        }

        // Only when there is something to review; one call for every
        // machine with a suggestion.
        val removals = if (suggestions.isEmpty()) {
            emptyMap()
        } else {
            RecentRemovalRepository.fetch(suggestions.map { it.machineId }.distinct())
                .getOrDefault(emptyMap())
        }

        _uiState.update {
            it.copy(
                availableProducts = products,
                productCategories = categories,
                recentRemovals = removals,
                replacements = suggestions,
                step = if (suggestions.isEmpty()) RefillStep.PACKING else RefillStep.REVIEW
            )
        }
        return true
    }

    /**
     * Chooses a replacement product for one review slot, clearing any earlier
     * skip — the two decisions are mutually exclusive. Ported from iOS
     * `setReplacement`.
     */
    fun setReplacement(trayId: String, productId: String) {
        _uiState.update { state ->
            state.copy(
                replacements = state.replacements.map {
                    if (it.trayId == trayId) {
                        it.copy(replacementProductId = productId, isSkipped = false)
                    } else {
                        it
                    }
                }
            )
        }
    }

    /**
     * Leaves one review slot as it is, clearing any chosen replacement — the
     * opposite of [setReplacement]. Ported from iOS `skipReplacement`.
     */
    fun skipReplacement(trayId: String) {
        _uiState.update { state ->
            state.copy(
                replacements = state.replacements.map {
                    if (it.trayId == trayId) {
                        it.copy(isSkipped = true, replacementProductId = null)
                    } else {
                        it
                    }
                }
            )
        }
    }

    /**
     * Category of the product currently sitting in a review slot, so the
     * picker can open on it. `null` when the slot is unknown, unassigned, its
     * product is not among [RefillUiState.availableProducts] (a discontinued
     * one is not), or it has no category. Ported from iOS `currentCategoryId`.
     */
    fun categoryIdOfCurrentProduct(trayId: String): String? {
        val state = _uiState.value
        val productId = state.replacements
            .find { it.trayId == trayId }?.currentProductId ?: return null
        return state.availableProducts.find { it.id == productId }?.category
    }

    /**
     * Queues the chosen replacements into each machine's slot change request,
     * then reloads and moves on to [RefillStep.PACKING].
     *
     * **The review never writes `machine_trays`.** A replacement is a change
     * of the machine's layout, and layout changes only happen at the machine:
     * the chosen slot joins the machine's open change request
     * (`save_slot_change_request`, merged with what the office planned — see
     * [queueReplacements]), the reload brings it back as a change note, and
     * the refiller rebuilds it during the tour like any other planned slot
     * (`apply_slot_change`). The web's analysis "replace" button does the
     * same (`useMachineAnalysis.applySwap`).
     *
     * Only slots with a chosen product are queued — a skipped slot keeps
     * what it has — and nothing is queued at all until every slot has a
     * decision ([allReplacementsHandled]), matching iOS.
     *
     * **A failed save is blocking.** The loop stops at the first failing
     * machine, surfaces it and leaves the wizard at [RefillStep.REVIEW] with
     * the driver's decisions intact, so they can retry. A retry resumes:
     * [toApply] excludes anything already marked
     * [ReplacementSuggestion.isApplied].
     *
     * The reload afterwards is **awaited** — it is what turns the queued
     * slots into change notes. A failure of the *reload* is not blocking
     * (the requests are saved), so the step advances anyway with the error
     * surfaced, the "stale-list window": the pack step then lacks the new
     * change notes until the next successful load.
     *
     * Ported from iOS `applyReplacementsAndContinue`.
     */
    fun applyReplacementsAndContinue() {
        val snapshot = _uiState.value
        // Re-entrancy guard: a second tap would re-run the same saves.
        // iOS relies on `isSaving`
        // disabling its button; this does not depend on the UI.
        if (snapshot.isApplyingReplacements) return
        // Nothing to review means no review happened, so there is nothing to
        // apply and nothing to declare finished. Without this, one tap on the
        // Continue button of a review that a *failed* load left empty
        // ([allReplacementsHandled] is vacuously true over an empty list)
        // would latch [reviewCompleted] and switch the review off for the
        // rest of this ViewModel's life — including after the network comes
        // back and the re-armed entry gate loads the data successfully. The
        // driver would pack the van with no review and nothing would say so.
        if (snapshot.replacements.isEmpty()) return
        if (!snapshot.allReplacementsHandled) return

        val toApply = snapshot.replacements.filter {
            it.replacementProductId != null && !it.isApplied
        }
        _uiState.update { it.copy(isApplyingReplacements = true, error = null) }

        viewModelScope.launch {
            // One save per machine: `save_slot_change_request` replaces the
            // machine's whole pending plan, so each machine's chosen slots go
            // in together, merged into what the office already planned.
            for ((machineId, suggestions) in toApply.groupBy { it.machineId }) {
                val failure = queueReplacements(machineId, suggestions).exceptionOrNull()
                if (failure != null) {
                    _uiState.update {
                        it.copy(isApplyingReplacements = false, error = failure.message)
                    }
                    return@launch
                }
                // Marked immediately: a retry after a later machine failed
                // must not queue these again (harmless, but pointless).
                val queuedIds = suggestions.mapTo(HashSet()) { it.trayId }
                _uiState.update { state ->
                    state.copy(
                        replacements = state.replacements.map {
                            if (it.trayId in queuedIds) it.copy(isApplied = true) else it
                        }
                    )
                }
            }

            // Before the reload, or it would rebuild the suggestions it just
            // applied and bounce straight back into the review. The reload
            // re-fetches the change requests, so the queued slots show up as
            // change notes in the pack step right away.
            reviewCompleted = true
            performLoad()
            // Advances regardless of whether the reload above succeeded — see
            // the function doc's "stale-list window" paragraph.
            _uiState.update {
                it.copy(
                    step = RefillStep.PACKING,
                    isApplyingReplacements = false,
                    queuedReplacementCount = toApply.size.takeIf { count -> count > 0 }
                )
            }
        }
    }

    /**
     * Queues [suggestions] (all of one machine) into that machine's open slot
     * change request: the existing pending items are kept, a slot that
     * already had one gets its new product but keeps the planned capacity,
     * any other slot keeps its current capacity. Port of the web's
     * `useMachineAnalysis.applySwap`. Never touches `machine_trays`.
     */
    private suspend fun queueReplacements(
        machineId: String,
        suggestions: List<ReplacementSuggestion>
    ): Result<Unit> {
        val open = SlotChangeRepository.fetchOpenRequests(listOf(machineId))
            .getOrElse { return Result.failure(it) }[machineId]
        val capacityByTray = reviewMachines
            .firstOrNull { it.machine.id == machineId }
            ?.trays?.associate { it.tray.id to it.tray.capacity }
            .orEmpty()

        val changes = LinkedHashMap<String, PlannedChange>()
        open?.items?.forEach {
            changes[it.trayId] = PlannedChange(it.trayId, it.toProductId, it.toCapacity)
        }
        for (suggestion in suggestions) {
            val productId = suggestion.replacementProductId ?: continue
            val capacity = changes[suggestion.trayId]?.toCapacity
                ?: capacityByTray[suggestion.trayId]
                ?: return Result.failure(IllegalStateException("Tray ${suggestion.trayId} no longer exists"))
            changes[suggestion.trayId] = PlannedChange(suggestion.trayId, productId, capacity)
        }
        return SlotChangeRepository.saveRequest(machineId, changes.values.toList()).map { }
    }

    /** The "queued for the rebuild" notice has been shown. */
    fun clearQueuedReplacementNotice() {
        _uiState.update { it.copy(queuedReplacementCount = null) }
    }

    /**
     * Leaves every slot the driver hasn't decided on as it is, keeping the
     * replacements they *did* choose, and then runs
     * [applyReplacementsAndContinue]. Ported from iOS `skipReview`.
     */
    fun skipReview() {
        if (_uiState.value.isApplyingReplacements) return
        _uiState.update { state ->
            state.copy(
                replacements = state.replacements.map {
                    if (it.replacementProductId == null && !it.isSkipped) {
                        it.copy(isSkipped = true)
                    } else {
                        it
                    }
                }
            )
        }
        applyReplacementsAndContinue()
    }

    /**
     * Today as `YYYY-MM-DD` in the device's zone, the format
     * [RefillReviewLogic.expiredProductIds] compares against (and the one
     * `warehouse_stock_batches.expiration_date` is stored in). Local, not UTC:
     * "expired" is a shelf-life judgement made where the driver stands, and
     * iOS's `todayDateString()` is local too.
     */
    private fun todayIsoDate(): String =
        Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault()).date.toString()

    // ---------------------------------------------------------------------
    // Pack step (Task 7). All quantity/capping/commitment math lives in
    // [RefillTourLogic] and is called with named arguments throughout this
    // section — several of its functions take multiple consecutive
    // same-typed map parameters, and a transposition compiles silently.
    // Ported from iOS `RefillWizardViewModel.swift` L613-945.
    // ---------------------------------------------------------------------

    /**
     * Quantity to show in the Pack UI for a machine-product pair. Delegates
     * to [RefillTourLogic.displayQuantity]. Ported from iOS `displayQuantity`.
     */
    fun displayQuantity(machineId: String, productId: String): Int {
        val state = _uiState.value
        return RefillTourLogic.displayQuantity(
            machines = state.machines,
            machineId = machineId,
            productId = productId,
            packedItems = state.packedItems,
            customQuantities = state.customQuantities,
            warehouseStock = state.packingStock,
            stockLoaded = state.stockLoaded
        )
    }

    /**
     * Max quantity a machine could pack for a product, capped by tray
     * capacity and remaining warehouse stock. Delegates to
     * [RefillTourLogic.maxPackingQuantity]. Ported from iOS `maxPackingQuantity`.
     */
    fun maxPackingQuantity(machineId: String, productId: String): Int {
        val state = _uiState.value
        return RefillTourLogic.maxPackingQuantity(
            machines = state.machines,
            machineId = machineId,
            productId = productId,
            packedItems = state.packedItems,
            customQuantities = state.customQuantities,
            warehouseStock = state.packingStock,
            stockLoaded = state.stockLoaded
        )
    }

    /** Whether a specific machine-product pair has been packed. Ported from iOS `isMachinePacked`. */
    fun isPacked(machineId: String, productId: String): Boolean =
        _uiState.value.packedItems[machineId]?.contains(productId) == true

    /**
     * Whether a machine-product pair is out of remaining warehouse stock.
     * Delegates to [RefillTourLogic.isOutOfStockForMachine]. Ported from iOS
     * `isOutOfStockForMachine`.
     */
    fun isOutOfStockForMachine(machineId: String, productId: String): Boolean {
        val state = _uiState.value
        return RefillTourLogic.isOutOfStockForMachine(
            machines = state.machines,
            machineId = machineId,
            productId = productId,
            packedItems = state.packedItems,
            customQuantities = state.customQuantities,
            warehouseStock = state.packingStock,
            stockLoaded = state.stockLoaded
        )
    }

    /**
     * Product-level (not machine-scoped) out-of-stock check used only to
     * decide whether a picklist row is worth showing at all. Ported from iOS
     * `isOutOfWarehouseStock(productId:)` (distinct from the machine-scoped
     * [isOutOfStockForMachine] above, which also short-circuits `false` for
     * a machine that already packed its allocation).
     */
    private fun isOutOfWarehouseStock(state: RefillUiState, productId: String): Boolean {
        if (!state.stockLoaded) return false
        return RefillTourLogic.remainingWarehouseStock(
            machines = state.machines,
            productId = productId,
            packedItems = state.packedItems,
            customQuantities = state.customQuantities,
            warehouseStock = state.packingStock
        ) <= 0
    }

    /**
     * [RefillUiState.packingList], with rows hidden that have no warehouse
     * stock left **and** nothing packed yet — they'd just waste screen
     * space. A partially-packed row (or a row with any machine need already
     * packed) stays visible so the driver can still correct it. Ported from
     * iOS `visibleCombinedPackingList`.
     */
    fun visiblePackingList(): List<CombinedPackingItem> {
        val state = _uiState.value
        return state.packingList.filter { item ->
            val anyPacked = item.machineNeeds.any { need -> isPacked(need.machineId, item.productId) }
            anyPacked || !isOutOfWarehouseStock(state, item.productId)
        }
    }

    /**
     * Sets which chip filters the Pack step's list: `null` is the "all
     * machines" chip, otherwise one machine's chip. Ported from iOS
     * `activeChip` assignment (`ChipFilter.all` / `.machine(id)`).
     */
    fun selectChip(machineId: String?) {
        _uiState.update { it.copy(activeChip = machineId) }
    }

    /**
     * Potential box size for a chip: sum of [displayQuantity] over every
     * `(machine, product)` pair the chip covers, skipping pairs that are
     * out-of-stock and not yet packed (they don't render in the picklist
     * either). `null` sums across every machine. Ported from iOS
     * `chipItemCount`.
     */
    fun chipItemCount(machineId: String?): Int {
        val state = _uiState.value
        val scope = if (machineId == null) state.machines.map { it.machine.id } else listOf(machineId)
        return scope.sumOf { id -> state.packLines(id).sumOf { it.total } }
    }

    /**
     * True once every line of a chip is in the box. `null` requires every
     * machine with lines to be done. Ported from iOS `chipIsFullyPacked`.
     */
    fun chipIsFullyPacked(machineId: String?): Boolean {
        val state = _uiState.value
        val scope = if (machineId == null) state.machines.map { it.machine.id } else listOf(machineId)
        val lines = scope.flatMap { state.packLines(it) }
        return lines.isNotEmpty() && lines.all { it.ticked }
    }

    /**
     * Sets a custom packing quantity for a machine-product pair, clamped to
     * [RefillTourLogic.maxPackingQuantity]. Does not touch [RefillUiState.machines]
     * or `packedItems`, so `isPacked` is not re-derived here. Ported from iOS
     * `setPackingQuantity`.
     */
    fun setPackingQuantity(machineId: String, productId: String, quantity: Int) {
        _uiState.update { it.withPinnedQuantity(machineId, productId, quantity).withPackingList() }
    }

    /**
     * Ticks / unticks a machine's line of a product (refill and rebuild units
     * under one tick, "in the box"). Ticking takes the rebuild units first (a
     * planned slot cannot be done without them), then the refill, each pinned
     * to what goes into the box. Ported from iOS `toggleLine`.
     */
    fun toggleLine(machineId: String, productId: String) {
        _uiState.update { state ->
            if (state.step != RefillStep.PACKING || isTourInMemory(state)) return@update state
            state.withToggledLine(machineId, productId).withSyncedPackedState()
        }
    }

    /**
     * Sets a line's amount. The rebuild units are filled first (a planned
     * slot needs its goods), the rest goes to the refill — so packing less
     * takes it off the refill first. Ported from iOS `setLineQuantity`.
     */
    fun setLineQuantity(machineId: String, productId: String, quantity: Int) {
        _uiState.update { state ->
            if (state.step != RefillStep.PACKING || isTourInMemory(state)) return@update state
            val line = state.packLine(machineId, productId)
            val total = quantity.coerceAtMost(line.maxQuantity).coerceAtLeast(0)
            // Free the refill's claim first, so the rebuild can grow into it.
            var next = if (line.hasRefill) state.withPinnedQuantity(machineId, productId, 0).withPackingList() else state
            var rebuild = 0
            if (line.rebuildNeed > 0) {
                rebuild = minOf(total, next.maxRebuildQuantity(machineId, productId))
                val machineMap = next.rebuildCustomQuantities[machineId].orEmpty() + (productId to rebuild)
                next = next.copy(rebuildCustomQuantities = next.rebuildCustomQuantities + (machineId to machineMap))
                    .withPackingList()
            }
            if (line.hasRefill) next = next.withPinnedQuantity(machineId, productId, total - rebuild)
            next.withPackingList()
        }
    }

    private fun RefillUiState.withToggledLine(machineId: String, productId: String): RefillUiState {
        val line = packLine(machineId, productId)
        if (line.isUnavailable) return this
        if (line.ticked) {
            return copy(
                rebuildTicks = rebuildTicks + (machineId to (rebuildTicks[machineId].orEmpty() - productId)),
                rebuildCustomQuantities = rebuildCustomQuantities + (machineId to (rebuildCustomQuantities[machineId].orEmpty() - productId)),
                rebuildTickSequence = rebuildTickSequence + (machineId to (rebuildTickSequence[machineId].orEmpty() - productId))
            ).withUnpacked(machineId, productId).withPackingList()
        }
        var next = this
        if (line.rebuildNeed > 0 && !isRebuildTaken(machineId, productId)) {
            val seq = rebuildTickCounter + 1
            next = next.copy(
                rebuildTickCounter = seq,
                rebuildTickSequence = rebuildTickSequence + (machineId to (rebuildTickSequence[machineId].orEmpty() + (productId to seq))),
                rebuildTicks = rebuildTicks + (machineId to (rebuildTicks[machineId].orEmpty() + productId))
            ).withPackingList()
            // Pin what is in the box: a later tick must not change it.
            val qty = next.rebuildCommitted[machineId]?.get(productId) ?: 0
            next = next.copy(
                rebuildCustomQuantities = next.rebuildCustomQuantities +
                    (machineId to (next.rebuildCustomQuantities[machineId].orEmpty() + (productId to qty)))
            ).withPackingList()
        }
        if (line.hasRefill) next = next.withPackedIfInStock(machineId, productId)
        return next
    }

    /** Ticks every line of [machineIds] that is not in the box yet ("pack all"). */
    private fun RefillUiState.withAllLinesTicked(machineIds: List<String>): RefillUiState {
        var next = this
        for (machineId in machineIds) {
            for (productId in next.lineProductIds(machineId)) {
                if (!next.isLineTicked(machineId, productId)) next = next.withToggledLine(machineId, productId)
            }
        }
        return next
    }

    /**
     * Toggles the packed state for one machine-product pair, skipping the
     * pack (silently) if the warehouse has no remaining stock for it. Pins
     * the quantity on pack, clears the pinned quantity on unpack. Re-derives
     * every machine's `isPacked`. Ported from iOS `togglePackedForMachine`.
     */
    fun togglePackedForMachine(machineId: String, productId: String) = toggleLine(machineId, productId)

    /**
     * Toggles the packed state for a product across every machine that needs
     * it: unpacks all if every one of them is already packed, else packs
     * every one of them that isn't out of stock (stock-aware, in picklist
     * order — an earlier machine in the loop can exhaust the remaining
     * warehouse stock for a later one). Ported from iOS `togglePackedAll`.
     */
    fun togglePackedAll(productId: String) {
        _uiState.update { state ->
            if (state.step != RefillStep.PACKING || isTourInMemory(state)) return@update state
            val machineIds = state.machines.map { it.machine.id }
                .filter { productId in state.lineProductIds(it) }
            val lines = machineIds.map { state.packLine(it, productId) }.filter { !it.isUnavailable }
            if (lines.isEmpty()) return@update state
            val untick = lines.all { it.ticked }
            var next = state
            for (line in lines) {
                if (line.ticked == untick) next = next.withToggledLine(line.machineId, productId)
            }
            next.withSyncedPackedState()
        }
    }

    /**
     * Packs every needed product for every machine that isn't already
     * packed, skipping (not aborting on) out-of-stock pairs. Ported from iOS
     * `packEverything`.
     */
    fun packEverything() {
        _uiState.update { state ->
            if (state.step != RefillStep.PACKING || isTourInMemory(state)) return@update state
            state.withAllLinesTicked(state.machines.map { it.machine.id }).withSyncedPackedState()
        }
    }

    /** Ticks every line of one machine. Ported from iOS `packAllForMachine`. */
    fun packAllForMachine(machineId: String) {
        _uiState.update { state ->
            if (state.step != RefillStep.PACKING || isTourInMemory(state)) return@update state
            state.withAllLinesTicked(listOf(machineId)).withSyncedPackedState()
        }
    }

    /**
     * Writes [quantity] into `customQuantities`, clamped to
     * [RefillTourLogic.maxPackingQuantity]. Shared by [setPackingQuantity]
     * and [withPinnedCurrentQuantity] so the clamp lives in exactly one
     * place. Ported from iOS `setPackingQuantity`'s clamp.
     */
    private fun RefillUiState.withPinnedQuantity(machineId: String, productId: String, quantity: Int): RefillUiState {
        val maxQty = RefillTourLogic.maxPackingQuantity(
            machines = machines,
            machineId = machineId,
            productId = productId,
            packedItems = packedItems,
            customQuantities = customQuantities,
            warehouseStock = packingStock,
            stockLoaded = stockLoaded
        )
        val clamped = quantity.coerceIn(0, maxQty)
        val machineMap = (customQuantities[machineId] ?: emptyMap()) + (productId to clamped)
        return copy(customQuantities = customQuantities + (machineId to machineMap))
    }

    /**
     * Pins [RefillTourLogic.packingQuantity]'s current value (the live tray
     * deficit, unless already pinned) into `customQuantities` at the moment
     * of packing. Without this, a sale during the tour widens the deficit,
     * the displayed "packed" number drifts under the driver's fingers, and a
     * warehouse that can only partly satisfy the new figure leaves the
     * driver short. Ported from iOS `pinPackingQuantity`.
     */
    private fun RefillUiState.withPinnedCurrentQuantity(machineId: String, productId: String): RefillUiState {
        val machine = machines.find { it.machine.id == machineId } ?: return this
        val currentQty = RefillTourLogic.packingQuantity(
            machine = machine,
            productId = productId,
            customQuantities = customQuantities
        )
        return withPinnedQuantity(machineId, productId, currentQty)
    }

    /** Removes a pinned quantity so a later re-pack recalculates from the tray deficit. Ported from iOS `togglePackedForMachine`'s unpack branch. */
    private fun RefillUiState.withClearedPinnedQuantity(machineId: String, productId: String): RefillUiState {
        val machineMap = customQuantities[machineId] ?: return this
        if (productId !in machineMap) return this
        return copy(customQuantities = customQuantities + (machineId to (machineMap - productId)))
    }

    /** Adds [productId] to [machineId]'s packed set and pins its quantity, unless out of warehouse stock. */
    private fun RefillUiState.withPackedIfInStock(machineId: String, productId: String): RefillUiState {
        val outOfStock = RefillTourLogic.isOutOfStockForMachine(
            machines = machines,
            machineId = machineId,
            productId = productId,
            packedItems = packedItems,
            customQuantities = customQuantities,
            warehouseStock = packingStock,
            stockLoaded = stockLoaded
        )
        if (outOfStock) return this
        val currentSet = packedItems[machineId] ?: emptySet()
        if (productId in currentSet) return this
        // Re-derived before pinning: the product's rebuild units are taken
        // along now and claim their stock first.
        return copy(packedItems = packedItems + (machineId to (currentSet + productId)))
            .withPackingList()
            .withPinnedCurrentQuantity(machineId, productId)
    }

    /** Removes [productId] from [machineId]'s packed set and clears its pinned quantity. */
    private fun RefillUiState.withUnpacked(machineId: String, productId: String): RefillUiState {
        val currentSet = packedItems[machineId] ?: emptySet()
        if (productId !in currentSet) return this
        return copy(packedItems = packedItems + (machineId to (currentSet - productId)))
            .withClearedPinnedQuantity(machineId, productId)
    }

    // ---------------------------------------------------------------------
    // Tour start (Task 8). Ported from iOS `startTour`
    // (`RefillWizardViewModel.swift:1652-1740`) and `deductWarehouseStock`
    // (L1741-1800).
    // ---------------------------------------------------------------------

    /**
     * Starts the tour: mints a tour id, narrows every machine's trays to
     * what was actually packed, charges the warehouse for exactly those
     * goods, writes the `tour_started` feed row, orders the machines by
     * urgency and moves to [RefillStep.REFILL].
     *
     * The order of the two writes is deliberate and matches iOS and the
     * PWA: the FIFO deductions run **before** the `tour_started` activity
     * row, so a start that dies mid-way never leaves an orphaned feed entry
     * announcing a tour that was never charged. A *failed* deduction, by
     * contrast, does not block anything — [RefillRepository.deductForTour]
     * keeps going past per-deduction errors on purpose (the tour must not get
     * stuck because the warehouse ledger had a hiccup) — but the ones that
     * failed land in [RefillUiState.failedDeductions] for the UI to report,
     * rather than disappearing.
     *
     * The deduction set comes from [RefillTourLogic.buildDeductions] and
     * from nowhere else. That function charges only the intersection of
     * `packedItems` and each machine's real tray products — never the tray
     * deficits — which is the fix for the bug that motivated this phase
     * (iOS billed the warehouse for goods the driver never packed, ~334
     * units across 53 tours). Rebuilding that list here, in any form, would
     * reintroduce it.
     */
    fun startTour() {
        val snapshot = _uiState.value
        if (snapshot.machines.none { it.isPacked }) return
        // Re-entrancy guard: a second tap (or a tap on a resumed tour)
        // would mint a second tour id and charge the warehouse twice for
        // the same box of goods. Not in iOS, which relies on `isSaving`
        // disabling its button; double-charging is the exact failure class
        // this phase exists to prevent, so it is enforced here too.
        // Task 9's reset path must clear BOTH tourId and step, or this guard
        // latches shut and startTour() silently does nothing forever.
        if (isTourInMemory(snapshot)) return

        val tourId = UUID.randomUUID().toString()

        // The id is written into the state *before* anything that records
        // it runs, so the deductions' `tour_id` metadata, the activity row
        // and the persisted snapshot can never disagree about which tour
        // they belong to.
        val started = _uiState.updateAndGet { state ->
            // Rebuild units are fixed now: what the warehouse covers for each
            // machine's accepted slots travels with the machine, and only the
            // accepted items of the change note go on the tour (web `startTour`).
            val rebuildCommitted = state.computeRebuildCommitted()
            state.copy(
                isSaving = true,
                tourId = tourId,
                tourLog = emptyList(),
                tourLeftovers = emptyMap(),
                leftoversReturned = false,
                machines = RefillTourLogic.applyTourInclusion(
                    machines = state.machines,
                    packedItems = state.packedItems,
                    customQuantities = state.customQuantities
                ).map { machine ->
                    val accepted = machine.acceptedChangeItems
                    machine.copy(
                        changeRequest = machine.changeRequest
                            ?.takeIf { accepted.isNotEmpty() }
                            ?.copy(items = accepted),
                        rebuildPacked = rebuildCommitted[machine.machine.id] ?: emptyMap()
                    )
                }
            ).withPackingList()
        }

        viewModelScope.launch {
            val warehouseId = started.selectedWarehouseId
            if (warehouseId != null) {
                // One deduction per (machine, product): the normal refill plus
                // the rebuild units, so unused rebuild units can later go back
                // to the very batches this tour took them from (the deduction
                // metadata carries the tour id `apply_slot_change` matches on).
                val deductions = SlotChange.mergeDeductions(
                    normal = RefillTourLogic.buildDeductions(
                        machines = started.machines,
                        packedItems = started.packedItems,
                        customQuantities = started.customQuantities
                    ),
                    rebuildPacked = started.machines
                        .filter { it.rebuildPacked.isNotEmpty() }
                        .associate { it.machine.id to it.rebuildPacked }
                )
                // Never fails the tour — the driver has already packed the
                // van — but the deductions that did not go through are kept
                // so the UI can say so. See [RefillUiState.failedDeductions]:
                // a swallowed failure means goods left the warehouse and the
                // ledger never recorded it, which nobody can fix without
                // being told. A `Result.failure` (something unexpected
                // escaping the whole loop) is treated as "all of them
                // failed", because none of them is known to have landed.
                val failed = RefillRepository.deductForTour(
                    warehouseId = warehouseId,
                    tourId = tourId,
                    deductions = deductions
                ).getOrDefault(deductions)
                if (failed.isNotEmpty()) {
                    _uiState.update { it.copy(failedDeductions = failed) }
                }
            }

            // Resolved once here and carried in the state for every later
            // row this tour writes (refills, skips) — see
            // [RefillUiState.tourCompanyId]. Deliberately after the
            // deductions so the "charge before you announce" ordering above
            // is untouched.
            val companyId = resolveTourCompanyId()

            // `activity_log.metadata` is a typed cross-client contract
            // (PWA/iOS/Android). These four keys and their types are what
            // this app's own dashboard reads back in
            // `models/ActivityFeed.kt:40-42` and
            // `data/ActivityFeedBuilder.kt:101-115` — a misspelling here
            // renders as an empty tour card. `tour_id` is added by
            // [RefillRepository.writeTourActivity] itself.
            val tourMachines = started.machines.filter { it.isPacked }
            val warehouseName = started.warehouses.find { it.id == warehouseId }?.name
            RefillRepository.writeTourActivity(
                action = "tour_started",
                machineId = null,
                machineName = null,
                tourId = tourId,
                warehouseId = warehouseId,
                extra = buildMap {
                    put("machine_count", JsonPrimitive(tourMachines.size))
                    put("machine_ids", JsonArray(tourMachines.map { JsonPrimitive(it.machine.id) }))
                    put("machine_names", JsonArray(tourMachines.map { JsonPrimitive(it.machine.displayName) }))
                    warehouseName?.let { put("warehouse_name", JsonPrimitive(it)) }
                },
                companyId = companyId
            )

            val next = _uiState.updateAndGet { state ->
                val ordered = RefillTourLogic.sortByVisitOrder(state.machines)
                state.copy(
                    machines = ordered,
                    step = RefillStep.REFILL,
                    currentMachineId = ordered.firstOrNull { it.isUnfinishedTourStop }?.machine?.id,
                    tourCompanyId = companyId,
                    isSaving = false,
                    tourNotes = emptyList()
                ).withPackingList()
            }
            tourStore.save(next.toPersistedTourState())
            prepareRebuildForCurrentMachine()
        }
    }

    // ---------------------------------------------------------------------
    // Note for the next tour (refill step).
    // ---------------------------------------------------------------------

    /**
     * Ticks a note off on the packing step. It stays on every tour until
     * then; removed right away and put back (with an error) if the server
     * refuses.
     */
    fun completeTourNote(noteId: String) {
        val note = _uiState.value.tourNotes.firstOrNull { it.id == noteId } ?: return
        _uiState.update { s -> s.copy(tourNotes = s.tourNotes.filterNot { it.id == noteId }, tourNoteError = null) }
        viewModelScope.launch {
            TourNoteRepository.completeNotes(listOf(noteId), _uiState.value.tourId)
                .onFailure { e ->
                    Log.w(TAG, "Completing tour note failed", e)
                    _uiState.update { s ->
                        s.copy(
                            tourNotes = TourNotes.forPacking(s.tourNotes + note, s.tourId),
                            tourNoteError = e.message ?: e.toString()
                        )
                    }
                }
        }
    }

    /** Opens the note dialog for [machineId], prefilled with this tour's open note of it. */
    fun openTourNote(machineId: String) {
        val tourId = _uiState.value.tourId
        _uiState.update { it.copy(tourNoteEditor = TourNoteEditorState(machineId = machineId, isLoading = tourId.isNotEmpty())) }
        if (tourId.isEmpty()) return
        viewModelScope.launch {
            val existing = TourNoteRepository.fetchTourNote(machineId, tourId)
                .onFailure { e -> Log.w(TAG, "Loading the tour note failed", e) }
                .getOrNull()
            _uiState.update { state ->
                val editor = state.tourNoteEditor
                if (editor == null || editor.machineId != machineId) state
                else state.copy(tourNoteEditor = editor.copy(isLoading = false, initialText = existing?.note.orEmpty()))
            }
        }
    }

    /**
     * Closes the dialog. Always — a swiped-away sheet must not stay in the
     * state invisibly; a save still in flight lands (or fails) silently.
     */
    fun dismissTourNote() {
        _uiState.update { it.copy(tourNoteEditor = null) }
    }

    /** Saves the dialog's text for this tour; empty deletes the note. Closes on success. */
    fun saveTourNote(text: String) {
        val state = _uiState.value
        val editor = state.tourNoteEditor ?: return
        if (editor.isSaving || state.tourId.isEmpty()) return
        val machineId = editor.machineId
        _uiState.update { it.copy(tourNoteEditor = editor.copy(isSaving = true, error = null)) }
        viewModelScope.launch {
            val result = TourNoteRepository.saveNote(machineId, state.tourId, TourNotes.normalizedForSave(text))
            _uiState.update { current ->
                val open = current.tourNoteEditor
                when {
                    open == null || open.machineId != machineId -> current
                    result.isSuccess -> current.copy(tourNoteEditor = null)
                    else -> current.copy(
                        tourNoteEditor = open.copy(
                            isSaving = false,
                            error = result.exceptionOrNull()?.message.orEmpty()
                        )
                    )
                }
            }
        }
    }

    /** Packed, and neither refilled nor skipped yet — a stop the tour still owes a visit. */
    private val RefillMachine.isUnfinishedTourStop: Boolean
        get() = isPacked && !isRefilled && !isSkipped

    /**
     * Snapshot for [TourStore]. [PersistedTourState.currentMachineIndex] is
     * an index into the *remaining* machines (iOS `remainingMachines`), not
     * into [RefillUiState.machines] — resolved from [RefillUiState.currentMachineId]
     * so the two can't drift; it is 0 at tour start, as on iOS.
     */
    private fun RefillUiState.toPersistedTourState(): PersistedTourState {
        val remaining = machines.filter { it.isUnfinishedTourStop }
        return PersistedTourState(
            step = step,
            machines = machines,
            // -1 (no match) collapses to the first remaining stop. Unreachable
            // at tour start, where currentMachineId comes from this very list;
            // on a later save a drifted id would resume the driver at the
            // first remaining machine rather than fail loudly.
            currentMachineIndex = remaining
                .indexOfFirst { it.machine.id == currentMachineId }
                .coerceAtLeast(0),
            selectedWarehouseId = selectedWarehouseId,
            tourId = tourId,
            tourLog = tourLog,
            // Placeholder only: TourStore.save() re-stamps this from its own
            // clock, so the write and the expiry check share one time source.
            savedAt = "",
            tourLeftovers = tourLeftovers,
            leftoversReturned = leftoversReturned
        )
    }

    /**
     * Re-derives every machine's `isPacked`: packed as soon as at least one
     * of its still-needed products (a product with `deficit > 0` in one of
     * its trays) is in `packedItems`, or it has an accepted change-note slot. Also refreshes [RefillUiState.packingList]
     * since this changes `machines`. Ported from iOS `syncMachinePackedState`.
     */
    private fun RefillUiState.withSyncedPackedState(): RefillUiState {
        val newMachines = machines.map { rm ->
            val packedForMachine = packedItems[rm.machine.id] ?: emptySet()
            val rebuildTrayIds = rm.rebuildTrayIds
            val neededProductIds = rm.trays
                .filter { it.deficit > 0 && it.tray.id !in rebuildTrayIds }
                .mapNotNull { it.tray.productId }
                .toSet()
            // On the tour = at least one line of the machine is in the box
            // (refill or rebuild units). A change note alone does not put a
            // machine on the tour; only a pure swap, which needs nothing from
            // the warehouse and so has no line to tick, still means a visit.
            val rebuildTicked = rebuildTicks[rm.machine.id].orEmpty().isNotEmpty()
            val pureSwap = rm.acceptedChangeItems.isNotEmpty() &&
                SlotChange.rebuildPackNeeds(
                    rm.acceptedChangeItems,
                    rm.trays.associate { it.tray.id to it.tray.currentStock }
                ).values.none { it > 0 }
            rm.copy(isPacked = neededProductIds.any { it in packedForMachine } || rebuildTicked || pureSwap)
        }
        return copy(machines = newMachines).withPackingList()
    }

    // ---------------------------------------------------------------------
    // Refill step, skip, summary and resume (Task 9). Ported from iOS
    // `adjustFillAmount`/`fillTrayToCapacity`/`fillAllTrays`
    // (`RefillWizardViewModel.swift:1801-1828`), `applyRefillRPC` (L1848-1868),
    // `confirmRefill` (L1875-1950), `recordRefillSuccess` (L1952-1990),
    // `skipMachine` (L1991-2015), `advanceToNextMachine` (L2016-2024) and the
    // persistence block (L305-437).
    // ---------------------------------------------------------------------

    /**
     * Sets one tray's fill amount, clamped to what still fits
     * (`capacity - currentStock`). Ported from iOS `adjustFillAmount`.
     *
     * The clamp is written as `coerceAtMost(...).coerceAtLeast(0)` rather
     * than `coerceIn(0, maxFill)`: an over-stocked tray has a negative
     * `maxFill`, and `coerceIn` throws on an inverted range where iOS's
     * `max(0, min(maxFill, amount))` quietly yields 0.
     */
    fun adjustFillAmount(machineId: String, trayId: String, amount: Int) {
        _uiState.update { state ->
            state.withTrayFills(machineId, trayIds = setOf(trayId)) { tray ->
                amount.coerceAtMost(tray.maxFill).coerceAtLeast(0)
            }
        }
    }

    /** Fills one tray to capacity. Ported from iOS `fillTrayToCapacity`. */
    fun fillTrayToCapacity(machineId: String, trayId: String) {
        _uiState.update { state ->
            state.withTrayFills(machineId, trayIds = setOf(trayId)) { tray ->
                tray.maxFill.coerceAtLeast(0)
            }
        }
    }

    /**
     * Fills every *packed* tray of a machine to capacity. Ported from iOS
     * `fillAllTrays`.
     *
     * Restricted to `isInTour` trays: `RefillTourLogic.applyTourInclusion`
     * sets `isInTour = false, fillAmount = 0` for a tray whose product the
     * driver did not pack, and such a tray can still have `deficit > 0` /
     * `maxFill > 0`. Passing `trayIds = null` to [withTrayFills] would fill
     * those too — booking stock into trays that were never physically
     * loaded, and that the refill step does not even render a card for.
     */
    fun fillAllTrays(machineId: String) {
        _uiState.update { state ->
            val machine = state.machines.find { it.machine.id == machineId } ?: return@update state
            val inTourTrayIds = machine.trays.filter { it.isInTour }.map { it.tray.id }.toSet()
            state.withTrayFills(machineId, trayIds = inTourTrayIds) { tray -> tray.maxFill.coerceAtLeast(0) }
        }
    }

    /**
     * Makes [machineId] the machine the refill step shows. Ignores machines
     * the tour has already finished with (refilled or skipped) and machines
     * that were never packed — jumping to one would show the driver a stop
     * that [advanceToNextMachine] is not going to come back to. Persisted,
     * because the resume snapshot carries the current stop.
     */
    fun selectMachine(machineId: String) {
        val state = _uiState.value
        val target = state.machines.find { it.machine.id == machineId } ?: return
        if (!target.isUnfinishedTourStop) return
        if (state.currentMachineId == machineId) return
        val next = _uiState.updateAndGet { it.copy(currentMachineId = machineId) }
        tourStore.save(next.toPersistedTourState())
        prepareRebuildForCurrentMachine()
    }

    /**
     * Books one machine's fills through the atomic `refill_machine_trays`
     * RPC, then records the visit and moves on.
     *
     * Three attempts, sleeping 1 s before the second and 3 s before the
     * third. The retry is deliberately **blind** — no error classification:
     * the RPC dedupes per `(tour_id, tray_id)` (see the header comment of
     * `20260511120000_refill_machine_trays_rpc.sql`), so a retry of a call
     * that in fact committed is a no-op rather than a double booking. That
     * safety net is exactly why [RefillUiState.tourId] has to survive a
     * resume unchanged.
     *
     * After three failures the machine is **not** marked refilled, no tour
     * log entry and no audit row are written and the step does not change —
     * only [RefillUiState.error] is set, so the driver can confirm the same
     * machine again cleanly. (The pre-Task-9 Android code discarded the
     * write result and advanced regardless; that is the bug this removes.)
     *
     * A machine where no tray needs a write still records the visit — tour
     * log entry with 0/0 plus an `activity_log` row — so the history shows
     * the machine was opened. Ported from iOS `confirmRefill`.
     */
    fun confirmRefill(machineId: String) {
        val snapshot = _uiState.value
        val machine = snapshot.machines.find { it.machine.id == machineId } ?: return
        // Re-entrancy guards. iOS disables only its *Confirm* button on
        // `isSaving` (`RefillStepView.swift:447`); a second tap here would
        // write a second tour-log entry and a second audit row for one
        // visit, and the empty-tray path below never sets `isSaving` at all,
        // so the UI cannot block it on its own.
        //
        // These guards depend on `viewModelScope` dispatching through
        // `Dispatchers.Main.immediate`: the first state write inside the
        // launched block runs synchronously, before this function returns,
        // so a second tap in the same frame already sees it. Inserting a
        // suspending call ahead of that first write reopens the window —
        // and no test would catch it.
        if (snapshot.isSaving) return
        if (machine.isRefilled || machine.isSkipped) return

        // Change note first. The machine can only be confirmed once every
        // slot of it is marked rebuilt or not rebuilt (the UI says so and
        // disables Confirm); cards that were never prepared — they always are
        // by the time the step renders — are prepared instead of booked blind.
        val rebuildSlots = if (machine.acceptedChangeItems.isEmpty()) {
            emptyList()
        } else {
            if (snapshot.rebuildMachineId != machineId) {
                prepareRebuildForCurrentMachine()
                return
            }
            if (!snapshot.rebuildReady) return
            snapshot.currentRebuild
        }

        // `isInTour` is defensive here, not load-bearing today: the fill
        // actions above no longer set `fillAmount > 0` on a not-packed tray.
        // But this is the single place that books stock, so it must not
        // trust that invariant transitively — a future fill-setting caller
        // that forgets the `isInTour` filter must not be able to book stock
        // into a tray the driver never packed (see `fillAllTrays` and
        // `RefillTourLogic.applyTourInclusion`, which is what makes a
        // not-packed tray `isInTour = false` in the first place).
        val traysToRefill = machine.trays.filter { it.fillAmount > 0 && it.isInTour }

        viewModelScope.launch {
            // `apply_slot_change` runs **before** the normal refill: it
            // switches the rebuilt slots (the leftovers ride along in the van
            // and are booked at the end of the tour). When it
            // fails, nothing else is booked and the machine stays put — the
            // driver confirms again, and the RPC's (request, tour)
            // idempotency makes the retry safe even if the first call in fact
            // committed. The normal refill below never touches rebuilt slots.
            var slotsRebuilt = 0
            // Rebuilt slots go into the machine's audit row and tour log next
            // to the normal refill — `refill_machine_trays` never sees them.
            val rebuilt = SlotChange.rebuiltLines(rebuildSlots)
            if (rebuildSlots.isNotEmpty()) {
                _uiState.update { it.copy(isSaving = true, error = null, refillFailedAttempts = null) }
                val applied = applyRebuild(snapshot, machine, rebuildSlots, skipAll = false)
                val failure = applied.exceptionOrNull()
                if (failure != null) {
                    _uiState.update {
                        it.copy(
                            isSaving = false,
                            error = failure.message,
                            refillFailedAttempts = MAX_REFILL_ATTEMPTS
                        )
                    }
                    return@launch
                }
                slotsRebuilt = applied.getOrDefault(0)
            }

            if (traysToRefill.isEmpty()) {
                // Clear a stale error from a previous machine — a visit that
                // needed no stock write is still a success, and leaving the
                // old message (or a stale [RefillUiState.refillFailedAttempts]
                // from an earlier failed confirm on this same machine) up
                // makes it read as a failure.
                _uiState.update { it.copy(error = null, refillFailedAttempts = null) }
                recordRefillSuccess(
                    machineId = machineId,
                    traysSnapshot = emptyList(),
                    traysCount = 0,
                    itemsAdded = 0,
                    slotsRebuilt = slotsRebuilt,
                    rebuilt = rebuilt
                )
                _uiState.update { it.copy(isSaving = false) }
                return@launch
            }

            // Clears any [RefillUiState.refillFailedAttempts] left by a
            // previous failed confirm on this same machine — this is a fresh
            // attempt, not a continuation of that failure.
            _uiState.update { it.copy(isSaving = true, error = null, refillFailedAttempts = null) }

            val payload = traysToRefill.map {
                RefillTrayPayload(trayId = it.tray.id, fillAmount = it.fillAmount)
            }
            var lastError: Throwable? = null

            for (attempt in 1..MAX_REFILL_ATTEMPTS) {
                if (attempt > 1) delay(REFILL_BACKOFF_MS[attempt - 2])

                val result = RefillRepository.refillMachineTrays(
                    machineId = machineId,
                    tourId = snapshot.tourId,
                    trays = payload
                )
                val rows = result.getOrElse { e ->
                    lastError = e
                    null
                } ?: continue

                // Server-authoritative numbers only: the local `fillAmount`
                // is what was *requested*, `new_stock` is what the machine
                // actually holds now (a concurrent sale, a clamp, or a
                // deduped replay all make the two differ).
                _uiState.update { it.withMirroredStock(machineId, rows) }
                val itemsAdded = rows.sumOf { (it.newStock - it.oldStock).coerceAtLeast(0) }

                recordRefillSuccess(
                    machineId = machineId,
                    traysSnapshot = traysToRefill,
                    traysCount = rows.size,
                    itemsAdded = itemsAdded,
                    slotsRebuilt = slotsRebuilt,
                    rebuilt = rebuilt
                )
                _uiState.update { it.copy(isSaving = false) }
                return@launch
            }

            // All attempts failed: the machine stays an unfinished tour stop
            // and the step stays put, so the same machine can be confirmed
            // again. `error` carries only the raw cause (or null — the UI
            // supplies its own "unknown error" fallback text);
            // `refillFailedAttempts` is the signal that tells the UI to wrap
            // it in the localized "could not be saved after N attempts"
            // sentence rather than showing it as a bare exception message.
            _uiState.update {
                it.copy(
                    isSaving = false,
                    error = lastError?.message,
                    refillFailedAttempts = MAX_REFILL_ATTEMPTS
                )
            }
        }
    }

    /**
     * Marks [machineId] skipped, logs the skip and moves on. The
     * `stock_refill_tour_skip` activity row carries **no** extra metadata,
     * matching iOS and the PWA. Ported from iOS `skipMachine`.
     */
    fun skipMachine(machineId: String) {
        val snapshot = _uiState.value
        val machine = snapshot.machines.find { it.machine.id == machineId } ?: return
        // Same guards as `confirmRefill`, and `isSaving` matters most here:
        // neither iOS nor this app's UI disables Skip while a confirm sits in
        // its 1s/3s retry window (`RefillStepView.swift:416-425` has no
        // `.disabled`), so a Skip landing mid-retry would mark the machine
        // skipped, log it, advance — and then the succeeding RPC would log the
        // same visit a second time as refilled. One machine, counted as both.
        if (snapshot.isSaving) return
        if (machine.isRefilled || machine.isSkipped) return

        // Not rebuilt: every accepted slot stays open for the next tour, and
        // what was packed for them rides back in the van as tour leftovers.
        // Removed/filled play no part in a skip, so cards that were never
        // prepared can be built from the items alone.
        val rebuildSlots = when {
            machine.acceptedChangeItems.isEmpty() -> emptyList()
            snapshot.rebuildMachineId == machineId -> snapshot.currentRebuild
            else -> SlotChange.startRebuild(machine.acceptedChangeItems, emptyMap(), machine.rebuildPacked)
        }

        viewModelScope.launch {
            if (rebuildSlots.isNotEmpty()) {
                _uiState.update { it.copy(isSaving = true, error = null, refillFailedAttempts = null) }
                val failure = applyRebuild(snapshot, machine, rebuildSlots, skipAll = true)
                    .exceptionOrNull()
                if (failure != null) {
                    _uiState.update {
                        it.copy(
                            isSaving = false,
                            error = failure.message,
                            refillFailedAttempts = MAX_REFILL_ATTEMPTS
                        )
                    }
                    return@launch
                }
            }

            val state = _uiState.updateAndGet { current ->
                current.copy(
                    isSaving = false,
                    machines = current.machines.map {
                        if (it.machine.id == machineId) it.copy(isSkipped = true) else it
                    },
                    tourLog = current.tourLog + TourLogEntry(
                        machineId = machineId,
                        machineName = machine.machine.displayName,
                        traysRefilled = 0,
                        totalAdded = 0,
                        skipped = true
                    )
                ).withPackingList()
            }

            RefillRepository.writeTourActivity(
                action = "stock_refill_tour_skip",
                machineId = machineId,
                machineName = machine.machine.displayName,
                tourId = state.tourId,
                warehouseId = state.selectedWarehouseId,
                extra = emptyMap(),
                companyId = state.tourCompanyId
            )

            advanceToNextMachine()
        }
    }

    /**
     * Restores a tour the app was killed in the middle of. Everything the
     * running tour needs comes back, **including [RefillUiState.tourId]** —
     * without it a post-resume retry of a call that had in fact committed
     * would book a second time, because the RPC dedupes on
     * `(tour_id, tray_id)`.
     *
     * The persisted `currentMachineIndex` indexes the *remaining* stops of
     * the **urgency-sorted** tour list (the order [startTour] establishes via
     * [RefillTourLogic.sortByVisitOrder]), not the repository's fetch order —
     * so the machines are sorted first and only then indexed, or the driver
     * is sent to the wrong machine. An out-of-range index (the tour ended up
     * with fewer remaining stops than when it was saved) falls back to the
     * first remaining stop rather than leaving the refill step blank.
     *
     * Ported from iOS `resumeTour` (`RefillWizardViewModel.swift:369-403`).
     */
    fun resumeTour() {
        val saved = tourStore.load()
        if (saved == null) {
            _uiState.update { it.copy(hasSavedTour = false) }
            return
        }

        // A resumed tour is state worth protecting: closing the entry gate
        // stops a later tab re-entry from calling loadData() over it.
        didRunInitialLoad = true

        val ordered = RefillTourLogic.sortByVisitOrder(saved.machines)
        val remaining = ordered.filter { it.isUnfinishedTourStop }
        val current = remaining.getOrNull(saved.currentMachineIndex) ?: remaining.firstOrNull()

        _uiState.update { state ->
            state.copy(
                isLoading = false,
                isSaving = false,
                step = saved.step,
                machines = ordered,
                selectedWarehouseId = saved.selectedWarehouseId,
                tourId = saved.tourId,
                tourLog = saved.tourLog,
                tourLeftovers = saved.tourLeftovers,
                leftoversReturned = saved.leftoversReturned,
                currentMachineId = current?.machine?.id,
                hasSavedTour = false,
                error = null,
                refillFailedAttempts = null
            ).withPackingList()
        }
        prepareRebuildForCurrentMachine()

        // The rest of this tour still writes audit rows, so its company id is
        // resolved once here too — same reason as at tour start.
        viewModelScope.launch {
            val companyId = resolveTourCompanyId()
            _uiState.update { it.copy(tourCompanyId = companyId) }
        }
    }

    /** Throws away the saved tour without resuming it. Ported from iOS `clearSavedTour`. */
    fun discardSavedTour() {
        tourStore.clear()
        _uiState.update { it.copy(hasSavedTour = false) }
    }

    /**
     * Drops the whole wizard back to a clean slate: no tour in memory, no
     * saved tour on disk, entry gate re-armed so the next visit loads fresh.
     *
     * Both inputs of [isTourInMemory] — `step` and `tourId` — must come back
     * to their defaults here, which is why the state is replaced wholesale
     * rather than patched field by field: leaving either one set latches
     * [startTour]'s re-entrancy guard shut and it would silently never start
     * a tour again. Ported from iOS `reset`.
     *
     * [reviewCompleted] is cleared for the same reason: the next visit is a
     * new tour and has to review again, and a latched flag would silently
     * skip the review for the rest of the ViewModel's life.
     */
    fun reset() {
        tourStore.clear()
        didRunInitialLoad = false
        reviewCompleted = false
        _uiState.value = RefillUiState()
    }

    /**
     * Shared post-success bookkeeping: mark refilled, append the tour log
     * entry, write the audit row, advance (which persists). Ported from iOS
     * `recordRefillSuccess`.
     *
     * [traysCount] and [itemsAdded] are the server's numbers (row count and
     * `new_stock - old_stock`), passed in by [confirmRefill]; [traysSnapshot]
     * is the local request, used only for the human-readable `products`
     * breakdown, exactly as on iOS.
     */
    private suspend fun recordRefillSuccess(
        machineId: String,
        traysSnapshot: List<RefillTray>,
        traysCount: Int,
        itemsAdded: Int,
        slotsRebuilt: Int = 0,
        rebuilt: List<RebuiltSlotLine> = emptyList()
    ) {
        // Rebuilt slots count like refilled trays: the summary's "items
        // added" and the history row must include what went into them.
        val totalTrays = traysCount + rebuilt.size
        val totalAdded = itemsAdded + rebuilt.sumOf { it.quantity }
        val machineName = _uiState.value.machines
            .find { it.machine.id == machineId }?.machine?.displayName.orEmpty()

        val state = _uiState.updateAndGet { current ->
            current.copy(
                machines = current.machines.map {
                    if (it.machine.id == machineId) it.copy(isRefilled = true) else it
                },
                tourLog = current.tourLog + TourLogEntry(
                    machineId = machineId,
                    machineName = machineName,
                    traysRefilled = totalTrays,
                    totalAdded = totalAdded,
                    skipped = false,
                    slotsRebuilt = slotsRebuilt
                )
            ).withPackingList()
        }

        // `activity_log.metadata` is a typed cross-client contract
        // (PWA/iOS/Android). These keys and their types are what this app's
        // own dashboard reads back for a `stock_refill_tour` row:
        // `trays_refilled` and `total_added` as Int and `products` as an
        // array of `{product_name, quantity}` objects — see
        // `models/ActivityFeed.kt:37-38` and `:59-63`, consumed in
        // `data/ActivityFeedBuilder.kt:86-100`. `product_id` is written for
        // the PWA/iOS readers; this app's decoder ignores it. A misspelling
        // here renders as an empty refill card. Rebuilt slots are appended as
        // their own lines (`item_number`, `rebuild: true`) — extra keys the
        // existing decoders ignore — and counted in both totals.
        RefillRepository.writeTourActivity(
            action = "stock_refill_tour",
            machineId = machineId,
            machineName = machineName,
            tourId = state.tourId,
            warehouseId = state.selectedWarehouseId,
            extra = buildMap {
                put("trays_refilled", JsonPrimitive(totalTrays))
                put("total_added", JsonPrimitive(totalAdded))
                put(
                    "products",
                    JsonArray(
                        traysSnapshot.map { refillTray ->
                            buildJsonObject {
                                put(
                                    "product_id",
                                    refillTray.tray.productId
                                        ?.let { JsonPrimitive(it) } ?: JsonNull
                                )
                                put("product_name", JsonPrimitive(refillTray.productLabel))
                                put("quantity", JsonPrimitive(refillTray.fillAmount))
                            }
                        } + rebuilt.map { line ->
                            buildJsonObject {
                                put("product_id", JsonPrimitive(line.productId))
                                put("product_name", JsonPrimitive(line.productName ?: "Slot ${line.itemNumber}"))
                                put("quantity", JsonPrimitive(line.quantity))
                                put("item_number", JsonPrimitive(line.itemNumber))
                                put("rebuild", JsonPrimitive(true))
                            }
                        }
                    )
                )
            },
            companyId = state.tourCompanyId
        )

        advanceToNextMachine()
    }

    /**
     * Moves to the first remaining stop of the tour, or to
     * [RefillStep.SUMMARY] when none is left, then persists.
     *
     * "First remaining" is meaningful because [RefillUiState.machines] is
     * already in visit order by the time the refill step runs — [startTour]
     * sorts it, and [resumeTour] re-sorts what it restores. iOS expresses
     * the same thing as `currentMachineIndex = 0`.
     */
    private fun advanceToNextMachine() {
        val next = _uiState.updateAndGet { state ->
            val remaining = state.machines.filter { it.isUnfinishedTourStop }
            state.copy(
                step = if (remaining.isEmpty()) RefillStep.SUMMARY else state.step,
                currentMachineId = remaining.firstOrNull()?.machine?.id
            )
        }
        tourStore.save(next.toPersistedTourState())
        prepareRebuildForCurrentMachine()
    }

    /**
     * The tour's `company_id`, resolved once per tour. `null` on failure —
     * [RefillRepository.writeTourActivity] then falls back to resolving it
     * per row, so a failure here costs edge-function round trips, not audit
     * rows.
     */
    private suspend fun resolveTourCompanyId(): String? =
        AuthRepository.fetchOrganization().getOrNull()?.organization?.id

    /**
     * Applies [fill] to one machine's trays — either the trays in [trayIds]
     * or, when it is `null`, all of them. Shared by the three fill actions
     * so the "find machine, find tray, rebuild the list" plumbing exists
     * once. Refreshes the packing list because it changes `machines`.
     */
    private fun RefillUiState.withTrayFills(
        machineId: String,
        trayIds: Set<String>?,
        fill: (RefillTray) -> Int
    ): RefillUiState {
        if (machines.none { it.machine.id == machineId }) return this
        val newMachines = machines.map { machine ->
            if (machine.machine.id != machineId) return@map machine
            machine.copy(
                trays = machine.trays.map { tray ->
                    if (trayIds != null && tray.tray.id !in trayIds) tray
                    else tray.copy(fillAmount = fill(tray))
                }
            )
        }
        return copy(machines = newMachines).withPackingList()
    }

    /**
     * Writes the RPC's returned `new_stock` into the machine's local trays.
     * Trays the server did not report back (nothing to apply, or already
     * applied under this tour id) are left untouched.
     */
    private fun RefillUiState.withMirroredStock(
        machineId: String,
        rows: List<TrayApplicationResult>
    ): RefillUiState {
        if (rows.isEmpty()) return this
        val byTrayId = rows.associateBy { it.trayId }
        val newMachines = machines.map { machine ->
            if (machine.machine.id != machineId) return@map machine
            machine.copy(
                trays = machine.trays.map { tray ->
                    val row = byTrayId[tray.tray.id]
                    if (row == null) tray
                    else tray.copy(tray = tray.tray.copy(currentStock = row.newStock))
                }
            )
        }
        return copy(machines = newMachines).withPackingList()
    }

    // ---------------------------------------------------------------------
    // Slot rebuild at the machine ("Änderungsvermerk"). Ported from the web
    // wizard (`useRefillWizard.ts`: `loadTraysForCurrentMachine`'s rebuild
    // half, `recomputeRebuildFill`, `setRebuild*`, `applyCurrentRebuild`).
    // The arithmetic lives in [SlotChange] and is tested there.
    // ---------------------------------------------------------------------

    /**
     * Builds the rebuild cards of the current stop, once per stop. Shown at
     * once from the stock known locally, then refreshed with the slots' live
     * stock: "removed" defaults to what is in the slot *now*, so sales between
     * packing and filling are already accounted for. Also looks up the
     * best-before suggestion for goods coming out of the machine, which
     * travels with the stop's leftovers to the summary. Clears the cards
     * when the current stop has no change note.
     */
    private fun prepareRebuildForCurrentMachine() {
        val state = _uiState.value
        val machine = state.machines.find { it.machine.id == state.currentMachineId }
        val items = machine?.acceptedChangeItems.orEmpty()
        if (machine == null || items.isEmpty()) {
            if (state.rebuildMachineId != null || state.currentRebuild.isNotEmpty()) {
                _uiState.update {
                    it.copy(
                        rebuildMachineId = null,
                        currentRebuild = emptyList(),
                        rebuildExpirySuggestions = emptyMap()
                    )
                }
            }
            return
        }
        val machineId = machine.machine.id
        if (state.rebuildMachineId == machineId) return

        val packed = machine.rebuildPacked
        _uiState.update {
            it.copy(
                rebuildMachineId = machineId,
                currentRebuild = SlotChange.startRebuild(
                    items,
                    machine.trays.associate { tray -> tray.tray.id to tray.tray.currentStock },
                    packed
                ),
                rebuildExpirySuggestions = emptyMap()
            )
        }

        viewModelScope.launch {
            // Withdrawn in the office after the tour loaded it?
            val status = machine.changeRequest?.id?.let { SlotChangeRepository.fetchRequestStatus(it) }
            if (status != null && status != "open") {
                _uiState.update { s ->
                    if (s.rebuildMachineId != machineId) return@update s
                    s.copy(
                        withdrawnRebuildMachines = s.withdrawnRebuildMachines + machineId,
                        currentRebuild = SlotChange.withdrawn(s.currentRebuild)
                    )
                }
                return@launch
            }
            val live = SlotChangeRepository.fetchTrayStocks(items.map { it.trayId }).getOrNull()
            if (live != null) {
                _uiState.update { s ->
                    if (s.rebuildMachineId != machineId || s.isSaving || machineId in s.withdrawnRebuildMachines) return@update s
                    s.copy(
                        currentRebuild = SlotChange.recomputeFill(
                            s.currentRebuild.map { slot ->
                                val stock = live[slot.item.trayId] ?: return@map slot
                                // A "removed" the driver already typed wins.
                                val untouched = slot.removed == slot.liveStock
                                slot.copy(liveStock = stock, removed = if (untouched) stock else slot.removed)
                            },
                            packed
                        )
                    )
                }
            }

            val fromProducts = items.mapNotNull { it.fromProductId }.distinct()
            val found = fromProducts.mapNotNull { productId ->
                SlotChangeRepository.suggestExpiry(machineId, productId)?.let { productId to it }
            }
            if (found.isNotEmpty()) {
                _uiState.update { s ->
                    if (s.rebuildMachineId != machineId) return@update s
                    s.copy(rebuildExpirySuggestions = s.rebuildExpirySuggestions + found)
                }
            }
        }
    }

    /** Units of the old product taken out of a slot. Re-plans the suggested fills. */
    fun setRebuildRemoved(itemId: String, value: Int) {
        updateRebuild(recompute = true) { slot ->
            if (slot.item.id == itemId) slot.copy(removed = value.coerceAtLeast(0)) else slot
        }
    }

    /** Units of the new product put in, clamped to the new capacity; 0 for a slot left empty. */
    fun setRebuildFilled(itemId: String, value: Int) {
        _uiState.update { state ->
            if (state.isSaving) return@update state
            val machine = state.machines.find { it.machine.id == state.rebuildMachineId } ?: return@update state
            val max = SlotChange.maxRebuildFilled(state.currentRebuild, itemId, machine.rebuildPacked)
            state.copy(
                currentRebuild = state.currentRebuild.map { slot ->
                    if (slot.item.id != itemId) slot
                    else slot.copy(filled = value.coerceAtMost(max).coerceAtLeast(0), filledTouched = true)
                }
            )
        }
    }

    /** Dismisses the "slot change withdrawn" notice. */
    fun clearRebuildWithdrawnNotice() {
        _uiState.update { it.copy(rebuildWithdrawnNotice = null) }
    }

    /** Marks a slot rebuilt / not rebuilt; `null` takes the decision back. */
    fun setRebuildAction(itemId: String, action: RebuildAction?) {
        updateRebuild(recompute = true) { slot ->
            if (slot.item.id == itemId) SlotChange.withAction(slot, action) else slot
        }
    }

    /** The new price has been set at the machine's selection. */
    fun setRebuildPriceSet(itemId: String, value: Boolean) {
        updateRebuild(recompute = true) { slot ->
            if (slot.item.id == itemId) SlotChange.withPriceSet(slot, value) else slot
        }
    }

    /**
     * The age setting has been changed at the machine's selection. Unticking
     * a slot already marked rebuilt takes "rebuilt" back (recompute: a slot
     * going back to undecided counts as rebuilt for the fill plan anyway).
     */
    fun setRebuildAgeSet(itemId: String, value: Boolean) {
        updateRebuild(recompute = true) { slot ->
            if (slot.item.id == itemId) SlotChange.withAgeSet(slot, value) else slot
        }
    }

    // ---------------------------------------------------------------------
    // Tour end: slot change leftovers booked back at the warehouse
    // (`return_slot_change_leftovers`). The refiller counts what is really
    // in the van now; the computed numbers are only the defaults.
    // ---------------------------------------------------------------------

    /** Summary: unused (van) units of [productId] as counted. */
    fun setLeftoverVanQty(productId: String, value: Int) = updateLeftoverEdits {
        it.copy(leftoverVanQty = it.leftoverVanQty + (productId to value.coerceAtLeast(0)))
    }

    /** Summary: units of [productId] taken out of machines, as counted. */
    fun setLeftoverMachineQty(productId: String, value: Int) = updateLeftoverEdits {
        it.copy(leftoverMachineQty = it.leftoverMachineQty + (productId to value.coerceAtLeast(0)))
    }

    fun setLeftoverDestination(productId: String, destination: LeftoverDestination) = updateLeftoverEdits {
        it.copy(leftoverDestinations = it.leftoverDestinations + (productId to destination))
    }

    /** Best-before date (`YYYY-MM-DD`) for machine goods of [productId]; `null` = explicitly no date. */
    fun setLeftoverExpiry(productId: String, date: String?) = updateLeftoverEdits {
        it.copy(leftoverExpiry = it.leftoverExpiry + (productId to date.orEmpty()))
    }

    /** Locked while the return is in flight and once it is booked. */
    private fun updateLeftoverEdits(transform: (RefillUiState) -> RefillUiState) {
        _uiState.update { if (it.isReturningLeftovers || it.leftoversReturned) it else transform(it) }
    }

    /**
     * Books the tour's leftovers in one go. Products the refiller counted
     * down to zero are left out. Idempotent per tour on the server, so a
     * retry after a lost response cannot book twice. On success the flag is
     * persisted with the tour, so a resumed summary does not offer it again.
     *
     * @param batchLabel localized batch number of the return batch
     *   ("Rückgabe aus Automat") — the ViewModel has no resources.
     */
    fun returnTourLeftovers(batchLabel: String) {
        val snapshot = _uiState.value
        if (snapshot.isReturningLeftovers || snapshot.leftoversReturned) return
        if (snapshot.tourId.isEmpty()) return
        val payload = SlotChange.tourReturnPayload(
            aggregated = snapshot.aggregatedTourLeftovers,
            vanQty = snapshot.leftoverVanQty,
            machineQty = snapshot.leftoverMachineQty,
            destinations = snapshot.leftoverDestinations,
            expiry = snapshot.leftoverExpiry,
            batchNumber = batchLabel
        )
        _uiState.update { it.copy(isReturningLeftovers = true, leftoverReturnError = null) }
        viewModelScope.launch {
            val result = SlotChangeRepository.returnTourLeftovers(
                tourId = snapshot.tourId,
                warehouseId = snapshot.selectedWarehouseId,
                leftovers = payload
            )
            val failure = result.exceptionOrNull()
            val next = _uiState.updateAndGet {
                if (failure != null) {
                    it.copy(isReturningLeftovers = false, leftoverReturnError = failure.message ?: "")
                } else {
                    it.copy(isReturningLeftovers = false, leftoversReturned = true, leftoverReturnError = null)
                }
            }
            if (failure == null) tourStore.save(next.toPersistedTourState())
        }
    }

    /**
     * Whether the tour waiting to be resumed still has leftovers in the van
     * that were never booked back — discarding it asks first.
     */
    fun savedTourHasUnreturnedLeftovers(): Boolean {
        val saved = tourStore.load() ?: return false
        return !saved.leftoversReturned && SlotChange.aggregateTourLeftovers(saved.tourLeftovers).isNotEmpty()
    }

    /**
     * Stores what [machine]'s stop leaves in the van, replacing an earlier
     * entry of the same machine (a retried quit must not count twice).
     * Only with a warehouse: without one nothing was deducted at tour start,
     * so there is nothing to book back — as before.
     */
    private fun storeTourLeftovers(machine: RefillMachine, leftovers: List<RebuildLeftover>) {
        _uiState.update { state ->
            if (state.selectedWarehouseId == null) return@update state
            val suggestions = if (state.rebuildMachineId == machine.machine.id) state.rebuildExpirySuggestions else emptyMap()
            val entries = leftovers
                .filter { it.van + it.machine > 0 }
                .map {
                    TourLeftover(
                        productId = it.productId,
                        name = it.name,
                        imagePath = it.imagePath,
                        van = it.van,
                        machine = it.machine,
                        suggestedExpiry = if (it.machine > 0) suggestions[it.productId] else null
                    )
                }
            state.copy(
                tourLeftovers = if (entries.isEmpty()) state.tourLeftovers - machine.machine.id
                else state.tourLeftovers + (machine.machine.id to entries)
            )
        }
    }

    /**
     * Applies [transform] to every card of the current stop. Locked while a
     * write is in flight, like every other control of the refill step.
     */
    private fun updateRebuild(recompute: Boolean, transform: (RebuildSlot) -> RebuildSlot) {
        _uiState.update { state ->
            if (state.isSaving) return@update state
            val machine = state.machines.find { it.machine.id == state.rebuildMachineId } ?: return@update state
            val slots = state.currentRebuild.map(transform)
            state.copy(
                currentRebuild = if (recompute) SlotChange.recomputeFill(slots, machine.rebuildPacked) else slots
            )
        }
    }

    /**
     * Quits the rebuild of [machine] through `apply_slot_change`, retried like
     * the refill (three attempts, 1 s / 3 s apart — safe, the RPC is
     * idempotent per (request, tour)). Returns how many slots were rebuilt.
     *
     * [skipAll] is the "machine skipped" path: every slot stays open.
     *
     * No leftovers are sent: what is left over rides along in the van and is
     * booked at the end of the tour ([returnTourLeftovers]). On success this
     * stop's leftovers — for a skip, every unit packed for it — are stored in
     * the tour state.
     */
    private suspend fun applyRebuild(
        state: RefillUiState,
        machine: RefillMachine,
        slots: List<RebuildSlot>,
        skipAll: Boolean
    ): Result<Int> {
        val request = machine.changeRequest ?: return Result.success(0)
        if (slots.isEmpty()) return Result.success(0)
        val effective = if (skipAll) slots.map { it.copy(action = RebuildAction.SKIP) } else slots
        val items = effective.map {
            SlotChangeApplyItem(
                itemId = it.item.id,
                action = if (it.action == RebuildAction.DONE) RebuildAction.DONE else RebuildAction.SKIP,
                removed = it.removed,
                filled = it.filled,
                priceSet = it.priceSet,
                ageSet = SlotChange.ageSetPayload(it)
            )
        }

        var lastError: Throwable? = null
        for (attempt in 1..MAX_REFILL_ATTEMPTS) {
            if (attempt > 1) delay(REFILL_BACKOFF_MS[attempt - 2])
            val result = SlotChangeRepository.applySlotChange(
                requestId = request.id,
                tourId = state.tourId,
                warehouseId = state.selectedWarehouseId,
                items = items,
                leftovers = emptyList()
            )
            if (result.isSuccess) {
                storeTourLeftovers(machine, SlotChange.leftovers(effective, machine.rebuildPacked))
                return Result.success(items.count { it.action == RebuildAction.DONE })
            }
            lastError = result.exceptionOrNull()
            // Withdrawn in the office while the tour was running: a retry can
            // never succeed. Nothing is switched; the packed units go back as
            // leftovers and the tour carries on.
            if (lastError?.message?.contains("no longer open") == true) {
                val withdrawn = SlotChange.withdrawn(effective)
                _uiState.update { s ->
                    s.copy(
                        withdrawnRebuildMachines = s.withdrawnRebuildMachines + machine.machine.id,
                        currentRebuild = if (s.rebuildMachineId == machine.machine.id) withdrawn else s.currentRebuild,
                        rebuildWithdrawnNotice = if (effective.any { it.action == RebuildAction.DONE }) machine.machine.displayName else s.rebuildWithdrawnNotice
                    )
                }
                storeTourLeftovers(machine, SlotChange.leftovers(withdrawn, machine.rebuildPacked))
                return Result.success(0)
            }
        }
        return Result.failure(lastError ?: IllegalStateException("apply_slot_change failed"))
    }

    private companion object {
        const val TAG = "RefillViewModel"

        /** Attempts per `refill_machine_trays` call — iOS `for attempt in 1...3`. */
        const val MAX_REFILL_ATTEMPTS = 3

        /** Sleep before attempt 2 and attempt 3 — iOS `backoffSeconds = [1.0, 3.0]`. */
        val REFILL_BACKOFF_MS = longArrayOf(1_000L, 3_000L)
    }
}

/**
 * Product name for a tray's audit-log line, falling back to the slot number
 * for an unassigned slot — the same value iOS writes (`Tray.productName`,
 * `ios/VMflow/Models/Tray.swift:43-45`). Deliberately **not** localized: it
 * is persisted metadata read back by three clients in whatever language the
 * reader is running, not UI text.
 */
private val RefillTray.productLabel: String
    get() = tray.products?.name ?: "Slot ${tray.itemNumber}"
