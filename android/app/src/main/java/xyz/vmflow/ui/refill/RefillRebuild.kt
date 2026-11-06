package xyz.vmflow.ui.refill

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import xyz.vmflow.R
import xyz.vmflow.data.LeftoverDestination
import xyz.vmflow.data.RebuildAction
import xyz.vmflow.data.RebuildSlot
import xyz.vmflow.data.SlotChange
import xyz.vmflow.data.SlotChangeItem
import xyz.vmflow.ui.components.ProductImage
import xyz.vmflow.ui.deals.formatEuro
import xyz.vmflow.ui.theme.RebuildViolet
import xyz.vmflow.ui.theme.StockGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed

/**
 * Slot re-assignment ("Fächer umbelegen") in the refill tour — the two
 * pieces of UI the change request adds:
 *
 *  - [ChangeNoteCard] on the pack step: the machine's change note. The
 *    refiller accepts (default) or declines each slot; accepted slots add
 *    their rebuild units to the van — as violet lines in the normal packing
 *    list, not in the note. Web `RefillChangeNote.vue`.
 *  - [RebuildSection] on the refill step: rebuild each accepted slot at the
 *    machine — count what comes out, fill the new product, set the price,
 *    mark it rebuilt or not. Nothing is booked until the machine is
 *    confirmed; what is left over rides in the van. Web `RefillRebuildSection.vue`.
 *  - [TourLeftoverCard] on the summary: the leftovers of every rebuild of
 *    the tour, counted and booked back at the warehouse in one go.
 *
 * Same contract as the steps: plain state in, callbacks out, no ViewModel.
 * Accent colour is [StockOrange] (the web uses amber) — a fixed token, never
 * a scheme role, for the same dark-mode reason as the rest of the wizard.
 */

/** One machine's change note on the pack step. */
data class ChangeNoteState(
    val machineId: String,
    val machineName: String,
    val items: List<SlotChangeItem>
)

/**
 * A machine's change note as one violet banner ("Rebuild 3 slots · 12, 14,
 * 23") plus the spirals to take along, the one thing not on the packing
 * list. It opens in place and is information only: every planned slot is
 * packed (its goods are ticked in the packing list like any other goods),
 * and a slot that can't be done is skipped at the machine. Web
 * `RefillChangeNote.vue`, iOS `ChangeNoteBanner`.
 */
@Composable
fun ChangeNoteCard(
    note: ChangeNoteState,
    showMachineName: Boolean,
    modifier: Modifier = Modifier
) {
    var expanded by remember(note.machineId) { mutableStateOf(false) }
    val items = note.items.sortedBy { it.itemNumber }
    val summary = pluralStringResource(R.plurals.refill_rebuild_count, items.size, items.size) +
        " · " + items.joinToString(", ") { it.itemNumber.toString() }
    val spiralCounts = items.filter { it.capacityChanges }
        .groupingBy { it.toCapacity }.eachCount().toSortedMap()
    val context = LocalContext.current
    val takeAlong = stringResource(R.string.refill_rebuild_take_along)
    val spirals = if (spiralCounts.isEmpty()) null else {
        takeAlong + " " + spiralCounts.entries.joinToString(", ") { (cap, count) ->
            context.getString(R.string.refill_rebuild_spiral_for, count, cap)
        }
    }
    Card(
        modifier = modifier.fillMaxWidth(),
        border = BorderStroke(1.5.dp, RebuildViolet.copy(alpha = 0.5f)),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(shape = CircleShape, color = RebuildViolet.copy(alpha = 0.15f), modifier = Modifier.size(40.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.SwapHoriz, contentDescription = null, tint = RebuildViolet, modifier = Modifier.size(20.dp))
                }
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                if (showMachineName) {
                    Text(
                        text = note.machineName,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Text(text = summary, style = MaterialTheme.typography.bodyMedium, color = RebuildViolet)
                if (spirals != null) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 2.dp)) {
                        Icon(Icons.Default.Inventory2, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(text = spirals, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            Icon(
                imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        if (expanded) {
            items.forEach { item ->
                HorizontalDivider()
                ChangeNoteItemRow(item)
            }
        }
    }
}

@Composable
private fun ChangeNoteItemRow(item: SlotChangeItem) {
    Row(modifier = Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.Top) {
        Surface(
            shape = RoundedCornerShape(8.dp),
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.9f),
            modifier = Modifier.size(40.dp)
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text(
                    text = item.itemNumber.toString(),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.surface
                )
            }
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (item.fromImagePath != null) {
                    ProductImage(imagePath = item.fromImagePath, contentDescription = null, size = 24.dp, modifier = Modifier.alpha(0.5f))
                    Spacer(modifier = Modifier.width(8.dp))
                }
                Text(
                    text = item.fromName ?: stringResource(R.string.refill_rebuild_empty_slot),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (item.toImagePath != null) {
                    ProductImage(imagePath = item.toImagePath, contentDescription = null, size = 24.dp)
                    Spacer(modifier = Modifier.width(8.dp))
                }
                Text(
                    text = item.toName ?: stringResource(R.string.refill_rebuild_empty_the_slot),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
            val toPrice = item.toPrice
            val showPrice = item.toProductId != null && item.hasPriceChange && toPrice != null
            if (item.capacityChanges || showPrice || item.ageChanged) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (item.capacityChanges) {
                        NoteTag(stringResource(R.string.refill_rebuild_spiral_tag, item.toCapacity), StockOrange)
                    }
                    if (showPrice && toPrice != null) NoteTag(formatEuro(toPrice), InfoBlue)
                    if (item.ageChanged) NoteTag(ageLabel(item.toMinAge), StockRed)
                }
            }
        }
    }
}

@Composable
private fun NoteTag(text: String, color: Color) {
    Surface(shape = RoundedCornerShape(6.dp), color = color.copy(alpha = 0.15f)) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = color,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
        )
    }
}

