package xyz.vmflow.ui.refill

import androidx.compose.foundation.BorderStroke
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.clickable
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.material3.AlertDialog
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DisabledByDefault
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocalShipping
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import xyz.vmflow.R
import xyz.vmflow.data.MachineStockTier
import xyz.vmflow.data.RefillTourLogic
import xyz.vmflow.data.SlotChange
import xyz.vmflow.models.RefillMachine
import xyz.vmflow.models.Warehouse
import xyz.vmflow.ui.components.ProductImage
import xyz.vmflow.ui.theme.RebuildViolet
import xyz.vmflow.ui.theme.StockGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed
import xyz.vmflow.ui.theme.VMflowBlue
import xyz.vmflow.ui.theme.VMflowBlueLight

/**
 * Pack step — the screen a driver uses to load the van from a warehouse
 * before setting out. Product-centric: one card per product with one line
 * per machine. A line holds everything the machine gets of the product —
 * the refill and the units for its slot rebuilds — under one tick ("in the
 * box") and one amount. Ported from iOS `PackingStepView.swift`
 * (`AllPackingList`, `MachinePackingList`, `PackProductCard`, `PackLineRow`,
 * `bottomBar`, `OpenPackLinesSheet`).
 *
 * **Every quantity comes from the state's line API** ([packLine] and
 * friends in `PackLines.kt`); nothing here recomputes a packing quantity
 * from trays or stock.
 *
 * No ViewModel reference: like `WarehouseStockTab`, this takes the immutable
 * [RefillUiState] plus already-bound callbacks.
 *
 * @param onReloadWarehouseStock re-fetches the warehouse's stock and pick
 *   order (and the warehouse list itself when there is no selection) — the
 *   retry path for a failed stock fetch, and deliberately *not* a reload of
 *   the machine list. See [StockCapWarningCard].
 */
