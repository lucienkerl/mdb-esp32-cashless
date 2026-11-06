package xyz.vmflow.ui.refill

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.VerticalAlignTop
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedIconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import xyz.vmflow.R
import xyz.vmflow.data.MachineAnalysis
import xyz.vmflow.data.RefillLayout
import xyz.vmflow.data.RefillSlotState
import xyz.vmflow.models.RefillMachine
import xyz.vmflow.models.RefillTray
import xyz.vmflow.ui.components.MachineLayoutCell
import xyz.vmflow.ui.components.MachineLayoutGrid
import xyz.vmflow.ui.components.ProductImage
import xyz.vmflow.ui.theme.OfflineGray
import xyz.vmflow.ui.theme.StockGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed
import xyz.vmflow.ui.theme.StockYellow
import xyz.vmflow.ui.theme.VMflowBlue
import xyz.vmflow.ui.theme.VMflowBlueLight

/**
 * Refill step — the screen a driver stands in front of a vending machine
 * with. One machine at a time: a header with the tour's progress and a way
 * to jump to another stop, a card per tray that still wants stock, the
 * already-full trays folded into a single expandable row, and a bottom bar
 * with skip/confirm.
 *
 * Ported from iOS `RefillStepView.swift` (`machineHeader`, `machinePicker`,
 * `refillTrayCard`, `fullTrayRow`, `bottomActionBar`), adapted to Android
 * idiom: a Material [ModalBottomSheet] for the machine picker, and the
 * disclosure group replaced by a hoisted expand/collapse row.
 *
 * **Touch targets are deliberately larger than the rest of the app.** The
 * driver is standing at a machine, often one-handed, sometimes in gloves —
 * the steppers are 64 dp circles (iOS uses 52 pt). Those, and [SlotBadge]
 * before this fix, are a fixed `Modifier.size` — a real trade-off, not an
 * oversight: a touch target that grows with font scale would drift out from
 * under a thumb that has already found it. Everything that is *not* a touch
 * target — "Max", the bottom bar buttons, [SlotBadge] — uses
 * `defaultMinSize` instead, so a long German label or a large font scale
 * grows the row instead of clipping it.
 *
 * No ViewModel reference, same contract as [PackingStep]: immutable state in,
 * bound callbacks out. Per-row aggregates are resolved once in this body —
 * [trayRows], [fullTrayRows], [machinePickerRows] — rather than inside a
 * `LazyColumn` item body; the leaf composables still resolve their own
 * formatted display strings from those values, same as [RefillTrayCard] does
 * today and same split as `PackingStep.packRows`.
 *
 * **The whole screen is inert while [isSaving].** `RefillViewModel.confirmRefill`
 * and `skipMachine` both drop a call that arrives while a write is in flight,
 * and `isSaving` deliberately stays set across the audit write that follows a
 * successful booking — a tap silently swallowed in that window would read as
 * a broken app, so every control that could produce one is visibly disabled
 * and Confirm carries a spinner (same treatment as `BatchAdjustSheet`).
 *
 * @param machine the current stop, `RefillUiState.currentMachineId` resolved
 *   by the caller.
 * @param remainingMachines the tour's unfinished stops, in visit order —
 *   the machine picker's contents. `RefillViewModel.selectMachine` rejects
 *   anything else, so the sheet must not offer anything else.
 * @param machineNumber 1-based position of this stop in the tour, for
 *   "Machine 2 of 5".
 * @param progressFraction stops already finished / total stops, for the bar.
 */