private val InfoBlue = Color(0xFF3B82F6)

// ─────────────────────────────────────────────────────────────────────────
// At the machine
// ─────────────────────────────────────────────────────────────────────────

/** Everything [RebuildSection] shows, resolved by the caller from `RefillUiState`. */
data class RebuildSectionState(
    val slots: List<RebuildSlot>,
    /**
     * Leftovers are booked back at the end of the tour, which needs a
     * warehouse; without one the "take it with you" hint is not shown.
     */
    val showReturnHint: Boolean,
    /** Units packed for the machine's rebuild, per product — caps what a slot can get. */
    val packed: Map<String, Int> = emptyMap(),
    /** The change note was withdrawn while the tour ran: nothing is rebuilt here. */
    val withdrawn: Boolean = false
)

/** [RebuildSection]'s callbacks, bundled so the refill step's signature stays readable. */
data class RebuildActions(
    val onRemoved: (itemId: String, value: Int) -> Unit,
    val onFilled: (itemId: String, value: Int) -> Unit,
    val onAction: (itemId: String, action: RebuildAction?) -> Unit,
    val onPriceSet: (itemId: String, value: Boolean) -> Unit,
    val onAgeSet: (itemId: String, value: Boolean) -> Unit
)

/**
 * At the machine: the slots of the change note as a short list, one row per
 * slot, ticked off like the goods when packing (iOS `RefillRebuildSection`,
 * web `RefillRebuildSection.vue`). A row shows the slot, the new product
 * instead of the old one, what to watch for (spiral, price, age) and the
 * units going in. One tap on the circle marks the slot done; a new price or
 * age limit is confirmed once on that tap. Tapping the row opens the amounts
 * and "Not possible today".
 */