@Composable
fun PackingStep(
    uiState: RefillUiState,
    chipItemCount: (machineId: String?) -> Int,
    chipIsFullyPacked: (machineId: String?) -> Boolean,
    onSelectWarehouse: (String) -> Unit,
    onReloadWarehouseStock: () -> Unit,
    onSelectChip: (machineId: String?) -> Unit,
    onToggleLine: (machineId: String, productId: String) -> Unit,
    onSetLineQuantity: (machineId: String, productId: String, quantity: Int) -> Unit,
    onPackEverything: () -> Unit,
    onPackAllForMachine: (machineId: String) -> Unit,
    onStartTour: () -> Unit,
    modifier: Modifier = Modifier,
    onCompleteTourNote: (noteId: String) -> Unit = {}
) {
    val haptic = LocalHapticFeedback.current

    // Chips: "All" plus one per machine with something to pack or rebuild,
    // in the tour's urgency order.
    val chipMachines = uiState.machines.filter { machine ->
        uiState.lineProductIds(machine.machine.id).isNotEmpty() ||
            machine.changeRequest?.items?.isNotEmpty() == true
    }

    // A chip whose machine has since lost every need (or vanished) falls back
    // to "All" rather than rendering an empty list under a dead chip.
    val activeChip = uiState.activeChip?.takeIf { id -> chipMachines.any { it.machine.id == id } }
    val activeMachineName = chipMachines
        .firstOrNull { it.machine.id == activeChip }?.machine?.displayName

    // …and the correction is written back, or the dead id stays selected in
    // the ViewModel and the filter silently snaps back to it the moment that
    // machine regains a need.
    val chipSelectionIsStale = uiState.activeChip != null && activeChip == null
    LaunchedEffect(chipSelectionIsStale) {
        if (chipSelectionIsStale) onSelectChip(null)
    }

    val allChipFullyPacked = chipIsFullyPacked(null)
    val isActiveChipFullyPacked =
        if (activeChip == null) allChipFullyPacked else chipIsFullyPacked(activeChip)

    // Chip label state resolved here, next to the card states and for the same
    // reason (see the note below `PackingStep`).
    val chipStates = buildList {
        add(
            ChipState(
                machineId = null,
                name = stringResource(R.string.refill_pack_chip_all),
                count = chipItemCount(null),
                isFullyPacked = allChipFullyPacked
            )
        )
        chipMachines.forEach { machine ->
            val id = machine.machine.id
            add(
                ChipState(
                    machineId = id,
                    name = machine.machine.displayName,
                    count = chipItemCount(id),
                    isFullyPacked = chipIsFullyPacked(id),
                    // PWA `effectiveStockHealth`: OK once the selected warehouse
                    // holds none of this machine's products needing refill.
                    tier = RefillTourLogic.displayTier(machine, uiState.warehouseStock, uiState.stockLoaded)
                )
            )
        }
    }

    val changeNotes = uiState.machines
        .filter { machine ->
            machine.changeRequest?.items?.isNotEmpty() == true &&
                (activeChip == null || machine.machine.id == activeChip)
        }
        .map { machine ->
            ChangeNoteState(
                machineId = machine.machine.id,
                machineName = machine.machine.displayName,
                items = machine.changeRequest?.items.orEmpty()
            )
        }

    val cards = packCards(uiState, activeChip)
    val (boxPacked, boxTotal) = uiState.packBox
    val openLines = uiState.openPackLines
    var showOpenLines by remember { mutableStateOf(false) }

    Column(modifier = modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // "Notes from last time" first: what to bring along decides what
            // goes into the van before anything else is packed.
            if (uiState.tourNotes.isNotEmpty()) {
                item(key = "tour-notes") {
                    TourNotesCard(
                        notes = uiState.tourNotes,
                        machineNames = uiState.machines.associate { it.machine.id to it.machine.displayName },
                        onDone = onCompleteTourNote,
                        error = uiState.tourNoteError
                    )
                }
            }

            if (uiState.warehouses.size > 1) {
                item(key = "warehouse-picker") {
                    WarehousePickerField(
                        warehouses = uiState.warehouses,
                        selectedWarehouseId = uiState.selectedWarehouseId,
                        onSelect = onSelectWarehouse
                    )
                }
            }

            // Not gated on a selected warehouse: the stock fetch failing, the
            // *warehouses* fetch failing and a company with zero warehouses
            // all read as "no stock loaded" to the capping logic, so all of
            // them need the same warning and the same way out.
            if (!uiState.stockLoaded) {
                item(key = "stock-warning") {
                    StockCapWarningCard(onReload = onReloadWarehouseStock)
                }
            }

            if (chipMachines.isNotEmpty()) {
                item(key = "chip-row") {
                    PackChipRow(
                        chips = chipStates,
                        activeChip = activeChip,
                        onSelectChip = { id ->
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            onSelectChip(id)
                        }
                    )
                }
            }

            item(key = "header-strip") {
                PackHeaderStrip(
                    activeChip = activeChip,
                    activeMachineName = activeMachineName,
                    itemCount = chipItemCount(activeChip),
                    isFullyPacked = isActiveChipFullyPacked,
                    anyPacked = cards.any { card -> card.lines.any { it.line.ticked } }
                )
            }

            // The change notes: information only. Their goods are in the
            // cards below; only the spirals to take along are not.
            items(items = changeNotes, key = { "change-note-${it.machineId}" }) { note ->
                ChangeNoteCard(note = note, showMachineName = activeChip == null)
            }

            if (cards.isEmpty()) {
                if (changeNotes.isEmpty()) {
                    item(key = "empty") {
                        PackEmptyState(isMachineChip = activeChip != null)
                    }
                }
            } else {
                items(items = cards, key = { it.productId }) { card ->
                    PackProductCard(
                        card = card,
                        showMachineNames = activeChip == null,
                        enabled = !uiState.isSaving,
                        onToggle = { machineId ->
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            onToggleLine(machineId, card.productId)
                        },
                        onSetQuantity = { machineId, quantity ->
                            onSetLineQuantity(machineId, card.productId, quantity)
                        }
                    )
                }
            }
        }

        PackBottomBar(
            readyMachineCount = uiState.readyMachineCount,
            boxPacked = boxPacked,
            boxTotal = boxTotal,
            activeMachineName = activeMachineName,
            // Nothing on the list means nothing to pack.
            showPackAll = cards.any { card -> card.lines.any { !it.line.ticked && !it.line.isUnavailable } },
            canStart = uiState.machines.any { it.isPacked },
            isSaving = uiState.isSaving,
            onPackAll = {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                if (activeChip == null) onPackEverything() else onPackAllForMachine(activeChip)
            },
            onStartTour = {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                if (openLines.isEmpty()) onStartTour() else showOpenLines = true
            }
        )
    }

    if (showOpenLines) {
        OpenPackLinesDialog(
            lines = openLines,
            productNames = { productId -> productLabel(uiState, productId) },
            machineNames = uiState.machines.associate { it.machine.id to it.machine.displayName },
            onDismiss = { showOpenLines = false },
            onStartAnyway = {
                showOpenLines = false
                onStartTour()
            }
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Card state. Resolved once per recomposition in [PackingStep]'s body — which
// never skips, since it holds the (unstable) ui state — and handed to the
// leaf composables as plain values. Leaf composables must not read the
// ViewModel themselves: a skipped leaf would keep rendering a stale quantity.
// ─────────────────────────────────────────────────────────────────────────

/** One machine's line inside a product card. */
private data class PackLineState(
    val line: PackLine,
    val machineName: String
)

/** One product card: header plus one line per machine in scope. */
private data class PackCardState(
    val productId: String,
    val name: String?,
    val imagePath: String?,
    /** Units in the selected warehouse, `null` while stock isn't loaded. */
    val stockTotal: Int?,
    val lines: List<PackLineState>
) {
    val open: List<PackLine> get() = lines.map { it.line }.filter { !it.isUnavailable }
    val total: Int get() = lines.sumOf { it.line.total }
    val allTicked: Boolean get() = open.isNotEmpty() && open.all { it.ticked }
    val isShort: Boolean get() = open.any { it.ticked && it.shortfall > 0 }
}

/**
 * The product cards for the machines in scope, in warehouse walk order (else
 * by quantity): products refilled anyway and those only a rebuild needs alike.
 * Unavailable lines stay on a card (dimmed) so the driver sees what is missing.
 */
@Composable
private fun packCards(uiState: RefillUiState, activeChip: String?): List<PackCardState> {
    val scope = if (activeChip == null) uiState.machines.map { it.machine.id } else listOf(activeChip)
    val byProduct = LinkedHashMap<String, MutableList<PackLineState>>()
    for (machineId in scope) {
        val name = uiState.machines.find { it.machine.id == machineId }?.machine?.displayName.orEmpty()
        for (productId in uiState.lineProductIds(machineId)) {
            byProduct.getOrPut(productId) { mutableListOf() } += PackLineState(uiState.packLine(machineId, productId), name)
        }
    }
    val unknown = stringResource(R.string.refill_pack_unknown_product)
    val context = LocalContext.current
    val cards = byProduct.map { (productId, lines) ->
        // Machines refilling the product first, then those needing it only for a rebuild.
        val sorted = lines.sortedBy { if (it.line.refillNeed > 0) 0 else 1 }
        val info = productInfo(uiState, productId)
        PackCardState(
            productId = productId,
            name = info.first
                ?: unassignedSlot(uiState, sorted.map { it.line.machineId }, productId)
                    ?.let { context.getString(R.string.machine_card_unassigned_slot, it) }
                ?: unknown,
            imagePath = info.second,
            stockTotal = if (uiState.stockLoaded) (uiState.warehouseStock[productId] ?: 0) else null,
            lines = sorted
        )
    }
    // Scoped to one machine, a card the driver can do nothing with is dropped.
    val visible = if (activeChip == null) cards else cards.filter { it.open.isNotEmpty() }
    return SlotChange.sortForPacking(
        rows = visible,
        pickOrder = uiState.pickOrder,
        productId = { it.productId },
        name = { productInfo(uiState, it.productId).first },
        quantity = { card -> card.lines.sumOf { it.line.need } }
    )
}

/** Name and image of a product on the packing list (from its slots, or from a change note). */
private fun productInfo(uiState: RefillUiState, productId: String): Pair<String?, String?> {
    uiState.packingList.firstOrNull { it.productId == productId }?.let {
        return it.productName?.takeIf { name -> name.isNotBlank() } to it.imagePath
    }
    val item = uiState.machines.asSequence()
        .flatMap { it.acceptedChangeItems.asSequence() }
        .firstOrNull { it.toProductId == productId }
    return item?.toName to item?.toImagePath
}

@Composable
private fun productLabel(uiState: RefillUiState, productId: String): String =
    productInfo(uiState, productId).first ?: stringResource(R.string.refill_pack_unknown_product)

/** Slot number to name an unassigned product by. */
private fun unassignedSlot(uiState: RefillUiState, machineIds: List<String>, productId: String): Int? =
    machineIds.firstNotNullOfOrNull { id ->
        uiState.machines.firstOrNull { it.machine.id == id }
            ?.trays?.firstOrNull { it.tray.productId == productId }?.tray?.itemNumber
    }

// ─────────────────────────────────────────────────────────────────────────
// Warehouse picker + stock warning
// ─────────────────────────────────────────────────────────────────────────

/** Same idiom as the warehouse module's picker; rendered only for more than one warehouse. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WarehousePickerField(
    warehouses: List<Warehouse>,
    selectedWarehouseId: String?,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }
    val selected = warehouses.firstOrNull { it.id == selectedWarehouseId }

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = modifier.fillMaxWidth()
    ) {
        OutlinedTextField(
            value = selected?.name ?: selected?.id.orEmpty(),
            onValueChange = {},
            readOnly = true,
            label = { Text(stringResource(R.string.warehouse_picker_label)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor(MenuAnchorType.PrimaryNotEditable)
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            warehouses.forEach { warehouse ->
                DropdownMenuItem(
                    text = { Text(warehouse.name ?: warehouse.id) },
                    onClick = {
                        onSelect(warehouse.id)
                        expanded = false
                    }
                )
            }
        }
    }
}

/**
 * Warning + retry for "no warehouse stock loaded".
 *
 * A failed stock fetch — or a failed *warehouses* fetch, or a company with no
 * warehouse at all — leaves `warehouseStock` empty, and empty is
 * indistinguishable from "not loaded" for the capping logic: the caps lift
 * and the driver is told to pack more than the warehouse holds. The error
 * itself is transient (a snackbar) and `selectWarehouse` early-returns for
 * the already-selected id, so the picker can't retry — this banner is the
 * visible way back, and it stays up for as long as the state lasts.
 */
@Composable
private fun StockCapWarningCard(
    onReload: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = StockOrange.copy(alpha = 0.12f))
    ) {
        Row(
            modifier = Modifier.padding(start = 12.dp, top = 8.dp, end = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                // Decorative: the title beside it says the same thing.
                imageVector = Icons.Default.Warning,
                contentDescription = null,
                tint = StockOrange,
                modifier = Modifier.size(20.dp)
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.refill_pack_stock_unavailable_title),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = stringResource(R.string.refill_pack_stock_unavailable_body),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(modifier = Modifier.width(4.dp))
            TextButton(onClick = onReload) {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(4.dp))
                Text(
                    text = stringResource(R.string.refill_pack_stock_retry),
                    maxLines = 1
                )
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Chip bar + header strip
// ─────────────────────────────────────────────────────────────────────────

/** One chip's resolved label state. [machineId] `null` is the "All" chip. */
private data class ChipState(
    val machineId: String?,
    val name: String,
    /** Outstanding units for this chip, from `RefillViewModel.chipItemCount`. */
    val count: Int,
    val isFullyPacked: Boolean,
    /** The machine's tour health, shown as a dot; `null` for the "All" chip. */
    val tier: MachineStockTier? = null
)

/**
 * "All" plus one chip per machine with a need, each carrying its outstanding
 * count and a tick once fully packed.
 *
 * [FlowRow], not [Row]: four chips already overflowed a 360 dp screen in the
 * warehouse module, and German machine names are longer still.
 */
@Composable
private fun PackChipRow(
    chips: List<ChipState>,
    activeChip: String?,
    onSelectChip: (machineId: String?) -> Unit,
    modifier: Modifier = Modifier
) {
    FlowRow(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        chips.forEach { chip ->
            PackChip(
                name = chip.name,
                count = chip.count,
                isSelected = activeChip == chip.machineId,
                isFullyPacked = chip.isFullyPacked,
                tier = chip.tier,
                onClick = { onSelectChip(chip.machineId) }
            )
        }
    }
}

@Composable
private fun PackChip(
    name: String,
    count: Int,
    isSelected: Boolean,
    isFullyPacked: Boolean,
    tier: MachineStockTier?,
    onClick: () -> Unit
) {
    val tierColor: Color? = when (tier) {
        null -> null
        MachineStockTier.CRITICAL -> StockRed
        MachineStockTier.LOW -> StockOrange
        MachineStockTier.FILL -> if (isSystemInDarkTheme()) VMflowBlueLight else VMflowBlue
        MachineStockTier.OK -> StockGreen
    }
    FilterChip(
        selected = isSelected,
        onClick = onClick,
        label = {
            // Two Texts, not one formatted string: [FlowRow] constrains the
            // chip to the container width, so a single ellipsised Text eats
            // the count — the actionable number — on a long German machine
            // name at 360 dp. Only the name may shrink and ellipsise
            // (`fill = false` so a short name doesn't stretch the chip); the
            // count always survives. iOS keeps them as two Texts in an
            // HStack (`PackingStepView.swift:513-520`).
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = name,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false)
                )
                Spacer(modifier = Modifier.width(4.dp))
                Text(
                    text = stringResource(R.string.refill_pack_chip_count, count),
                    maxLines = 1
                )
            }
        },
        leadingIcon = if (isFullyPacked) {
            {
                Icon(
                    imageVector = Icons.Default.CheckCircle,
                    contentDescription = stringResource(R.string.refill_pack_status_complete),
                    tint = StockGreen,
                    modifier = Modifier.size(18.dp)
                )
            }
        } else if (tierColor != null) {
            {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(tierColor)
                )
            }
        } else {
            null
        }
    )
}

