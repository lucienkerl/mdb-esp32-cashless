package de.kerlhandel.vmflow.ui.machines

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.MachineStats
import de.kerlhandel.vmflow.data.model.StockSeverity
import de.kerlhandel.vmflow.data.model.TrayDeficit
import de.kerlhandel.vmflow.data.model.WarehouseAvailability
import de.kerlhandel.vmflow.ui.common.ProductImage
import de.kerlhandel.vmflow.ui.common.StatusChip
import de.kerlhandel.vmflow.ui.common.StockBar
import de.kerlhandel.vmflow.ui.common.VMflowTopAppBar
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import de.kerlhandel.vmflow.ui.theme.VMGreen
import de.kerlhandel.vmflow.ui.theme.VMOrange
import de.kerlhandel.vmflow.ui.theme.VMRed
import de.kerlhandel.vmflow.ui.theme.VMYellow
import de.kerlhandel.vmflow.util.DateFormatting

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MachineListScreen(
    onOpenDetail: (String) -> Unit,
    viewModel: MachineListViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { viewModel.load() }
    val pullState = rememberPullToRefreshState()

    Scaffold(
        topBar = {
            Column {
                VMflowTopAppBar(title = stringResource(R.string.nav_machines))
                SearchField(
                    value = state.search,
                    onValueChange = viewModel::setSearch,
                    placeholder = stringResource(R.string.machines_search),
                )
            }
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        PullToRefreshBox(
            state = pullState,
            isRefreshing = state.loading,
            onRefresh = { viewModel.load() },
            modifier = Modifier.fillMaxSize().padding(inner),
        ) {
            when {
                state.loading && state.machines.isEmpty() -> Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator(color = BrandSlate900) }

                state.filtered.isEmpty() && !state.loading -> EmptyState()
                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(state.filtered, key = { it.id }) { stats ->
                        MachineCard(stats = stats, onClick = { onOpenDetail(stats.id) })
                    }
                }
            }
        }
    }
}

// -------- Search field --------

@Composable
private fun SearchField(value: String, onValueChange: (String) -> Unit, placeholder: String) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text(placeholder) },
        leadingIcon = {
            Icon(
                Icons.Filled.Search,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        singleLine = true,
        shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
            focusedTextColor = MaterialTheme.colorScheme.onSurface,
            unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
private fun EmptyState() {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Filled.Storefront,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            stringResource(R.string.machines_empty_title),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(R.string.machines_empty_body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// -------- Machine card --------

@Composable
private fun MachineCard(stats: MachineStats, onClick: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stats.machine.displayName,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                StatusChip(stats.machine.isOnline)
            }

            Spacer(Modifier.height(12.dp))

            StockBar(
                current = (stats.stockPercent * 100).toInt().coerceIn(0, 100),
                capacity = 100,
                showLabel = false,
            )

            Spacer(Modifier.height(10.dp))
            BadgeRow(stats)

            Spacer(Modifier.height(14.dp))
            SalesGrid(stats)

            if (stats.trayDeficits.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                stats.trayDeficits.take(5).forEach { DeficitRow(it) }
                if (stats.trayDeficits.size > 5) {
                    Text(
                        "+${stats.trayDeficits.size - 5} more",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }

            stats.paxcounterCount?.let { pax ->
                Spacer(Modifier.height(10.dp))
                PaxChip(pax)
            }
        }
    }
}

@Composable
private fun BadgeRow(stats: MachineStats) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (stats.emptyTrays > 0) Pill(stringResource(R.string.machines_empty_count, stats.emptyTrays), VMRed)
        if (stats.lowTrays > 0) Pill(stringResource(R.string.machines_low_count, stats.lowTrays), VMYellow)
        if (stats.swapNeededCount > 0) Pill(stringResource(R.string.machines_swap_count, stats.swapNeededCount), VMOrange)
        if (stats.noStockCount > 0) Pill(
            stringResource(R.string.machines_no_stock_count, stats.noStockCount),
            MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Pill(label: String, color: Color) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.12f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = color,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun PaxChip(count: Int) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(MaterialTheme.colorScheme.surfaceContainerHighest)
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Text(
            "👣  $count",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun SalesGrid(stats: MachineStats) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SalesCell(
                label = stringResource(R.string.machines_today),
                revenue = stats.todayRevenue,
                count = stats.todaySalesCount,
                modifier = Modifier.weight(1f),
            )
            SalesCell(
                label = stringResource(R.string.machines_yesterday),
                revenue = stats.yesterdayRevenue,
                count = stats.yesterdaySalesCount,
                modifier = Modifier.weight(1f),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SalesCell(
                label = stringResource(R.string.machines_this_week),
                revenue = stats.thisWeekRevenue,
                count = stats.thisWeekSalesCount,
                modifier = Modifier.weight(1f),
            )
            SalesCell(
                label = stringResource(R.string.machines_last_week),
                revenue = stats.lastWeekRevenue,
                count = stats.lastWeekSalesCount,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun SalesCell(label: String, revenue: Double, count: Int, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Column {
            Text(
                label,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                DateFormatting.formatCurrency(revenue),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                "$count",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun DeficitRow(deficit: TrayDeficit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProductImage(deficit.imagePath, size = 36.dp)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    deficit.productName,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                if (deficit.isDiscontinued) {
                    Spacer(Modifier.width(6.dp))
                    Pill(
                        stringResource(R.string.machines_discontinued),
                        MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "-${deficit.deficit}",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = severityColor(deficit.severity),
                )
                val avail = availabilityPair(deficit.warehouseAvailability)
                if (avail != null) {
                    Spacer(Modifier.width(8.dp))
                    Text(
                        avail.first,
                        style = MaterialTheme.typography.labelSmall,
                        color = avail.second,
                    )
                }
            }
        }
    }
}

@Composable
private fun availabilityPair(avail: WarehouseAvailability): Pair<String, Color>? = when (avail) {
    WarehouseAvailability.InStock -> stringResource(R.string.machines_in_stock) to VMGreen
    WarehouseAvailability.NeedsSwap -> stringResource(R.string.machines_swap) to VMOrange
    WarehouseAvailability.NoStock -> stringResource(R.string.machines_no_stock) to MaterialTheme.colorScheme.onSurfaceVariant
    WarehouseAvailability.Unknown -> null
}

@Composable
private fun severityColor(sev: StockSeverity) = when (sev) {
    StockSeverity.Critical -> VMRed
    StockSeverity.Low -> VMYellow
    StockSeverity.FillBelow -> MaterialTheme.colorScheme.onSurfaceVariant
}