@Composable
fun RebuildSection(
    state: RebuildSectionState,
    actions: RebuildActions,
    enabled: Boolean,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf<String?>(null) }
    var confirming by remember { mutableStateOf<String?>(null) }

    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (state.withdrawn) {
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = StockRed.copy(alpha = 0.10f),
                border = BorderStroke(1.dp, StockRed.copy(alpha = 0.4f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = stringResource(R.string.refill_rebuild_withdrawn_here),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = StockRed,
                    modifier = Modifier.padding(12.dp)
                )
            }
            return@Column
        }

        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 4.dp)) {
            Icon(
                imageVector = Icons.Default.SwapHoriz,
                contentDescription = null,
                tint = RebuildViolet,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = stringResource(R.string.refill_rebuild_at_machine_title),
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = RebuildViolet
            )
        }

        Card(
            modifier = Modifier.fillMaxWidth(),
            elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
        ) {
            state.slots.forEachIndexed { index, slot ->
                if (index > 0) HorizontalDivider()
                val id = slot.item.id
                RebuildSlotRow(
                    slot = slot,
                    expanded = expanded == id,
                    maxFilled = SlotChange.maxRebuildFilled(state.slots, id, state.packed),
                    skippedSources = SlotChange.skippedSourceSlots(state.slots, id),
                    actions = actions,
                    enabled = enabled,
                    onTick = {
                        when {
                            slot.action != null -> actions.onAction(id, null)
                            slot.needsConfirmation -> confirming = id
                            else -> actions.onAction(id, RebuildAction.DONE)
                        }
                    },
                    onToggleOpen = { expanded = if (expanded == id) null else id },
                    onSkip = {
                        actions.onAction(id, RebuildAction.SKIP)
                        expanded = null
                    }
                )
            }
        }

        if (state.showReturnHint && state.slots.all { it.action != null }) {
            Text(
                text = stringResource(R.string.refill_rebuild_take_along_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp)
            )
        }
    }

    // Price / age set on the machine? Asked once when ticking.
    val confirmSlot = state.slots.firstOrNull { it.item.id == confirming && it.action == null }
    if (confirmSlot != null) {
        val item = confirmSlot.item
        val toPrice = item.toPrice
        AlertDialog(
            onDismissRequest = { confirming = null },
            title = { Text(stringResource(R.string.refill_rebuild_slot_done, item.itemNumber)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (confirmSlot.needsPriceConfirmation && toPrice != null) {
                        Text(stringResource(R.string.refill_rebuild_price_set, item.itemNumber, formatEuro(toPrice)))
                    }
                    if (confirmSlot.needsAgeConfirmation) {
                        Text(stringResource(R.string.refill_rebuild_age_set) + ": " + ageChangeLabel(item))
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    if (confirmSlot.needsPriceConfirmation) actions.onPriceSet(item.id, true)
                    if (confirmSlot.needsAgeConfirmation) actions.onAgeSet(item.id, true)
                    actions.onAction(item.id, RebuildAction.DONE)
                    confirming = null
                }) { Text(stringResource(R.string.refill_rebuild_yes_set_on_machine)) }
            },
            dismissButton = {
                TextButton(onClick = { confirming = null }) { Text(stringResource(R.string.action_cancel)) }
            }
        )
    }
}

