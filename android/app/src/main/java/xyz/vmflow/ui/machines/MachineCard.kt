package xyz.vmflow.ui.machines

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import xyz.vmflow.R
import xyz.vmflow.data.connectivity
import xyz.vmflow.models.MachineWithStats
import xyz.vmflow.models.StockSeverity
import xyz.vmflow.models.TrayDeficit
import xyz.vmflow.models.WarehouseAvailability
import xyz.vmflow.ui.components.ProductImage
import xyz.vmflow.ui.components.ConnectivityTimeLine
import xyz.vmflow.ui.components.StatusChip
import xyz.vmflow.ui.components.rememberNow
import xyz.vmflow.ui.components.StockHealthBar
import xyz.vmflow.ui.theme.StockGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed
import xyz.vmflow.ui.theme.VMflowBlue
import xyz.vmflow.ui.theme.VMflowBlueLight
import java.text.NumberFormat
import java.util.Locale

@Composable
fun MachineCard(
    machineStats: MachineWithStats,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val currencyFormat = NumberFormat.getCurrencyInstance(Locale.GERMANY).apply {
        currency = java.util.Currency.getInstance("EUR")
    }
    val now by rememberNow()
    val connectivity = machineStats.machine.connectivity(now)

    Card(
        onClick = onClick,
        modifier = modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            // Top row: Name + Status
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = machineStats.machine.displayName,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Spacer(modifier = Modifier.width(8.dp))
                StatusChip(connectivity = connectivity)
            }
            ConnectivityTimeLine(
                connectivity = connectivity,
                now = now,
                modifier = Modifier.padding(top = 4.dp)
            )

            Spacer(modifier = Modifier.height(12.dp))

            // Revenue row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    Text(
                        text = stringResource(R.string.machine_revenue_today),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = currencyFormat.format(machineStats.todayRevenue),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                Column {
                    Text(
                        text = stringResource(R.string.machine_card_sales),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = "${machineStats.todaySalesCount}",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                Column {
                    Text(
                        text = stringResource(R.string.machine_revenue_yesterday),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = currencyFormat.format(machineStats.yesterdayRevenue),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Stock section, laid out like the PWA machine card
            // (`pages/machines/index.vue`). Every count is a PRODUCT, judged on
            // the sums over all its slots (StockHealth.groupTraysByProduct).
            // Only products the warehouse can refill count as Empty / Low /
            // Top off and drive the colour; the rest are "swap" (sold out) or
            // "no warehouse stock".
            val stock = machineStats.productStock
            val health = machineStats.stockHealth
            val hasNoStockIssues = machineStats.swapNeededCount > 0 || machineStats.noStockCount > 0
            val totalSlots = machineStats.trays.size

            if (health == MachineWithStats.StockHealth.OK && !hasNoStockIssues) {
                Text(
                    text = if (totalSlots > 0) {
                        pluralStringResource(R.plurals.machine_card_all_stocked, totalSlots, totalSlots)
                    } else {
                        stringResource(R.string.machine_card_no_trays)
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                // Hint only, never a health input: slots that are empty while their
                // product is still stocked in another slot of this machine.
                if (stock.emptySlotsWithStock > 0) {
                    Text(
                        text = pluralStringResource(
                            R.plurals.machine_card_empty_slots_with_stock,
                            stock.emptySlotsWithStock,
                            stock.emptySlotsWithStock
                        ),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))
            } else {
                // "All stocked" context when only no-warehouse-stock issues remain.
                if (health == MachineWithStats.StockHealth.OK) {
                    Text(
                        text = pluralStringResource(R.plurals.machine_card_all_stocked, totalSlots, totalSlots),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(6.dp))
                }

                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    if (stock.refillableEmpty > 0) {
                        SummaryBadge(
                            text = stringResource(R.string.machine_card_badge_empty, stock.refillableEmpty),
                            color = StockRed
                        )
                    }
                    if (stock.refillableLow > 0) {
                        SummaryBadge(
                            text = stringResource(R.string.machine_card_badge_low, stock.refillableLow),
                            color = StockOrange
                        )
                    }
                    if (machineStats.swapNeededCount > 0) {
                        SummaryBadge(
                            text = stringResource(R.string.machine_card_badge_swap, machineStats.swapNeededCount),
                            color = StockOrange
                        )
                    }
                    if (machineStats.noStockCount > 0) {
                        SummaryBadge(
                            text = stringResource(R.string.machine_card_badge_no_stock, machineStats.noStockCount),
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    if (stock.refillableFill > 0) {
                        SummaryBadge(
                            text = stringResource(R.string.machine_card_badge_topoff, stock.refillableFill),
                            color = fillColor()
                        )
                    }
                    if (stock.emptySlotsWithStock > 0) {
                        SummaryBadge(
                            text = pluralStringResource(
                                R.plurals.machine_card_empty_slots_with_stock,
                                stock.emptySlotsWithStock,
                                stock.emptySlotsWithStock
                            ),
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                Spacer(modifier = Modifier.height(8.dp))

                if (machineStats.trayDeficits.isNotEmpty()) {
                    DeficitRowsSection(machineStats.trayDeficits)
                    Spacer(modifier = Modifier.height(8.dp))
                }

                // Stock bar only while refillable products need attention (PWA).
                if (health != MachineWithStats.StockHealth.OK) {
                    StockHealthBar(trays = machineStats.trays)
                    Spacer(modifier = Modifier.height(8.dp))
                }
            }

            // Last sale + pax
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                machineStats.lastSaleAt?.let { dateStr ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.Schedule,
                            contentDescription = null,
                            modifier = Modifier.height(14.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = relativeTimeAgo(dateStr),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                if (machineStats.paxCount > 0) {
                    Text(
                        text = pluralStringResource(R.plurals.machine_card_visitors, machineStats.paxCount, machineStats.paxCount),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

/** Top-off tier colour — the PWA's blue, lighter in dark mode. */
@Composable
private fun fillColor(): Color = if (isSystemInDarkTheme()) VMflowBlueLight else VMflowBlue

/** Capsule badge used by the summary row above the deficit list ("N Empty", "N Swap", …). */
@Composable
private fun SummaryBadge(text: String, color: Color) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.12f))
            .padding(horizontal = 8.dp, vertical = 4.dp)
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = color
        )
    }
}

/** First four rows always visible; the rest expand/collapse behind a "+N more" toggle. */
@Composable
private fun DeficitRowsSection(deficits: List<TrayDeficit>) {
    var expanded by remember { mutableStateOf(false) }
    val visible = if (expanded) deficits else deficits.take(4)
    val remaining = deficits.size - 4

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        visible.forEach { deficit -> DeficitRow(deficit) }
        if (remaining > 0) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (expanded) {
                        stringResource(R.string.machine_card_deficit_show_less)
                    } else {
                        stringResource(R.string.machine_card_deficit_show_more, remaining)
                    },
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.width(4.dp))
                Icon(
                    imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.height(14.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun DeficitRow(deficit: TrayDeficit) {
    val isSwap = deficit.warehouseAvailability == WarehouseAvailability.NEEDS_SWAP
    val isNoStock = deficit.warehouseAvailability == WarehouseAvailability.NO_STOCK
    val textColor = when {
        isSwap -> StockOrange
        isNoStock -> MaterialTheme.colorScheme.onSurfaceVariant
        else -> when (deficit.severity) {
            StockSeverity.CRITICAL -> StockRed
            StockSeverity.LOW -> StockOrange
            StockSeverity.FILL_BELOW -> fillColor()
        }
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (isNoStock) 0.5f else 1f),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ProductImage(
            imagePath = deficit.imagePath,
            contentDescription = deficit.productName,
            size = 20.dp
        )
        Spacer(modifier = Modifier.width(6.dp))
        Text(
            text = deficit.productName,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
            color = textColor,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false)
        )
        Spacer(modifier = Modifier.width(4.dp))
        Text(
            text = stringResource(R.string.machine_card_deficit_amount, deficit.deficit),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (deficit.isDiscontinued) {
            Spacer(modifier = Modifier.width(4.dp))
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(3.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(horizontal = 4.dp, vertical = 1.dp)
            ) {
                Text(
                    text = stringResource(R.string.machine_card_deficit_discontinued),
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        Spacer(modifier = Modifier.weight(1f))
        when (deficit.warehouseAvailability) {
            WarehouseAvailability.IN_STOCK -> Text(
                text = stringResource(R.string.machine_card_deficit_in_stock),
                style = MaterialTheme.typography.labelSmall,
                color = StockGreen
            )
            WarehouseAvailability.NEEDS_SWAP -> Text(
                text = stringResource(R.string.machine_card_deficit_needs_swap),
                style = MaterialTheme.typography.labelSmall,
                color = StockOrange
            )
            WarehouseAvailability.NO_STOCK -> Text(
                text = stringResource(R.string.machine_card_deficit_no_stock),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            WarehouseAvailability.UNKNOWN -> Unit
        }
    }
}
