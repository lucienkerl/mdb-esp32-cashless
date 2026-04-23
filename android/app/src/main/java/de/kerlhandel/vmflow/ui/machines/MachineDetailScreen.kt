package de.kerlhandel.vmflow.ui.machines

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.LibraryAdd
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.Sale
import de.kerlhandel.vmflow.data.model.Tray
import de.kerlhandel.vmflow.data.model.VendingMachine
import de.kerlhandel.vmflow.ui.common.ProductImage
import de.kerlhandel.vmflow.ui.common.StockBar
import de.kerlhandel.vmflow.ui.theme.BrandLime400
import de.kerlhandel.vmflow.ui.theme.BrandSlate800
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import de.kerlhandel.vmflow.ui.theme.VMGreen
import de.kerlhandel.vmflow.ui.theme.VMRed
import de.kerlhandel.vmflow.ui.theme.VMYellow
import de.kerlhandel.vmflow.ui.trays.BatchAddSheet
import de.kerlhandel.vmflow.ui.trays.TrayEditSheet
import de.kerlhandel.vmflow.util.DateFormatting
import de.kerlhandel.vmflow.util.WeekBoundaries

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MachineDetailScreen(
    machineId: String,
    onBack: () -> Unit,
    viewModel: MachineDetailViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { viewModel.load() }
    var selectedTab by remember { mutableIntStateOf(0) }

    var editingTray by remember { mutableStateOf<Tray?>(null) }
    var showAddSheet by remember { mutableStateOf(false) }
    var showBatchSheet by remember { mutableStateOf(false) }
    var fabMenuOpen by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            MachineDetailTopBar(
                machine = state.machine,
                traysCount = state.trays.size,
                onBack = onBack,
            )
        },
        floatingActionButton = {
            if (selectedTab == 1) {
                Box {
                    ExtendedFloatingActionButton(
                        onClick = { fabMenuOpen = true },
                        containerColor = BrandSlate900,
                        contentColor = BrandLime400,
                        elevation = FloatingActionButtonDefaults.elevation(defaultElevation = 3.dp),
                        icon = { Icon(Icons.Filled.Add, null, modifier = Modifier.size(18.dp)) },
                        text = {
                            Text(
                                stringResource(R.string.trays_add),
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.SemiBold,
                            )
                        },
                    )
                    DropdownMenu(
                        expanded = fabMenuOpen,
                        onDismissRequest = { fabMenuOpen = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.trays_add)) },
                            leadingIcon = { Icon(Icons.Filled.Add, null) },
                            onClick = { fabMenuOpen = false; showAddSheet = true },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.trays_batch_add)) },
                            leadingIcon = { Icon(Icons.Filled.LibraryAdd, null) },
                            onClick = { fabMenuOpen = false; showBatchSheet = true },
                        )
                    }
                }
            }
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        Column(Modifier.fillMaxSize().padding(inner)) {
            PrimaryTabRow(
                selectedTabIndex = selectedTab,
                containerColor = MaterialTheme.colorScheme.surface,
            ) {
                Tab(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    text = {
                        Text(
                            "Übersicht",
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                        )
                    },
                )
                Tab(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    text = {
                        Text(
                            "Fächer · ${state.trays.size}",
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                        )
                    },
                )
            }

            when {
                state.loading && state.trays.isEmpty() -> Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator(color = BrandSlate900) }

                selectedTab == 0 -> OverviewTab(state.trays, state.sales)
                else -> TraysTab(
                    trays = state.trays,
                    onAdjust = viewModel::adjustStock,
                    onFill = viewModel::fillTray,
                    onEdit = { editingTray = it },
                )
            }
        }
    }

    // ----- Sheets -----
    editingTray?.let { tray ->
        TrayEditSheet(
            tray = tray,
            machineId = machineId,
            products = state.products,
            onDismiss = { editingTray = null },
            onSave = { payload, id ->
                viewModel.saveTray(payload, id)
                editingTray = null
            },
            onDelete = { id ->
                viewModel.deleteTray(id)
                editingTray = null
            },
        )
    }

    if (showAddSheet) {
        TrayEditSheet(
            tray = null,
            machineId = machineId,
            products = state.products,
            onDismiss = { showAddSheet = false },
            onSave = { payload, _ ->
                viewModel.saveTray(payload, null)
                showAddSheet = false
            },
        )
    }

    if (showBatchSheet) {
        BatchAddSheet(
            machineId = machineId,
            onDismiss = { showBatchSheet = false },
            onConfirm = { start, count, cap ->
                viewModel.batchAddTrays(start, count, cap)
                showBatchSheet = false
            },
        )
    }
}

