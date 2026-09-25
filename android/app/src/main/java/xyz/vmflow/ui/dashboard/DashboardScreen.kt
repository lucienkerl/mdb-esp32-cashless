package xyz.vmflow.ui.dashboard

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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.launch
import kotlinx.datetime.TimeZone
import xyz.vmflow.R
import xyz.vmflow.data.ActivityFeedBuilder
import xyz.vmflow.data.DashboardKpis
import xyz.vmflow.models.MachineWithStats
import xyz.vmflow.ui.common.dayLabel
import xyz.vmflow.ui.theme.OnlineGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale

private val SectionPadding = Modifier.padding(horizontal = 16.dp)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(
    onNavigateToMachine: (String) -> Unit,
    onNavigateToDeals: () -> Unit,
    onLogout: () -> Unit,
    viewModel: DashboardViewModel = viewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val scope = rememberCoroutineScope()
    val currencyFormat = remember {
        NumberFormat.getCurrencyInstance(Locale.GERMANY).apply {
            currency = Currency.getInstance("EUR")
        }
    }
    var expandedIds by remember { mutableStateOf(setOf<String>()) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(stringResource(R.string.app_name), fontWeight = FontWeight.Bold)
                        uiState.organization?.let {
                            Text(
                                text = it.name,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                },
                actions = {
                    IconButton(onClick = onNavigateToDeals) {
                        Icon(
                            Icons.Filled.LocalOffer,
                            contentDescription = stringResource(R.string.deals_open),
                        )
                    }
                    IconButton(onClick = {
                        scope.launch {
                            viewModel.signOut()
                            onLogout()
                        }
                    }) {
                        Icon(
                            Icons.AutoMirrored.Filled.Logout,
                            contentDescription = stringResource(R.string.action_sign_out),
                        )
                    }
                }
            )
        }
    ) { padding ->
        if (uiState.isLoading && uiState.machines.isEmpty() && uiState.activity.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
            }
        } else {
            PullToRefreshBox(
                isRefreshing = uiState.isRefreshing,
                onRefresh = { viewModel.refresh() },
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
            ) {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(top = 8.dp, bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    if (uiState.newDealsCount > 0) {
                        item(key = "deals-banner") {
                            NewDealsBanner(
                                uiState.newDealsCount,
                                onClick = onNavigateToDeals,
                                modifier = SectionPadding,
                            )
                        }
                    }

                    item(key = "kpi-row") {
                        KpiCardRow(uiState = uiState, currencyFormat = currencyFormat)
                    }

                    item(key = "chart") {
                        ChartSection(
                            days = uiState.dailySales,
                            currencyFormat = currencyFormat,
                            modifier = SectionPadding.then(Modifier.fillMaxWidth()),
                        )
                    }

                    item(key = "cash-book") {
                        CashBookCard(
                            summary = uiState.cashBookSummary,
                            currencyFormat = currencyFormat,
                            modifier = SectionPadding,
                        )
                    }

                    val alertMachines = uiState.machines.filter {
                        it.stockHealth != MachineWithStats.StockHealth.OK
                    }
                    if (alertMachines.isNotEmpty()) {
                        item(key = "needs-attention-title") {
                            Text(
                                text = stringResource(R.string.dashboard_needs_attention_title),
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold,
                                modifier = SectionPadding,
                            )
                        }
                        items(alertMachines.take(5), key = { "attn-${it.machine.id}" }) { machineStats ->
                            NeedsAttentionCard(
                                machineStats = machineStats,
                                modifier = SectionPadding,
                                onClick = { onNavigateToMachine(machineStats.machine.id) },
                            )
                        }
                    }

                    item(key = "activity-title") {
                        Text(
                            text = stringResource(R.string.dashboard_recent_activity_title),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                            modifier = SectionPadding,
                        )
                    }

                    if (uiState.activity.isEmpty() && !uiState.isLoading && !uiState.hasMoreActivity) {
                        item(key = "activity-empty") {
                            Text(
                                text = stringResource(R.string.dashboard_no_recent_activity),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = SectionPadding,
                            )
                        }
                    } else {
                        // Plain computation, not `remember` — this content
                        // lambda is `LazyListScope.() -> Unit`, not a
                        // @Composable context, so composable-only APIs like
                        // `remember` can't be called directly in it (only
                        // inside the `item { }` / `items { }` blocks below).
                        val groups = ActivityFeedBuilder.groupByDay(uiState.activity, TimeZone.currentSystemDefault())
                        groups.forEach { group ->
                            item(key = "day-${group.date}") {
                                DaySectionHeader(
                                    label = dayLabel(group.date, remember { TimeZone.currentSystemDefault() }),
                                    count = group.items.size,
                                    modifier = SectionPadding,
                                )
                            }
                            items(group.items, key = { it.id }) { feedItem ->
                                ActivityFeedRow(
                                    item = feedItem,
                                    currencyFormat = currencyFormat,
                                    isExpanded = feedItem.id in expandedIds,
                                    onToggleExpanded = { id ->
                                        expandedIds = if (id in expandedIds) {
                                            expandedIds - id
                                        } else {
                                            expandedIds + id
                                        }
                                    },
                                    modifier = SectionPadding,
                                )
                            }
                        }

                        // Infinite-scroll sentinel: composing this item is the
                        // "becomes visible" signal in a LazyColumn. Hidden
                        // during a full dashboard reload so it never races
                        // loadDashboard() (mirrors the iOS `!viewModel.isLoading`
                        // guard on its own sentinel `.task`).
                        if (uiState.hasMoreActivity && !uiState.isLoading) {
                            item(key = "activity-sentinel") {
                                if (uiState.loadMoreFailed) {
                                    Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                                        TextButton(onClick = { viewModel.loadMoreActivity() }) {
                                            Text(stringResource(R.string.dashboard_retry))
                                        }
                                    }
                                } else {
                                    // Unit key, not a re-arming counter: fires once when
                                    // this composable slot first enters composition (i.e.
                                    // "becomes visible" near the bottom of the list). A key
                                    // that changes on every completed load (e.g. a raw-row
                                    // counter) sounds more faithful to the iOS
                                    // `.task(id: rawSourceRowCount)` sentinel, but measured
                                    // on-device it outran the frame loop against an account
                                    // with deep history — each load widens the window, which
                                    // almost always pulls in more raw rows (the query is a
                                    // wider `gte`, not a page), so `hasMoreActivity` rarely
                                    // flips false and the effect kept re-firing faster than
                                    // Compose could push this item off screen, hanging the
                                    // main thread (reproduced as an ANR on the emulator).
                                    // Unit still satisfies "loads more when the sentinel
                                    // becomes visible" — repeat scrolling re-enters it.
                                    LaunchedEffect(Unit) {
                                        viewModel.loadMoreActivity()
                                    }
                                    Box(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(vertical = 12.dp),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        CircularProgressIndicator(modifier = Modifier.size(20.dp))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun NewDealsBanner(count: Int, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .background(OnlineGreen.copy(alpha = 0.12f))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Filled.LocalOffer,
            contentDescription = null,
            tint = OnlineGreen,
        )
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text = pluralDealsLabel(count),
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            color = OnlineGreen,
            modifier = Modifier.weight(1f),
        )
        Icon(
            imageVector = Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = OnlineGreen,
        )
    }
}

@Composable
private fun pluralDealsLabel(count: Int) =
    pluralStringResource(R.plurals.dashboard_new_deals, count, count)

@Composable
private fun KpiCardRow(uiState: DashboardUiState, currencyFormat: NumberFormat) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "kpi-today") {
            RevenueKpiCard(
                icon = DashboardKpiIcons.Today,
                title = stringResource(R.string.dashboard_kpi_today),
                currentRevenue = uiState.kpis.todayRevenue,
                currentSales = uiState.kpis.todayCount,
                previousLabel = stringResource(R.string.dashboard_kpi_yesterday),
                previousRevenue = uiState.kpis.yesterdayRevenue,
                previousSales = uiState.kpis.yesterdayCount,
                tint = MaterialTheme.colorScheme.primary,
                currencyFormat = currencyFormat,
            )
        }
        item(key = "kpi-week") {
            RevenueKpiCard(
                icon = DashboardKpiIcons.Week,
                title = stringResource(R.string.dashboard_kpi_this_week),
                currentRevenue = uiState.kpis.weekRevenue,
                currentSales = uiState.kpis.weekCount,
                previousLabel = stringResource(R.string.dashboard_kpi_last_week),
                previousRevenue = uiState.kpis.lastWeekRevenue,
                previousSales = uiState.kpis.lastWeekCount,
                tint = MaterialTheme.colorScheme.tertiary,
                currencyFormat = currencyFormat,
            )
        }
        item(key = "kpi-month") {
            RevenueKpiCard(
                icon = DashboardKpiIcons.Month,
                title = stringResource(R.string.dashboard_kpi_this_month),
                currentRevenue = uiState.kpis.monthRevenue,
                currentSales = uiState.kpis.monthCount,
                previousLabel = stringResource(R.string.dashboard_kpi_last_month),
                previousRevenue = uiState.kpis.lastMonthRevenue,
                previousSales = uiState.kpis.lastMonthCount,
                tint = MaterialTheme.colorScheme.secondary,
                currencyFormat = currencyFormat,
            )
        }
        item(key = "kpi-stock") {
            StockAlertsKpiCard(
                critical = uiState.stockCriticalCount,
                low = uiState.stockLowCount,
                machinesOnline = uiState.machinesOnline,
                machinesTotal = uiState.totalMachines,
            )
        }
    }
}

@Composable
private fun ChartSection(
    days: List<xyz.vmflow.data.DailySales>,
    currencyFormat: NumberFormat,
    modifier: Modifier = Modifier,
) {
    val total = remember(days) { DashboardKpis.totalOf(days) }
    val average = remember(days) { DashboardKpis.averageOf(days) }
    Card(modifier = modifier, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(R.string.dashboard_chart_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = currencyFormat.format(total),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            Spacer(modifier = Modifier.height(12.dp))
            DashboardBarChart(days = days, average = average)
            if (average > 0.0) {
                Text(
                    text = stringResource(R.string.dashboard_chart_average, currencyFormat.format(average)),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.tertiary,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 4.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.End,
                )
            }
        }
    }
}

@Composable
private fun NeedsAttentionCard(
    machineStats: MachineWithStats,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val healthColor = when (machineStats.stockHealth) {
        MachineWithStats.StockHealth.CRITICAL -> StockRed
        MachineWithStats.StockHealth.LOW -> StockOrange
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Card(
        onClick = onClick,
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = when (machineStats.stockHealth) {
                MachineWithStats.StockHealth.CRITICAL -> StockRed.copy(alpha = 0.08f)
                MachineWithStats.StockHealth.LOW -> StockOrange.copy(alpha = 0.08f)
                else -> MaterialTheme.colorScheme.surface
            }
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = machineStats.machine.displayName,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = pluralStringResource(
                        R.plurals.dashboard_trays_need_refill,
                        machineStats.lowTrayCount,
                        machineStats.lowTrayCount,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(Icons.Filled.Warning, contentDescription = null, tint = healthColor)
        }
    }
}