/** Status line for the active chip: what it holds and whether its box is done. */
@Composable
private fun PackHeaderStrip(
    activeChip: String?,
    activeMachineName: String?,
    itemCount: Int,
    isFullyPacked: Boolean,
    anyPacked: Boolean,
    modifier: Modifier = Modifier
) {
    val isPartial = !isFullyPacked && anyPacked
    // Fixed status tokens, not scheme roles: the brand palette's
    // primary/secondary/tertiary collapse into each other in dark mode.
    val accent: Color = when {
        isFullyPacked -> StockGreen
        isPartial -> StockOrange
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val statusLabel = stringResource(
        when {
            isFullyPacked -> R.string.refill_pack_status_complete
            isPartial -> R.string.refill_pack_status_partial
            else -> R.string.refill_pack_status_pending
        }
    )

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = accent.copy(alpha = 0.10f)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = when {
                    isFullyPacked -> Icons.Default.CheckCircle
                    isPartial -> Icons.Default.Warning
                    else -> Icons.Default.Inventory2
                },
                // Decorative: [statusLabel] is rendered as text below.
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(20.dp)
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = activeMachineName?.takeIf { activeChip != null }
                        ?: stringResource(R.string.refill_pack_header_all),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = statusLabel,
                    style = MaterialTheme.typography.bodySmall,
                    color = accent
                )
            }
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = pluralStringResource(R.plurals.refill_pack_items, itemCount, itemCount),
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = accent
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Product card + line
// ─────────────────────────────────────────────────────────────────────────