// =============================================================
//  Top App Bar — Title + Subtitle (Online-Status)
// =============================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MachineDetailTopBar(
    machine: VendingMachine?,
    traysCount: Int,
    onBack: () -> Unit,
) {
    TopAppBar(
        title = {
            Column {
                Text(
                    text = machine?.displayName ?: "—",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                machine?.let {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        val statusColor = if (it.isOnline) VMGreen else VMRed
                        Box(
                            modifier = Modifier
                                .size(7.dp)
                                .clip(CircleShape)
                                .background(statusColor),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = if (it.isOnline) stringResource(R.string.machines_online)
                            else stringResource(R.string.machines_offline),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        it.embeddeds?.subdomain?.let { subdomain ->
                            Text(
                                text = " · #$subdomain",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.cd_back),
                )
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = MaterialTheme.colorScheme.surface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            navigationIconContentColor = MaterialTheme.colorScheme.onSurface,
        ),
    )
}

// =============================================================
//  Overview Tab
// =============================================================

@Composable
private fun OverviewTab(trays: List<Tray>, sales: List<Sale>) {
    val totalCapacity = trays.sumOf { it.capacity }
    val totalStock = trays.sumOf { it.currentStock }
    val startOfToday = WeekBoundaries.startOfToday()
    val todaySales = sales.filter { it.createdAt >= startOfToday }
    val todayRevenue = todaySales.sumOf { it.itemPrice ?: 0.0 }
    val emptyCount = trays.count { it.isEmpty }
    val lowCount = trays.count { it.isBelowMinStock && !it.isEmpty }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            StockHealthCard(
                totalStock = totalStock,
                totalCapacity = totalCapacity,
                emptyCount = emptyCount,
                lowCount = lowCount,
            )
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SmallStatTile(
                    label = "Heute",
                    value = DateFormatting.formatCurrency(todayRevenue),
                    modifier = Modifier.weight(1f),
                )
                SmallStatTile(
                    label = "Verkäufe",
                    value = "${todaySales.size}",
                    modifier = Modifier.weight(1f),
                )
            }
        }
        item {
            SectionHeader(
                title = "Letzte Verkäufe",
                trailing = if (sales.isNotEmpty()) "${sales.size}" else null,
            )
        }
        if (sales.isEmpty()) {
            item { EmptySalesMessage() }
        } else {
            items(sales.take(12), key = { it.id }) { sale -> SaleRow(sale) }
        }
    }
}

@Composable
private fun StockHealthCard(
    totalStock: Int,
    totalCapacity: Int,
    emptyCount: Int,
    lowCount: Int,
) {
    val ratio = if (totalCapacity > 0) totalStock.toFloat() / totalCapacity else 1f
    val accent = when {
        ratio < 0.25f -> VMRed
        ratio < 0.5f -> VMYellow
        else -> VMGreen
    }
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "Bestand",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = "${(ratio * 100).toInt()}%",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = accent,
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                text = "$totalStock von $totalCapacity Artikeln",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.height(12.dp))
            StockBar(current = totalStock, capacity = totalCapacity.coerceAtLeast(1), showLabel = false)

            if (emptyCount > 0 || lowCount > 0) {
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (emptyCount > 0) AlertPill("$emptyCount leer", VMRed)
                    if (lowCount > 0) AlertPill("$lowCount niedrig", VMYellow)
                }
            }
        }
    }
}

@Composable
private fun AlertPill(label: String, color: Color) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = color,
        )
    }
}

@Composable
private fun SmallStatTile(label: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(2.dp))
        Text(
            text = value,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
        )
    }
}

@Composable
private fun SectionHeader(title: String, trailing: String? = null) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(top = 4.dp, start = 4.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.weight(1f),
        )
        trailing?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SaleRow(sale: Sale) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProductImage(sale.products?.imagePath, size = 36.dp)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = sale.products?.name ?: "Slot ${sale.itemNumber ?: 0}",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = DateFormatting.formatTimeHms(sale.createdAt),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            text = sale.formattedPrice(),
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Bold,
            color = BrandSlate900,
        )
    }
}