@Composable
private fun RebuildSlotRow(
    slot: RebuildSlot,
    expanded: Boolean,
    maxFilled: Int,
    skippedSources: List<Int>,
    actions: RebuildActions,
    enabled: Boolean,
    onTick: () -> Unit,
    onToggleOpen: () -> Unit,
    onSkip: () -> Unit
) {
    val item = slot.item
    val skipped = slot.action == RebuildAction.SKIP
    val done = slot.action == RebuildAction.DONE
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Column(modifier = Modifier.fillMaxWidth().alpha(if (skipped) 0.7f else 1f)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // The circle: open → done (price / age confirmed first), done or skipped → open again
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(48.dp)
                    .clickable(enabled = enabled, onClick = onTick)
            ) {
                Surface(
                    shape = CircleShape,
                    color = if (done) StockGreen else Color.Transparent,
                    border = if (done) null else BorderStroke(2.dp, muted.copy(alpha = 0.4f)),
                    modifier = Modifier.size(28.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        if (done) {
                            Icon(Icons.Default.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                        } else if (skipped) {
                            Icon(Icons.Default.Remove, contentDescription = null, tint = muted, modifier = Modifier.size(18.dp))
                        }
                    }
                }
            }

            Row(
                modifier = Modifier
                    .weight(1f)
                    .clickable(enabled = enabled, onClick = onToggleOpen)
                    .padding(vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = if (skipped) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.9f),
                    modifier = Modifier.size(36.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Text(
                            text = item.itemNumber.toString(),
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold,
                            color = if (skipped) muted else MaterialTheme.colorScheme.surface
                        )
                    }
                }
                Spacer(modifier = Modifier.width(10.dp))
                val image = if (skipped) item.fromImagePath else item.toImagePath
                if (image != null) {
                    ProductImage(imagePath = image, contentDescription = null, size = 40.dp)
                    Spacer(modifier = Modifier.width(10.dp))
                }
                Column(modifier = Modifier.weight(1f)) {
                    if (skipped) {
                        Text(
                            text = stringResource(R.string.refill_rebuild_stays, item.fromName ?: stringResource(R.string.refill_rebuild_empty_slot)),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = stringResource(R.string.refill_rebuild_comes_again),
                            style = MaterialTheme.typography.labelSmall,
                            color = muted
                        )
                    } else {
                        Text(
                            text = item.toName ?: stringResource(R.string.refill_rebuild_empty_the_slot),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = if (done) muted else MaterialTheme.colorScheme.onSurface,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                        if (item.fromProductId != null) {
                            Text(
                                text = stringResource(R.string.refill_rebuild_instead, item.fromName ?: ""),
                                style = MaterialTheme.typography.labelSmall,
                                color = muted,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        val toPrice = item.toPrice
                        val showPrice = item.toProductId != null && item.hasPriceChange && toPrice != null
                        if (item.capacityChanges || showPrice || item.ageChanged) {
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 2.dp)) {
                                if (item.capacityChanges) {
                                    NoteTag(stringResource(R.string.refill_rebuild_spiral_tag, item.toCapacity), StockOrange)
                                }
                                if (showPrice && toPrice != null) NoteTag(formatEuro(toPrice), InfoBlue)
                                if (item.ageChanged) NoteTag(ageLabel(item.toMinAge), StockRed)
                            }
                        }
                    }
                }
                if (!skipped && item.toProductId != null) {
                    Spacer(modifier = Modifier.width(6.dp))
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = RebuildViolet.copy(alpha = if (expanded) 0.25f else 0.10f),
                        modifier = Modifier.defaultMinSize(minWidth = 48.dp, minHeight = 40.dp)
                    ) {
                        Box(contentAlignment = Alignment.Center, modifier = Modifier.padding(horizontal = 6.dp)) {
                            Text(
                                text = "+${slot.filled}",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = RebuildViolet
                            )
                        }
                    }
                    Spacer(modifier = Modifier.width(4.dp))
                }
            }
        }

        // Amounts and "not possible today"
        if (expanded) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(start = 52.dp, end = 12.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (!skipped) {
                    if (item.fromProductId != null) {
                        NumberStepperField(
                            label = stringResource(R.string.refill_rebuild_take_out, item.fromName ?: ""),
                            value = slot.removed,
                            max = null,
                            enabled = enabled,
                            onValue = { actions.onRemoved(item.id, it) }
                        )
                    }
                    if (item.toProductId != null) {
                        NumberStepperField(
                            label = stringResource(R.string.refill_rebuild_put_in, item.toName ?: ""),
                            value = slot.filled,
                            max = maxFilled,
                            enabled = enabled,
                            onValue = { actions.onFilled(item.id, it) }
                        )
                        Text(
                            text = stringResource(R.string.refill_rebuild_fill_source, slot.moved, slot.fromVan),
                            style = MaterialTheme.typography.labelSmall,
                            color = muted
                        )
                    }
                    if (skippedSources.isNotEmpty() && slot.filled < item.toCapacity) {
                        Text(
                            text = if (skippedSources.size == 1) {
                                stringResource(R.string.refill_rebuild_skipped_source_one, skippedSources.first())
                            } else {
                                stringResource(R.string.refill_rebuild_skipped_source_many, skippedSources.joinToString(", "))
                            },
                            style = MaterialTheme.typography.labelSmall,
                            color = StockOrange
                        )
                    }
                    OutlinedButton(
                        onClick = onSkip,
                        enabled = enabled,
                        modifier = Modifier.fillMaxWidth().defaultMinSize(minHeight = 48.dp)
                    ) {
                        Text(stringResource(R.string.refill_rebuild_not_possible_today), color = muted)
                    }
                } else {
                    OutlinedButton(
                        onClick = { actions.onAction(item.id, null) },
                        enabled = enabled,
                        modifier = Modifier.fillMaxWidth().defaultMinSize(minHeight = 48.dp)
                    ) {
                        Text(stringResource(R.string.refill_rebuild_rebuild_after_all))
                    }
                }
            }
        }
    }
}

/** One age restriction as shown to the refiller: "ab 18" / "18+", or "ohne Altersgrenze". */
@Composable
private fun ageLabel(minAge: Int?): String =
    if (minAge == null) stringResource(R.string.refill_rebuild_age_none)
    else stringResource(R.string.refill_rebuild_age_min, minAge)