/**
 * One product: image, name, warehouse stock and — with several lines — the
 * total, then one line per machine. No tick of its own: a card is done when
 * every line is ticked.
 */
@Composable
private fun PackProductCard(
    card: PackCardState,
    showMachineNames: Boolean,
    enabled: Boolean,
    onToggle: (machineId: String) -> Unit,
    onSetQuantity: (machineId: String, quantity: Int) -> Unit,
    modifier: Modifier = Modifier
) {
    val unavailable = card.open.isEmpty()
    val borderColor: Color? = when {
        card.isShort -> StockOrange
        card.allTicked -> StockGreen
        else -> null
    }
    Card(
        modifier = modifier
            .fillMaxWidth()
            .alpha(if (unavailable) 0.5f else 1f),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
        border = borderColor?.let { BorderStroke(if (card.isShort) 2.dp else 1.5.dp, it.copy(alpha = 0.6f)) }
    ) {
        Column(modifier = Modifier.padding(vertical = 8.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                ProductImage(imagePath = card.imagePath, contentDescription = null, size = 44.dp)
                Spacer(modifier = Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = card.name.orEmpty(),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = if (unavailable) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface
                    )
                    card.stockTotal?.let { stock ->
                        Text(
                            text = if (stock <= 0) stringResource(R.string.refill_pack_stock_none)
                            else stringResource(R.string.refill_pack_stock_in, stock),
                            style = MaterialTheme.typography.labelSmall,
                            color = if (stock <= 0) StockRed else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                // The total only adds something with several lines.
                if (card.lines.size > 1) {
                    Spacer(modifier = Modifier.width(8.dp))
                    QuantityPill(text = stringResource(R.string.refill_pack_total_quantity, card.total), color = VMflowBlue)
                }
            }
            card.lines.forEach { state ->
                HorizontalDivider(modifier = Modifier.padding(start = 12.dp, top = 8.dp))
                PackLineRow(
                    line = state.line,
                    machineName = state.machineName.takeIf { showMachineNames },
                    enabled = enabled,
                    onToggle = { onToggle(state.line.machineId) },
                    onSetQuantity = { onSetQuantity(state.line.machineId, it) }
                )
            }
        }
    }
}

/**
 * One machine's line of a product: a big tick (everything of the line lies
 * in the box), what it is for — "3 refill + ⇄ 5 rebuild · slot 57" — and
 * one stepper for the whole amount. Packing less takes it off the refill
 * first; the rebuilt slots keep their goods as long as possible.
 */
@Composable
private fun PackLineRow(
    line: PackLine,
    machineName: String?,
    enabled: Boolean,
    onToggle: () -> Unit,
    onSetQuantity: (Int) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (line.isUnavailable) 0.6f else 1f)
            .padding(start = 4.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(
            modifier = Modifier
                .weight(1f)
                .clickable(enabled = enabled && !line.isUnavailable, onClick = onToggle)
                .defaultMinSize(minHeight = 48.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(modifier = Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = when {
                        line.isUnavailable -> Icons.Default.DisabledByDefault
                        line.ticked -> Icons.Default.CheckBox
                        else -> Icons.Default.CheckBoxOutlineBlank
                    },
                    contentDescription = stringResource(R.string.refill_pack_in_box_label),
                    tint = when {
                        line.isUnavailable -> StockRed.copy(alpha = 0.5f)
                        line.ticked -> StockGreen
                        else -> MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    modifier = Modifier.size(28.dp)
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                if (machineName != null) {
                    Text(text = machineName, style = MaterialTheme.typography.bodyMedium)
                }
                Text(text = lineReason(line), style = MaterialTheme.typography.labelMedium)
            }
        }
        QuantityStepper(
            quantity = line.total,
            maxQuantity = line.maxQuantity,
            enabled = enabled && !line.isUnavailable,
            machineName = machineName.orEmpty(),
            onSetQuantity = onSetQuantity
        )
    }
}

/** "3 refill + ⇄ 5 rebuild · slot 57 · 2 still missing". */
@Composable
private fun lineReason(line: PackLine): AnnotatedString {
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    val refill = stringResource(R.string.refill_pack_line_refill, line.refill)
    val noStock = stringResource(R.string.refill_pack_line_no_stock)
    val rebuild = stringResource(R.string.refill_pack_line_rebuild, line.rebuild)
    val slots = if (line.slots.size == 1) {
        stringResource(R.string.refill_pack_slot_one, line.slots.first().toString())
    } else {
        stringResource(R.string.refill_pack_slot_many, line.slots.joinToString(", "))
    }
    val missing = pluralStringResource(R.plurals.refill_pack_still_missing, line.shortfall, line.shortfall)
    return buildAnnotatedString {
        if (line.refillNeed > 0) {
            if (line.hasRefill) withStyle(SpanStyle(color = secondary)) { append(refill) }
            else withStyle(SpanStyle(color = StockRed)) { append(noStock) }
        }
        if (line.rebuildNeed > 0) {
            if (line.refillNeed > 0) withStyle(SpanStyle(color = secondary)) { append(" + ") }
            withStyle(SpanStyle(color = RebuildViolet, fontWeight = FontWeight.SemiBold)) {
                append("⇄ ")
                append(rebuild)
                append(" · ")
                append(slots)
            }
        }
        if (line.shortfall > 0 && !line.isUnavailable) {
            withStyle(SpanStyle(color = secondary)) { append(" · ") }
            withStyle(SpanStyle(color = StockOrange, fontWeight = FontWeight.SemiBold)) { append(missing) }
        }
    }
}

/**
 * −/value/+ stepper. The upper bound is [maxQuantity] — the ViewModel's
 * `maxPackingQuantity`, already capped by tray capacity and remaining
 * warehouse stock — so a row can never advertise more than the warehouse
 * holds. (The ViewModel clamps again on write; this only stops the driver
 * pressing a button that would do nothing.)
 */
@Composable
private fun QuantityStepper(
    quantity: Int,
    maxQuantity: Int,
    enabled: Boolean,
    machineName: String,
    onSetQuantity: (Int) -> Unit
) {
    val haptic = LocalHapticFeedback.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(
            onClick = {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                onSetQuantity(quantity - 1)
            },
            enabled = enabled && quantity > 0
        ) {
            Icon(
                imageVector = Icons.Default.Remove,
                contentDescription = stringResource(R.string.refill_pack_decrement, machineName)
            )
        }
        Box(
            modifier = Modifier
                .defaultMinSize(minWidth = 36.dp, minHeight = 32.dp)
                .background(
                    color = if (enabled) {
                        MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
                    } else {
                        MaterialTheme.colorScheme.surfaceVariant
                    },
                    shape = RoundedCornerShape(8.dp)
                ),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = quantity.toString(),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                color = if (enabled) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
                modifier = Modifier.padding(horizontal = 6.dp)
            )
        }
        IconButton(
            onClick = {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                onSetQuantity(quantity + 1)
            },
            enabled = enabled && quantity < maxQuantity
        ) {
            Icon(
                imageVector = Icons.Default.Add,
                contentDescription = stringResource(R.string.refill_pack_increment, machineName)
            )
        }
    }
}

@Composable
private fun QuantityPill(text: String, color: Color) {
    Surface(
        shape = RoundedCornerShape(percent = 50),
        color = color.copy(alpha = 0.12f)
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
            color = color,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Empty state + bottom bar
// ─────────────────────────────────────────────────────────────────────────

@Composable
private fun PackEmptyState(isMachineChip: Boolean, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            imageVector = Icons.Default.CheckCircle,
            contentDescription = null,
            tint = StockGreen,
            modifier = Modifier.size(48.dp)
        )
        Spacer(modifier = Modifier.height(12.dp))
        if (isMachineChip) {
            Text(
                text = stringResource(R.string.refill_pack_empty_machine),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        } else {
            Text(
                text = stringResource(R.string.refill_pack_empty_title),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = stringResource(R.string.refill_pack_empty_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
    }
}

/**
 * Pack-all for the active scope, then what is in the box and Start Tour.
 * Stacked rather than side-by-side: "Alles für <Automatenname> packen" does
 * not fit beside a second button at 360 dp.
 */
@Composable
private fun PackBottomBar(
    readyMachineCount: Int,
    boxPacked: Int,
    boxTotal: Int,
    activeMachineName: String?,
    showPackAll: Boolean,
    canStart: Boolean,
    isSaving: Boolean,
    onPackAll: () -> Unit,
    onStartTour: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.fillMaxWidth()) {
        HorizontalDivider()
        Column(modifier = Modifier.padding(16.dp)) {
            if (showPackAll) {
                OutlinedButton(
                    onClick = onPackAll,
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = 48.dp),
                    enabled = !isSaving
                ) {
                    Icon(
                        imageVector = Icons.Default.Inventory2,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = activeMachineName
                            ?.let { stringResource(R.string.refill_pack_pack_all_for, it) }
                            ?: stringResource(R.string.refill_pack_pack_all)
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = pluralStringResource(R.plurals.refill_pack_machines_ready, readyMachineCount, readyMachineCount),
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium
                    )
                    Text(
                        text = stringResource(R.string.refill_pack_in_box, boxPacked, boxTotal),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(modifier = Modifier.width(12.dp))
                Button(
                    onClick = onStartTour,
                    modifier = Modifier.defaultMinSize(minHeight = 48.dp),
                    enabled = canStart && !isSaving
                ) {
                    if (isSaving) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Default.LocalShipping,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp)
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = stringResource(R.string.refill_pack_start_tour),
                            maxLines = 1
                        )
                    }
                }
            }
        }
    }
}

/**
 * Tour start while lines are not ticked: what stays in the warehouse (not
 * booked). The driver goes back to packing or starts without it.
 */
@Composable
private fun OpenPackLinesDialog(
    lines: List<PackLine>,
    productNames: @Composable (productId: String) -> String,
    machineNames: Map<String, String>,
    onDismiss: () -> Unit,
    onStartAnyway: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(pluralStringResource(R.plurals.refill_pack_open_lines_title, lines.size, lines.size))
        },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                Text(
                    text = stringResource(R.string.refill_pack_open_lines_hint),
                    style = MaterialTheme.typography.bodyMedium
                )
                Spacer(modifier = Modifier.height(12.dp))
                lines.forEach { line ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = productNames(line.productId),
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.SemiBold
                            )
                            Text(
                                text = machineNames[line.machineId].orEmpty(),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            if (line.rebuild > 0) {
                                Text(
                                    text = "⇄ " + if (line.slots.size == 1) {
                                        stringResource(R.string.refill_pack_slot_one, line.slots.first().toString())
                                    } else {
                                        stringResource(R.string.refill_pack_slot_many, line.slots.joinToString(", "))
                                    },
                                    style = MaterialTheme.typography.bodySmall,
                                    fontWeight = FontWeight.SemiBold,
                                    color = RebuildViolet
                                )
                            }
                        }
                        Text(
                            text = line.total.toString(),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
                if (lines.any { it.rebuild > 0 }) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = stringResource(R.string.refill_pack_open_lines_rebuild_hint),
                        style = MaterialTheme.typography.bodySmall,
                        color = RebuildViolet
                    )
                }
            }
        },
        confirmButton = {
            Button(onClick = onDismiss) { Text(stringResource(R.string.refill_pack_keep_packing)) }
        },
        dismissButton = {
            TextButton(onClick = onStartAnyway) { Text(stringResource(R.string.refill_pack_start_without)) }
        }
    )
}