@Composable
private fun EmptySalesMessage() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = stringResource(R.string.dashboard_no_recent_sales),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// =============================================================
//  Trays Tab — Card per row, 2 logical lines
// =============================================================

@Composable
private fun TraysTab(
    trays: List<Tray>,
    onAdjust: (String, Int) -> Unit,
    onFill: (String) -> Unit,
    onEdit: (Tray) -> Unit,
) {
    if (trays.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                stringResource(R.string.trays_empty),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(trays, key = { it.id }) { tray ->
            TrayCard(
                tray = tray,
                onAdjust = onAdjust,
                onFill = onFill,
                onEdit = onEdit,
            )
        }
        item { Spacer(Modifier.height(72.dp)) } // FAB Spacer
    }
}

@Composable
private fun TrayCard(
    tray: Tray,
    onAdjust: (String, Int) -> Unit,
    onFill: (String) -> Unit,
    onEdit: (Tray) -> Unit,
) {
    val accent = when {
        tray.isEmpty -> VMRed
        tray.isBelowMinStock -> VMYellow
        else -> VMGreen
    }
    Card(
        onClick = { onEdit(tray) },
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            // Row 1: Slot badge + Product image + Name / price + Stepper
            Row(verticalAlignment = Alignment.CenterVertically) {
                SlotBadge(tray.itemNumber, accent)
                Spacer(Modifier.width(10.dp))
                ProductImage(tray.products?.imagePath, size = 40.dp)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        text = tray.productName,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    tray.formattedSellprice()?.let { price ->
                        Text(
                            text = price,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Spacer(Modifier.width(8.dp))
                InlineStepper(
                    value = tray.currentStock,
                    capacity = tray.capacity,
                    onDecrement = { onAdjust(tray.id, -1) },
                    onIncrement = { onAdjust(tray.id, +1) },
                )
            }

            Spacer(Modifier.height(10.dp))

            // Row 2: StockBar + optional fill-to-capacity quick action
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(modifier = Modifier.weight(1f)) {
                    StockBar(
                        current = tray.currentStock,
                        capacity = tray.capacity,
                        showLabel = false,
                        minStock = tray.minStock.takeIf { it > 0 },
                        fillWhenBelow = tray.fillWhenBelow.takeIf { it > 0 },
                    )
                }
                if (tray.currentStock < tray.capacity) {
                    Spacer(Modifier.width(8.dp))
                    FillQuickAction(onClick = { onFill(tray.id) })
                }
            }
        }
    }
}

/** Slot-number badge — monospaced, tabular feel. Brand-tinted when stock is healthy. */
@Composable
private fun SlotBadge(number: Int, accent: Color) {
    Box(
        modifier = Modifier
            .size(width = 44.dp, height = 40.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(BrandSlate900),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "$number",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = if (accent == VMGreen) BrandLime400 else accent,
        )
    }
}

/** Pill-shaped − [count] + stepper — compact, thumb-reachable. */
@Composable
private fun InlineStepper(
    value: Int,
    capacity: Int,
    onDecrement: () -> Unit,
    onIncrement: () -> Unit,
) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(MaterialTheme.colorScheme.surfaceContainerHighest),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StepperButton(
            icon = Icons.Filled.Remove,
            onClick = onDecrement,
            enabled = value > 0,
        )
        Text(
            text = "$value/$capacity",
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
            modifier = Modifier.defaultMinSize(minWidth = 48.dp),
        )
        StepperButton(
            icon = Icons.Filled.Add,
            onClick = onIncrement,
            enabled = value < capacity,
        )
    }
}

@Composable
private fun StepperButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
    enabled: Boolean,
) {
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.size(36.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = if (enabled) MaterialTheme.colorScheme.onSurface
            else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
        )
    }
}

@Composable
private fun FillQuickAction(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(BrandLime400.copy(alpha = 0.18f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.WaterDrop,
            contentDescription = "Auffüllen",
            modifier = Modifier.size(18.dp),
            tint = BrandSlate900,
        )
    }
}