/** The age change of a slot spelled out, e.g. "ohne Altersgrenze → ab 18". */
@Composable
private fun ageChangeLabel(item: SlotChangeItem): String =
    "${ageLabel(item.fromMinAge)} → ${ageLabel(item.toMinAge)}"

/**
 * −/field/+ for a count. The field takes typed numbers (a spiral of 14 is
 * a lot of taps); the buttons are for the usual ±1 correction. [max] `null`
 * means unbounded — "removed" is whatever physically came out.
 */
@Composable
internal fun NumberStepperField(
    label: String,
    value: Int,
    max: Int?,
    enabled: Boolean,
    onValue: (Int) -> Unit
) {
    // Re-seeded whenever the ViewModel's value changes (including a clamp),
    // so the field never shows a number the state doesn't hold for long.
    var text by remember(value) { mutableStateOf(value.toString()) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        FilledTonalIconButton(
            onClick = { onValue((value - 1).coerceAtLeast(0)) },
            enabled = enabled && value > 0,
            modifier = Modifier.size(48.dp)
        ) {
            Icon(Icons.Default.Remove, contentDescription = null)
        }
        Spacer(modifier = Modifier.width(8.dp))
        OutlinedTextField(
            value = text,
            onValueChange = { input ->
                val digits = input.filter { it.isDigit() }.take(4)
                text = digits
                digits.toIntOrNull()?.let(onValue)
            },
            label = { Text(label, maxLines = 1) },
            singleLine = true,
            enabled = enabled,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.weight(1f)
        )
        Spacer(modifier = Modifier.width(8.dp))
        FilledTonalIconButton(
            onClick = { onValue(value + 1) },
            enabled = enabled && (max == null || value < max),
            modifier = Modifier.size(48.dp)
        ) {
            Icon(Icons.Default.Add, contentDescription = null)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// End of the tour, back at the warehouse
// ─────────────────────────────────────────────────────────────────────────

/** One product of the summary's leftover card, with the refiller's current edits applied. */
data class TourLeftoverRow(
    val productId: String,
    val name: String?,
    val imagePath: String?,
    /** Unused (van) units — the computed default until the refiller changes it. */
    val van: Int,
    /** Units taken out of machines — likewise. */
    val machine: Int,
    val destination: LeftoverDestination,
    /** Best-before date for the machine units, `null` = none. */
    val expiry: String?
)

/** [TourLeftoverCard]'s callbacks. */
data class TourLeftoverActions(
    val onVan: (productId: String, value: Int) -> Unit,
    val onMachine: (productId: String, value: Int) -> Unit,
    val onDestination: (productId: String, destination: LeftoverDestination) -> Unit,
    val onExpiry: (productId: String, date: String?) -> Unit,
    val onReturn: () -> Unit
)

/**
 * "Leftover goods from rebuilds" — everything the tour's slot rebuilds left
 * in the van, per product across all machines. Shown on the summary, when
 * the refiller is back at the warehouse and can count what is really there:
 * both quantities are editable, then one "Book back" books everything
 * (`return_slot_change_leftovers`). Once booked only the confirmation stays.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TourLeftoverCard(
    rows: List<TourLeftoverRow>,
    returned: Boolean,
    isReturning: Boolean,
    error: String?,
    actions: TourLeftoverActions,
    modifier: Modifier = Modifier
) {
    val enabled = !returned && !isReturning
    Card(
        modifier = modifier.fillMaxWidth(),
        border = BorderStroke(1.5.dp, (if (returned) StockGreen else StockOrange).copy(alpha = 0.6f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = if (returned) Icons.Default.Check else Icons.Default.SwapHoriz,
                    contentDescription = null,
                    tint = if (returned) StockGreen else StockOrange,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = stringResource(
                        if (returned) R.string.refill_leftover_booked else R.string.refill_leftover_title
                    ),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
            }
            if (returned) return@Column

            Text(
                text = stringResource(R.string.refill_leftover_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            rows.forEachIndexed { index, row ->
                if (index > 0) HorizontalDivider(modifier = Modifier.padding(vertical = 10.dp)) else Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ProductImage(imagePath = row.imagePath, contentDescription = null, size = 32.dp)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = row.name ?: stringResource(R.string.refill_pack_unknown_product),
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))
                NumberStepperField(
                    label = stringResource(R.string.refill_leftover_van),
                    value = row.van,
                    max = null,
                    enabled = enabled,
                    onValue = { actions.onVan(row.productId, it) }
                )
                Spacer(modifier = Modifier.height(6.dp))
                NumberStepperField(
                    label = stringResource(R.string.refill_leftover_machine),
                    value = row.machine,
                    max = null,
                    enabled = enabled,
                    onValue = { actions.onMachine(row.productId, it) }
                )
                Spacer(modifier = Modifier.height(8.dp))
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    SegmentedButton(
                        selected = row.destination == LeftoverDestination.WAREHOUSE,
                        onClick = { actions.onDestination(row.productId, LeftoverDestination.WAREHOUSE) },
                        enabled = enabled,
                        shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2)
                    ) {
                        Text(stringResource(R.string.refill_rebuild_to_warehouse), maxLines = 1)
                    }
                    SegmentedButton(
                        selected = row.destination == LeftoverDestination.WASTE,
                        onClick = { actions.onDestination(row.productId, LeftoverDestination.WASTE) },
                        enabled = enabled,
                        shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
                        colors = SegmentedButtonDefaults.colors(
                            activeContainerColor = StockRed.copy(alpha = 0.15f),
                            activeContentColor = StockRed
                        )
                    ) {
                        Text(stringResource(R.string.refill_rebuild_write_off), maxLines = 1)
                    }
                }
                if (row.destination == LeftoverDestination.WAREHOUSE) {
                    if (row.machine > 0) {
                        Spacer(modifier = Modifier.height(6.dp))
                        BestBeforeField(
                            dateIso = row.expiry,
                            enabled = enabled,
                            onChange = { actions.onExpiry(row.productId, it) }
                        )
                    }
                    val hints = buildList {
                        if (row.van > 0) add(stringResource(R.string.refill_rebuild_van_back_hint))
                        if (row.machine > 0) add(stringResource(R.string.refill_rebuild_machine_back_hint))
                    }
                    if (hints.isNotEmpty()) {
                        Text(
                            text = hints.joinToString(" "),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 4.dp)
                        )
                    }
                }
            }

            if (error != null) {
                Spacer(modifier = Modifier.height(10.dp))
                Text(
                    text = stringResource(
                        R.string.refill_leftover_error,
                        error.ifBlank { stringResource(R.string.refill_error_unknown) }
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = StockRed
                )
            }
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = actions.onReturn,
                enabled = enabled,
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = 48.dp)
            ) {
                if (isReturning) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(R.string.refill_leftover_book))
                }
            }
        }
    }
}

/**
 * Best-before date of goods taken out of a machine, pre-filled from the
 * batch of the last refill of that product into the machine. No lower
 * bound, unlike the warehouse intake's: goods coming *out* of a machine can
 * be past their date, and the record should say so.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BestBeforeField(dateIso: String?, enabled: Boolean, onChange: (String?) -> Unit) {
    var showDialog by remember { mutableStateOf(false) }
    val label = stringResource(R.string.refill_rebuild_best_before)
    OutlinedButton(
        onClick = { showDialog = true },
        enabled = enabled,
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = 48.dp)
    ) {
        Icon(Icons.Default.CalendarMonth, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = "$label: " + (dateIso?.let { formatBestBefore(it) } ?: stringResource(R.string.refill_rebuild_best_before_unset)),
            maxLines = 1
        )
    }

    if (showDialog) {
        val zone = ZoneOffset.UTC
        val initialMillis = remember(dateIso) {
            dateIso?.let { runCatching { LocalDate.parse(it).atStartOfDay(zone).toInstant().toEpochMilli() }.getOrNull() }
        }
        val pickerState = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
        DatePickerDialog(
            onDismissRequest = { showDialog = false },
            confirmButton = {
                TextButton(onClick = {
                    pickerState.selectedDateMillis?.let { millis ->
                        onChange(Instant.ofEpochMilli(millis).atZone(zone).toLocalDate().toString())
                    }
                    showDialog = false
                }) {
                    Text(stringResource(R.string.action_done))
                }
            },
            dismissButton = {
                TextButton(onClick = {
                    onChange(null)
                    showDialog = false
                }) {
                    Text(stringResource(R.string.refill_rebuild_best_before_clear))
                }
            }
        ) {
            DatePicker(state = pickerState)
        }
    }
}

private fun formatBestBefore(dateIso: String): String =
    try {
        LocalDate.parse(dateIso).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault()))
    } catch (_: Exception) {
        dateIso
    }