@Composable
fun RefillStepContent(
    machine: RefillMachine,
    remainingMachines: List<RefillMachine>,
    machineNumber: Int,
    machineTotal: Int,
    progressFraction: Float,
    isSaving: Boolean,
    onSelectMachine: (machineId: String) -> Unit,
    onAdjustFillAmount: (trayId: String, amount: Int) -> Unit,
    onFillTrayToCapacity: (trayId: String) -> Unit,
    onFillAllTrays: () -> Unit,
    onConfirmRefill: () -> Unit,
    onSkipMachine: () -> Unit,
    modifier: Modifier = Modifier,
    rebuild: RebuildSectionState? = null,
    rebuildActions: RebuildActions? = null,
    tourNote: TourNoteEditorState? = null,
    onOpenTourNote: () -> Unit = {},
    onSaveTourNote: (text: String) -> Unit = {},
    onDismissTourNote: () -> Unit = {}
) {
    val haptic = LocalHapticFeedback.current
    // The machine can only be confirmed once every slot of its change note is
    // marked rebuilt or not rebuilt (the ViewModel enforces it too).
    val showRebuild = rebuild != null && rebuildActions != null && rebuild.slots.isNotEmpty()
    val rebuildUndecided = showRebuild && rebuild?.slots?.any { it.action == null } == true

    // Both keyed on the machine id: the driver moving to the next stop must
    // not inherit the previous machine's open sheet or expanded full-tray
    // list. `machine` is a value type, so keying on the id (not the object)
    // keeps the state across a stock update of the same machine.
    var showPicker by remember(machine.machine.id) { mutableStateOf(false) }
    // `rememberSaveable`, not `remember`: a rotation must not silently
    // re-collapse a section the driver just opened to check something.
    var fullTraysExpanded by rememberSaveable(machine.machine.id) { mutableStateOf(false) }
    // The slot the driver is working on: set by tapping the layout grid, and
    // nothing else. It rings that cell and outlines the matching tray card —
    // it changes no stock, and there is no path from here to a fill amount.
    var selectedTrayId by rememberSaveable(machine.machine.id) { mutableStateOf<String?>(null) }

    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    val rows = trayRows(machine)
    val fullTrays = fullTrayRows(machine)
    val layout = machineLayout(machine, selectedTrayId)
    // `isInTour` as well as `fillAmount > 0`, matching `confirmRefill`'s own
    // filter (`RefillViewModel.kt`): this is the header count of "trays to
    // refill" and it must mean the same thing as the trays that actually get
    // booked. The two agree today only because `applyTourInclusion` zeroes
    // every excluded tray — the exact transitive reliance `confirmRefill`
    // refuses to accept for the write itself, so the read-out does not
    // accept it either.
    val traysToRefill = machine.trays.count { it.fillAmount > 0 && it.isInTour }

    // Scroll targets for a grid tap. Derived from the very same conditions the
    // `LazyColumn` below emits its items under — kept adjacent so the two
    // cannot drift apart — because `LazyListState` can only be scrolled by
    // index, not by item key. Item order is:
    //   [layout]?  ·  [rebuild]?  ·  [fill-all | empty]  ·  rows…  ·  [full-trays]?
    val showLayout = layout.rowCount > 0
    val headerCount = (if (showLayout) 1 else 0) + (if (showRebuild) 1 else 0)
    val firstCardIndex = headerCount + 1
    val fullTraysIndex = headerCount + when {
        rows.isNotEmpty() -> 1 + rows.size
        showRebuild -> 0 // no "nothing to fill" item next to a change note
        else -> 1
    }

    // A grid tap is pure navigation: select the slot, bring its card into view.
    val onSlotSelected: (String) -> Unit = { trayId ->
        selectedTrayId = trayId
        val cardIndex = rows.indexOfFirst { it.trayId == trayId }
        when {
            cardIndex >= 0 -> {
                scope.launch { listState.animateScrollToItem(firstCardIndex + cardIndex) }
            }
            // Already full: it has no card of its own, only a line in the
            // collapsed section — so open that and scroll to it.
            fullTrays.any { it.trayId == trayId } -> {
                fullTraysExpanded = true
                scope.launch { listState.animateScrollToItem(fullTraysIndex) }
            }
            // A slot this tour brought nothing for (`isInTour == false`) is in
            // neither list. It still takes the selection ring, so the tap is
            // acknowledged rather than silently dropped.
            else -> Unit
        }
    }

    Column(modifier = modifier.fillMaxSize()) {
        MachineHeader(
            machineName = machine.machine.displayName,
            machineNumber = machineNumber,
            machineTotal = machineTotal,
            traysToRefill = traysToRefill,
            progressFraction = progressFraction,
            // One remaining stop means there is nowhere to switch to — iOS
            // disables the header button on the same condition.
            canSwitchMachine = remainingMachines.size > 1 && !isSaving,
            onOpenPicker = { showPicker = true }
        )

        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            if (showLayout) {
                item(key = "layout") {
                    MachineLayoutSection(
                        rowCount = layout.rowCount,
                        cells = layout.cells,
                        onSlotClick = onSlotSelected
                    )
                }
            }

            if (showRebuild && rebuild != null && rebuildActions != null) {
                item(key = "rebuild") {
                    RebuildSection(
                        state = rebuild,
                        actions = rebuildActions,
                        enabled = !isSaving
                    )
                }
            }

            if (rows.isNotEmpty()) {
                items(items = rows, key = { it.trayId }) { row ->
                    RefillTrayCard(
                        row = row,
                        enabled = !isSaving,
                        isSelected = row.trayId == selectedTrayId,
                        onDecrement = {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            onAdjustFillAmount(row.trayId, row.fillAmount - 1)
                        },
                        onIncrement = {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            onAdjustFillAmount(row.trayId, row.fillAmount + 1)
                        },
                        onFillToCapacity = {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            onFillTrayToCapacity(row.trayId)
                        }
                    )
                }
            } else if (!showRebuild) {
                item(key = "empty") { NothingToFill() }
            }

            if (fullTrays.isNotEmpty()) {
                item(key = "full-trays") {
                    FullTraysSection(
                        trays = fullTrays,
                        expanded = fullTraysExpanded,
                        onToggle = { fullTraysExpanded = !fullTraysExpanded }
                    )
                }
            }
        }

        RefillBottomBar(
            isSaving = isSaving,
            confirmBlockedHint = if (rebuildUndecided) {
                stringResource(R.string.refill_rebuild_decide_all)
            } else {
                null
            },
            onSkip = {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                onSkipMachine()
            },
            onTourNote = onOpenTourNote,
            onConfirm = {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                onConfirmRefill()
            }
        )
    }

    if (tourNote != null && tourNote.machineId == machine.machine.id) {
        TourNoteSheet(
            state = tourNote,
            machineName = machine.machine.displayName,
            onSave = onSaveTourNote,
            onDismiss = onDismissTourNote
        )
    }

    if (showPicker) {
        MachinePickerSheet(
            rows = machinePickerRows(remainingMachines, machine.machine.id),
            onSelect = { id ->
                onSelectMachine(id)
                showPicker = false
            },
            onDismiss = { showPicker = false }
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Row state. Resolved once per recomposition of [RefillStepContent] — whose
// body never skips, it holds the machine — and handed down as plain values,
// so a leaf composable never has to resolve a string or re-derive a number.
// Same pattern and reasoning as `PackingStep.packRows`.
// ─────────────────────────────────────────────────────────────────────────

/** One tray card. */
private data class TrayRowState(
    val trayId: String,
    val itemNumber: Int,
    val label: String,
    val imagePath: String?,
    val currentStock: Int,
    val targetStock: Int,
    val capacity: Int,
    val fillAmount: Int,
    /** `capacity - currentStock`, clamped: what still physically fits. */
    val maxFill: Int
) {
    val canDecrement: Boolean get() = fillAmount > 0
    val canIncrement: Boolean get() = fillAmount < maxFill
    val isEmptySlot: Boolean get() = currentStock <= 0
}

/** One line of the collapsed "already full" section. */
private data class FullTrayRowState(
    val trayId: String,
    val itemNumber: Int,
    val label: String
)

/** One candidate row of the machine picker sheet. */
private data class MachinePickerRowState(
    val machineId: String,
    val displayName: String,
    val isCurrent: Boolean,
    val trayCount: Int,
    val unitCount: Int
)

/**
 * The tray cards: every tray this tour brought stock for
 * ([RefillTray.isInTour]) that still has room.
 *
 * A tray the driver has dialled back to `fillAmount == 0` **stays** a card —
 * that is the only way to bring it back up (iOS says the same in
 * `RefillStepView.swift:36-38`). A tray that is genuinely full
 * (`deficit == 0`) moves to [fullTrayRows] instead: the brief asks for trays
 * that need nothing to be collapsed into one row rather than rendered as
 * cards, and `applyTourInclusion` marks a packed product's already-full tray
 * `isInTour = true`, so without this split such a tray would render twice —
 * as a dead card with a disabled stepper *and* in the full-trays list (iOS
 * has exactly that duplicate).
 */
@Composable
private fun trayRows(machine: RefillMachine): List<TrayRowState> {
    val context = LocalContext.current
    return machine.trays
        .filter { it.isInTour && it.deficit > 0 }
        .map { refillTray ->
            TrayRowState(
                trayId = refillTray.tray.id,
                itemNumber = refillTray.tray.itemNumber,
                label = refillTray.tray.products?.name?.takeIf { it.isNotBlank() }
                    ?: context.getString(
                        R.string.machine_card_unassigned_slot,
                        refillTray.tray.itemNumber
                    ),
                imagePath = refillTray.tray.products?.imagePath,
                currentStock = refillTray.tray.currentStock,
                targetStock = refillTray.targetStock,
                capacity = refillTray.tray.capacity,
                fillAmount = refillTray.fillAmount,
                maxFill = refillTray.maxFill.coerceAtLeast(0)
            )
        }
}

/** Trays that want nothing: nothing dialled in and no deficit. iOS's `fullTrays`. */
@Composable
private fun fullTrayRows(machine: RefillMachine): List<FullTrayRowState> {
    val context = LocalContext.current
    return machine.trays
        .filter { it.fillAmount == 0 && it.deficit == 0 }
        .map { refillTray ->
            FullTrayRowState(
                trayId = refillTray.tray.id,
                itemNumber = refillTray.tray.itemNumber,
                label = refillTray.tray.products?.name?.takeIf { it.isNotBlank() }
                    ?: context.getString(
                        R.string.machine_card_unassigned_slot,
                        refillTray.tray.itemNumber
                    )
            )
        }
}

/**
 * The machine picker's rows: one per unfinished stop, with the two
 * aggregates ("N trays / M units") the summary line needs pre-summed. No
 * string resolution here — the summary and title text stay in
 * [MachinePickerSheet], same split as [trayRows] leaving a tray's formatted
 * labels to [RefillTrayCard].
 */
private fun machinePickerRows(
    machines: List<RefillMachine>,
    currentMachineId: String
): List<MachinePickerRowState> = machines.map { candidate ->
    MachinePickerRowState(
        machineId = candidate.machine.id,
        displayName = candidate.machine.displayName,
        isCurrent = candidate.machine.id == currentMachineId,
        trayCount = candidate.trays.count { it.fillAmount > 0 },
        unitCount = candidate.trays.sumOf { it.fillAmount }
    )
}

/**
 * Stock-level colour. Fixed tokens, never `MaterialTheme.colorScheme`: the
 * brand scheme's primary/secondary/tertiary collapse into near-identical
 * tones in dark mode, which is useless for a bar you read at a glance.
 */
private fun stockColor(fraction: Float): Color = when {
    fraction < 0.25f -> StockRed
    fraction < 0.5f -> StockOrange
    fraction < 0.75f -> StockYellow
    else -> StockGreen
}

// ─────────────────────────────────────────────────────────────────────────
// Machine layout grid
// ─────────────────────────────────────────────────────────────────────────

/** Alpha of an in-tour cell's fill — same weight the analysis grid uses. */
private const val SLOT_FILL_ALPHA = 0.35f

/**
 * Alpha of a slot this tour brought nothing for. Deliberately much lower: the
 * slot is physically in the machine and has to be drawn, but it must not be
 * mistakable for one the driver is meant to open.
 */
private const val SLOT_FILL_ALPHA_NOT_IN_TOUR = 0.12f

/**
 * Alpha of the foreground scrim drawn over a slot's product photo
 * ([MachineLayoutCell.foreground]). [background] alone is invisible on any
 * slot with a photo — the photo fills the whole cell and paints on top of it
 * — so this scrim has to carry the state colour on its own. It is deliberately
 * uniform across every state, [RefillSlotState.NOT_IN_TOUR] included: at the
 * same strength, [OfflineGray]'s neutral, desaturated tone already reads as
 * "dimmed" next to the four vivid state colours, so a second, lower alpha
 * tier is not needed to keep it distinguishable. Strong enough to name the
 * state at a glance; translucent enough that the photo underneath — which
 * still matters, it is how the driver recognises the product — stays visible
 * through it.
 */
private const val SLOT_SCRIM_ALPHA = 0.55f

/**
 * Fill-state colour for a layout cell. Fixed tokens, same argument as
 * [stockColor], and deliberately the *same palette* — red for empty, orange
 * for low, green for stocked — so the grid and the tray cards under it speak
 * one colour language.
 *
 * The same palette, **not** the same thresholds, and they genuinely differ:
 * [stockColor] bands a bar at 0.25 / 0.5 / 0.75 (four steps, yellow
 * included), while [xyz.vmflow.data.RefillLayout.classify] splits a slot once,
 * at `LOW_FRACTION = 0.5`. A slot at 10 % of capacity is therefore orange in
 * the grid and red on its card. That is acceptable because the two answer
 * different questions at different resolutions: the grid says "does this slot
 * need opening on this visit" (empty / low / fine), the card's bar quantifies
 * how full the slot is while the driver dials a number into it. A grid that
 * resolved four levels in a 30 dp cell would trade a legible map for a
 * precision the driver reads off the card anyway.
 *
 * [RefillSlotState.JUST_FILLED] gets the brand blue rather than a fifth point on
 * that ramp: "the driver has dialled stock in here" is not a stock level, and
 * blue is already what this screen uses for a non-zero fill amount.
 *
 * Plain function, not `@Composable`: [machineLayout] resolves [isDark] once,
 * outside its `remember` block, and this is called from inside that block —
 * `remember`'s calculation lambda cannot itself call a composable.
 */
private fun RefillSlotState.slotColor(isDark: Boolean): Color = when (this) {
    RefillSlotState.NOT_IN_TOUR -> OfflineGray
    RefillSlotState.JUST_FILLED -> if (isDark) VMflowBlueLight else VMflowBlue
    RefillSlotState.EMPTY -> StockRed
    RefillSlotState.LOW -> StockOrange
    RefillSlotState.FULL -> StockGreen
}

/**
 * The ring around the slot the driver is working on. Neutral on purpose: it is
 * drawn over five state colours and, where a product has a photo, over the photo
 * — any hue there would read as a sixth state. Black on light and white on dark
 * are the only two that separate from all of them.
 *
 * Plain function for the same reason as [slotColor]: called from inside
 * [machineLayout]'s `remember` block.
 */
private fun slotSelectionColor(isDark: Boolean): Color = if (isDark) Color.White else Color.Black

/** The machine's physical layout, ready for [MachineLayoutGrid]. */
private data class MachineLayoutState(
    val rowCount: Int,
    val cells: List<MachineLayoutCell>
)

/**
 * Build the layout grid for the current stop: **every** slot in the machine,
 * not just the ones on the tour — the driver is looking at a physical shelf and
 * a hole in the drawing would send them to the wrong slot. Slots the tour
 * brought nothing for are dimmed instead of omitted.
 *
 * Geometry comes from [MachineAnalysis] (`slotRowCol` / `computeSlotWidths`) —
 * the same unit-tested math the analysis tab's grid uses, not a second copy.
 * The state bucket comes from [RefillLayout.classify]. This function only
 * resolves colours and the spoken description on top of them.
 *
 * Wrapped in `remember`: this runs on every recomposition of [RefillStepContent]
 * — including every +/− stepper press — and without memoisation it would map
 * every tray and resolve one or two strings per tray each time, for output the
 * grid's own internal `remember` (`buildGridEntries`) would then discard as
 * unchanged. Keyed on [machine], [selectedTrayId], the dark-theme flag, and
 * every string template the cells are built from — `remember`'s calculation
 * lambda cannot itself call a composable (no `stringResource`, no
 * `isSystemInDarkTheme`), so all of those are read here, outside the lambda,
 * and passed in as both inputs to the computation and keys that invalidate it
 * on an in-place configuration change.
 */
@Composable
private fun machineLayout(machine: RefillMachine, selectedTrayId: String?): MachineLayoutState {
    val isDark = isSystemInDarkTheme()
    val notInTourLabel = stringResource(R.string.refill_step_layout_state_not_in_tour)
    val fillingTemplate = stringResource(R.string.refill_step_layout_state_filling)
    val emptyLabel = stringResource(R.string.refill_step_layout_state_empty)
    val lowLabel = stringResource(R.string.refill_step_layout_state_low)
    val fullLabel = stringResource(R.string.refill_step_layout_state_full)
    val slotTemplate = stringResource(R.string.refill_step_layout_slot)
    val slotEmptyTemplate = stringResource(R.string.refill_step_layout_slot_empty)
    val slotSelectedTemplate = stringResource(R.string.refill_step_layout_slot_selected)

    return remember(
        machine,
        selectedTrayId,
        isDark,
        notInTourLabel,
        fillingTemplate,
        emptyLabel,
        lowLabel,
        fullLabel,
        slotTemplate,
        slotEmptyTemplate,
        slotSelectedTemplate,
    ) {
        val selectionColor = slotSelectionColor(isDark)
        val widths = MachineAnalysis.computeSlotWidths(machine.trays.map { it.tray.itemNumber })

        val cells = machine.trays.map { refillTray ->
            val itemNumber = refillTray.tray.itemNumber
            val position = MachineAnalysis.slotRowCol(itemNumber)
            val state = RefillLayout.classify(
                isInTour = refillTray.isInTour,
                fillAmount = refillTray.fillAmount,
                currentStock = refillTray.tray.currentStock,
                capacity = refillTray.tray.capacity
            )
            val isSelected = refillTray.tray.id == selectedTrayId
            val stateColor = state.slotColor(isDark)

            // Never colour alone: the state is spoken with the slot number and
            // the product, and so is the selection.
            val stateLabel = when (state) {
                RefillSlotState.NOT_IN_TOUR -> notInTourLabel
                RefillSlotState.JUST_FILLED -> String.format(fillingTemplate, refillTray.fillAmount)
                RefillSlotState.EMPTY -> emptyLabel
                RefillSlotState.LOW -> lowLabel
                RefillSlotState.FULL -> fullLabel
            }
            val productName = refillTray.tray.products?.name?.takeIf { it.isNotBlank() }
            val described = if (productName != null) {
                String.format(slotTemplate, itemNumber, productName, stateLabel)
            } else {
                String.format(slotEmptyTemplate, itemNumber, stateLabel)
            }

            MachineLayoutCell(
                id = refillTray.tray.id,
                itemNumber = itemNumber,
                row = position.row,
                column = position.column,
                width = widths[itemNumber] ?: 1,
                imagePath = refillTray.tray.products?.imagePath,
                background = stateColor.copy(
                    alpha = if (state == RefillSlotState.NOT_IN_TOUR) {
                        SLOT_FILL_ALPHA_NOT_IN_TOUR
                    } else {
                        SLOT_FILL_ALPHA
                    }
                ),
                outline = selectionColor.takeIf { isSelected },
                foreground = stateColor.copy(alpha = SLOT_SCRIM_ALPHA),
                contentDescription = if (isSelected) {
                    String.format(slotSelectedTemplate, described)
                } else {
                    described
                }
            )
        }

        MachineLayoutState(
            rowCount = cells.maxOfOrNull { it.row }?.plus(1) ?: 0,
            cells = cells
        )
    }
}

/**
 * The grid above the tray cards. Read-only navigation: a tap selects a slot and
 * scrolls to its card, and there is deliberately no control here that could
 * change a fill amount — a second, unlabelled way to alter what the driver is
 * about to book is exactly what this must not be.
 */
@Composable
private fun MachineLayoutSection(
    rowCount: Int,
    cells: List<MachineLayoutCell>,
    onSlotClick: (trayId: String) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Text(
            text = stringResource(R.string.refill_step_layout_title),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold
        )
        Text(
            text = stringResource(R.string.refill_step_layout_hint),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        MachineLayoutGrid(
            rowCount = rowCount,
            cells = cells,
            onCellClick = onSlotClick
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Machine header + picker
// ─────────────────────────────────────────────────────────────────────────

@Composable
private fun MachineHeader(
    machineName: String,
    machineNumber: Int,
    machineTotal: Int,
    traysToRefill: Int,
    progressFraction: Float,
    canSwitchMachine: Boolean,
    onOpenPicker: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        tonalElevation = 3.dp
    ) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = stringResource(
                        R.string.refill_step_machine_progress,
                        machineNumber,
                        machineTotal
                    ),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = pluralStringResource(
                        R.plurals.refill_step_trays_to_refill,
                        traysToRefill,
                        traysToRefill
                    ),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Spacer(modifier = Modifier.height(8.dp))

            val animatedProgress by animateFloatAsState(
                targetValue = progressFraction.coerceIn(0f, 1f),
                animationSpec = tween(300),
                label = "tour_progress"
            )
            LinearProgressIndicator(
                progress = { animatedProgress },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(RoundedCornerShape(3.dp)),
                strokeCap = StrokeCap.Round
            )

            Spacer(modifier = Modifier.height(8.dp))

            // The whole strip is the switch control, not a small chevron: it
            // is hit standing at a machine. A `Surface(onClick)` merges its
            // descendants' semantics, so the chevron's contentDescription is
            // what a screen reader announces for the row.
            Surface(
                onClick = onOpenPicker,
                enabled = canSwitchMachine,
                shape = RoundedCornerShape(12.dp),
                color = Color.Transparent,
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = 48.dp)
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = machineName,
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f)
                    )
                    if (canSwitchMachine) {
                        Spacer(modifier = Modifier.width(8.dp))
                        Icon(
                            imageVector = Icons.Default.ExpandMore,
                            contentDescription = stringResource(R.string.refill_step_change_machine),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

/**
 * Machine picker. The driver does not necessarily drive the planned order,
 * so any unfinished stop can be made the current one.
 *
 * Only [machines] — the tour's unfinished stops — are offered:
 * `RefillViewModel.selectMachine` silently rejects a finished or never-packed
 * machine, so a row for one would be a dead tap.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MachinePickerSheet(
    rows: List<MachinePickerRowState>,
    onSelect: (machineId: String) -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        // One flat LazyColumn rather than a Column wrapping a list: the title
        // and the cancel button ride along as items, so nothing can be pushed
        // out of reach by a long tour and there is no nested-scroll container
        // inside the sheet.
        LazyColumn(modifier = Modifier.fillMaxWidth()) {
            item(key = "title") {
                Text(
                    text = stringResource(R.string.refill_step_picker_title),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp)
                )
            }

            items(items = rows, key = { it.machineId }) { row ->
                Surface(
                    onClick = { onSelect(row.machineId) },
                    color = Color.Transparent,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .defaultMinSize(minHeight = 64.dp)
                            .padding(horizontal = 24.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = row.displayName,
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = if (row.isCurrent) FontWeight.Bold else FontWeight.Normal
                            )
                            Text(
                                text = stringResource(
                                    R.string.refill_step_picker_summary,
                                    row.trayCount,
                                    row.unitCount
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        if (row.isCurrent) {
                            Spacer(modifier = Modifier.width(12.dp))
                            Icon(
                                imageVector = Icons.Default.CheckCircle,
                                contentDescription = stringResource(
                                    R.string.refill_step_picker_current
                                ),
                                tint = StockGreen
                            )
                        }
                    }
                }
                HorizontalDivider()
            }

            item(key = "cancel") {
                TextButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp, vertical = 8.dp)
                        .defaultMinSize(minHeight = 48.dp)
                ) {
                    Text(stringResource(R.string.action_cancel))
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Tray card
// ─────────────────────────────────────────────────────────────────────────

/**
 * @param isSelected this is the card the driver reached by tapping its slot in
 *   the layout grid. Purely a marker so the eye lands on the right card after
 *   the scroll — it changes nothing about what the card does. `colorScheme
 *   .primary` here rather than a fixed token: this is a Material surface
 *   affordance, not one of the layout grid's state colours, and there is no
 *   sibling hue for it to collapse against.
 */
@Composable
private fun RefillTrayCard(
    row: TrayRowState,
    enabled: Boolean,
    isSelected: Boolean,
    onDecrement: () -> Unit,
    onIncrement: () -> Unit,
    onFillToCapacity: () -> Unit,
    modifier: Modifier = Modifier
) {
    val currentFraction = if (row.capacity > 0) row.currentStock.toFloat() / row.capacity else 0f
    val targetFraction = if (row.capacity > 0) row.targetStock.toFloat() / row.capacity else 0f
    val currentColor = stockColor(currentFraction)
    val targetColor = stockColor(targetFraction)

    Card(
        modifier = modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
        border = if (isSelected) {
            BorderStroke(2.dp, MaterialTheme.colorScheme.primary)
        } else {
            null
        }
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SlotBadge(
                    itemNumber = row.itemNumber,
                    color = if (row.isEmptySlot) StockRed else StockOrange
                )
                Spacer(modifier = Modifier.width(12.dp))
                ProductImage(
                    imagePath = row.imagePath,
                    contentDescription = null,
                    size = 48.dp
                )
                Spacer(modifier = Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = row.label,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                    Spacer(modifier = Modifier.height(2.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = row.currentStock.toString(),
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Bold,
                            color = currentColor
                        )
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowForward,
                            // Decorative: the two numbers beside it are the content.
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier
                                .padding(horizontal = 4.dp)
                                .size(14.dp)
                        )
                        Text(
                            text = row.targetStock.toString(),
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Bold,
                            color = targetColor
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = stringResource(R.string.refill_step_of_capacity, row.capacity),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            StockChangeBars(
                currentFraction = currentFraction,
                targetFraction = targetFraction,
                currentColor = currentColor,
                targetColor = targetColor
            )

            Spacer(modifier = Modifier.height(16.dp))

            // Large controls: standing at a machine, one-handed, in gloves.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                FilledIconButton(
                    onClick = onDecrement,
                    enabled = enabled && row.canDecrement,
                    modifier = Modifier.size(64.dp),
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant,
                        contentColor = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                ) {
                    Icon(
                        imageVector = Icons.Default.Remove,
                        contentDescription = stringResource(
                            R.string.refill_step_decrement,
                            row.label
                        ),
                        modifier = Modifier.size(30.dp)
                    )
                }

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = stringResource(R.string.refill_step_fill_amount, row.fillAmount),
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center,
                        color = if (row.fillAmount > 0) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        }
                    )
                    Text(
                        text = pluralStringResource(
                            R.plurals.refill_step_fill_unit,
                            row.fillAmount
                        ),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                FilledIconButton(
                    onClick = onIncrement,
                    enabled = enabled && row.canIncrement,
                    modifier = Modifier.size(64.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Add,
                        contentDescription = stringResource(
                            R.string.refill_step_increment,
                            row.label
                        ),
                        modifier = Modifier.size(30.dp)
                    )
                }

                Spacer(modifier = Modifier.width(12.dp))

                Button(
                    onClick = onFillToCapacity,
                    enabled = enabled && row.canIncrement,
                    modifier = Modifier.defaultMinSize(minWidth = 72.dp, minHeight = 56.dp)
                ) {
                    Text(
                        text = stringResource(R.string.refill_step_fill_max),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1
                    )
                }
            }
        }
    }
}

/**
 * Slot number, the machine's own label for the tray.
 *
 * `defaultMinSize`, not a fixed `size(32.dp)`: a two-digit slot number at a
 * large system font scale needs more than 32 dp to avoid clipping, and this
 * badge is not a touch target — nothing is lost by letting it grow.
 */
@Composable
private fun SlotBadge(itemNumber: Int, color: Color, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.defaultMinSize(minWidth = 32.dp, minHeight = 32.dp),
        shape = RoundedCornerShape(percent = 50),
        color = color
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(
                text = itemNumber.toString(),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                color = Color.White
            )
        }
    }
}

/** Before/after stock bars, iOS's two `StockBar`s with an arrow between them. */
@Composable
private fun StockChangeBars(
    currentFraction: Float,
    targetFraction: Float,
    currentColor: Color,
    targetColor: Color,
    modifier: Modifier = Modifier
) {
    val animatedCurrent by animateFloatAsState(
        targetValue = currentFraction.coerceIn(0f, 1f),
        animationSpec = tween(400),
        label = "current_bar"
    )
    val animatedTarget by animateFloatAsState(
        targetValue = targetFraction.coerceIn(0f, 1f),
        animationSpec = tween(400),
        label = "target_bar"
    )

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        LinearProgressIndicator(
            progress = { animatedCurrent },
            modifier = Modifier
                .weight(1f)
                .height(8.dp)
                .clip(RoundedCornerShape(4.dp)),
            color = currentColor,
            trackColor = MaterialTheme.colorScheme.surfaceVariant,
            strokeCap = StrokeCap.Round
        )
        Icon(
            imageVector = Icons.AutoMirrored.Filled.ArrowForward,
            // Decorative: the numbers above say current → target.
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .padding(horizontal = 8.dp)
                .size(14.dp)
        )
        LinearProgressIndicator(
            progress = { animatedTarget },
            modifier = Modifier
                .weight(1f)
                .height(8.dp)
                .clip(RoundedCornerShape(4.dp)),
            color = targetColor,
            trackColor = MaterialTheme.colorScheme.surfaceVariant,
            strokeCap = StrokeCap.Round
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Full trays + empty state + bottom bar
// ─────────────────────────────────────────────────────────────────────────

/**
 * Trays that want nothing, folded into one expandable row instead of a
 * screenful of dead cards. Collapsed by default; the expanded state is
 * hoisted into [RefillStepContent] so it survives the `LazyColumn` recycling
 * this item.
 */
@Composable
private fun FullTraysSection(
    trays: List<FullTrayRowState>,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = StockGreen.copy(alpha = 0.08f))
    ) {
        Column {
            Surface(
                onClick = onToggle,
                color = Color.Transparent,
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = 56.dp)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Default.CheckCircle,
                        // Decorative: the row's text says the same.
                        contentDescription = null,
                        tint = StockGreen,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = pluralStringResource(
                            R.plurals.refill_step_full_trays,
                            trays.size,
                            trays.size
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Icon(
                        imageVector = if (expanded) {
                            Icons.Default.ExpandLess
                        } else {
                            Icons.Default.ExpandMore
                        },
                        contentDescription = stringResource(
                            if (expanded) {
                                R.string.refill_step_full_trays_collapse
                            } else {
                                R.string.refill_step_full_trays_expand
                            }
                        ),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            if (expanded) {
                trays.forEach { tray ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 16.dp, end = 16.dp, bottom = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        SlotBadge(itemNumber = tray.itemNumber, color = StockGreen)
                        Spacer(modifier = Modifier.width(12.dp))
                        Text(
                            text = tray.label,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }
        }
    }
}

/**
 * Nothing dialled in for this machine. Not an error: the driver can still
 * confirm the visit (the ViewModel records a 0/0 stop) or skip it.
 */
@Composable
private fun NothingToFill(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            imageVector = Icons.Default.CheckCircle,
            contentDescription = null,
            tint = StockGreen,
            modifier = Modifier.size(48.dp)
        )
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = stringResource(R.string.refill_step_no_trays),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

/**
 * More actions (skip, note for next tour) + confirm.
 *
 * Everything is disabled for the whole [isSaving] window — which the ViewModel
 * holds across the audit write that follows a successful booking — and
 * Confirm shows a spinner while it lasts, so a tap the re-entrancy guard
 * would have dropped can't be made in the first place.
 */
@Composable
private fun RefillBottomBar(
    isSaving: Boolean,
    onSkip: () -> Unit,
    onTourNote: () -> Unit,
    onConfirm: () -> Unit,
    modifier: Modifier = Modifier,
    confirmBlockedHint: String? = null
) {
    var menuOpen by remember { mutableStateOf(false) }
    Column(modifier = modifier.fillMaxWidth()) {
        HorizontalDivider()
        if (confirmBlockedHint != null) {
            Text(
                text = confirmBlockedHint,
                style = MaterialTheme.typography.bodySmall,
                color = StockOrange,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp)
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Skip lives in the overflow menu next to "note for next tour"
            // (web and iOS alike); a 60 dp outlined icon button keeps the
            // touch target large for a driver standing at the machine.
            Box {
                OutlinedIconButton(
                    onClick = { menuOpen = true },
                    modifier = Modifier.size(60.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.MoreVert,
                        contentDescription = stringResource(R.string.refill_step_more_actions)
                    )
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.refill_step_skip_machine)) },
                        leadingIcon = { Icon(Icons.Default.SkipNext, contentDescription = null) },
                        enabled = !isSaving,
                        onClick = {
                            menuOpen = false
                            onSkip()
                        }
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.refill_tour_note_title)) },
                        leadingIcon = { Icon(Icons.Default.EditNote, contentDescription = null) },
                        onClick = {
                            menuOpen = false
                            onTourNote()
                        }
                    )
                }
            }
            Button(
                onClick = onConfirm,
                enabled = !isSaving && confirmBlockedHint == null,
                modifier = Modifier
                    .weight(1f)
                    .defaultMinSize(minHeight = 60.dp)
            ) {
                if (isSaving) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        color = MaterialTheme.colorScheme.onPrimary,
                        strokeWidth = 2.dp
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = stringResource(R.string.refill_step_saving),
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = 1
                    )
                } else {
                    Icon(
                        imageVector = Icons.Default.CheckCircle,
                        contentDescription = null,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = stringResource(R.string.refill_step_confirm),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }
        }
    }
}
