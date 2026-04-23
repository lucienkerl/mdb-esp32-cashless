package de.kerlhandel.vmflow.ui.dashboard

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.Euro
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.DailySales
import de.kerlhandel.vmflow.data.model.SaleWithMachine
import de.kerlhandel.vmflow.ui.common.ProductImage
import de.kerlhandel.vmflow.ui.common.VMflowPrimaryButton
import de.kerlhandel.vmflow.ui.common.VMflowSecondaryButton
import de.kerlhandel.vmflow.ui.common.VMflowTopAppBar
import de.kerlhandel.vmflow.ui.theme.BrandLime400
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import de.kerlhandel.vmflow.ui.theme.VMBlue
import de.kerlhandel.vmflow.ui.theme.VMGreen
import de.kerlhandel.vmflow.ui.theme.VMRed
import de.kerlhandel.vmflow.ui.theme.VMTeal
import de.kerlhandel.vmflow.ui.theme.VMYellow
import de.kerlhandel.vmflow.util.DateFormatting

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(
    onOpenRefill: () -> Unit,
    onOpenMachines: () -> Unit,
    viewModel: DashboardViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { viewModel.load() }
    val pullState = rememberPullToRefreshState()
    var menuOpen by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            VMflowTopAppBar(
                title = state.organizationName ?: stringResource(R.string.nav_dashboard),
                actions = {
                    Box {
                        IconButton(onClick = { menuOpen = true }) {
                            Box(
                                modifier = Modifier
                                    .size(36.dp)
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.surfaceContainerHighest),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    Icons.Filled.Person,
                                    contentDescription = stringResource(R.string.cd_account_menu),
                                )
                            }
                        }
                        DropdownMenu(
                            expanded = menuOpen,
                            onDismissRequest = { menuOpen = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.auth_sign_out)) },
                                leadingIcon = {
                                    Icon(
                                        Icons.AutoMirrored.Filled.Logout,
                                        contentDescription = null,
                                    )
                                },
                                onClick = { menuOpen = false; viewModel.logout() },
                            )
                        }
                    }
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        PullToRefreshBox(
            state = pullState,
            isRefreshing = state.loading,
            onRefresh = { viewModel.load() },
            modifier = Modifier.fillMaxSize().padding(inner),
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item { KpiSection(state.kpis) }
                item {
                    QuickActions(
                        hasActiveRefill = false,
                        onRefill = onOpenRefill,
                        onMachines = onOpenMachines,
                    )
                }
                item { ChartCard(state.kpis?.dailySales.orEmpty(), state.kpis?.monthRevenue ?: 0.0) }
                item {
                    RecentSalesCard(
                        sales = state.kpis?.recentSales.orEmpty().take(10),
                        loading = state.loading,
                    )
                }
                state.error?.let { err ->
                    item {
                        Text(
                            "Error: $err",
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }

            if (state.loading && state.kpis == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = BrandSlate900)
                }
            }
        }
    }
}

// ---------- KPI ----------

@Composable
private fun KpiSection(kpis: de.kerlhandel.vmflow.data.repository.DashboardKpis?) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            KpiTile(
                icon = Icons.Filled.Euro,
                accent = VMBlue,
                title = stringResource(R.string.dashboard_today_revenue),
                value = DateFormatting.formatCurrency(kpis?.todayRevenue ?: 0.0),
                sub = stringResource(
                    R.string.dashboard_yesterday,
                    DateFormatting.formatCurrency(kpis?.yesterdayRevenue ?: 0.0),
                ),
                modifier = Modifier.weight(1f),
            )
            KpiTile(
                icon = Icons.Filled.ShoppingCart,
                accent = VMGreen,
                title = stringResource(R.string.dashboard_today_sales),
                value = (kpis?.todaySalesCount ?: 0).toString(),
                sub = stringResource(R.string.dashboard_this_week, kpis?.weekSalesCount ?: 0),
                modifier = Modifier.weight(1f),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            KpiTile(
                icon = Icons.Filled.Storefront,
                accent = VMTeal,
                title = stringResource(R.string.dashboard_machines),
                value = "${kpis?.machinesOnline ?: 0}/${kpis?.machinesTotal ?: 0}",
                sub = stringResource(R.string.dashboard_online),
                modifier = Modifier.weight(1f),
            )
            KpiTile(
                icon = Icons.Filled.Warning,
                accent = stockAlertColor(kpis),
                title = stringResource(R.string.dashboard_stock_alerts),
                value = "${(kpis?.stockCriticalCount ?: 0) + (kpis?.stockLowCount ?: 0)}",
                sub = stringResource(
                    R.string.dashboard_x_critical_y_low,
                    kpis?.stockCriticalCount ?: 0,
                    kpis?.stockLowCount ?: 0,
                ),
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun KpiTile(
    icon: ImageVector,
    accent: Color,
    title: String,
    value: String,
    sub: String?,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Column(Modifier.padding(14.dp)) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(accent.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null, tint = accent)
            }
            Spacer(Modifier.height(10.dp))
            Text(
                title,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
            Text(
                value,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            sub?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun stockAlertColor(kpis: de.kerlhandel.vmflow.data.repository.DashboardKpis?): Color =
    when {
        (kpis?.stockCriticalCount ?: 0) > 0 -> VMRed
        (kpis?.stockLowCount ?: 0) > 0 -> VMYellow
        else -> VMGreen
    }

// ---------- Quick Actions ----------

@Composable
private fun QuickActions(hasActiveRefill: Boolean, onRefill: () -> Unit, onMachines: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        VMflowPrimaryButton(
            text = stringResource(
                if (hasActiveRefill) R.string.dashboard_continue_refill
                else R.string.dashboard_start_refill,
            ),
            onClick = onRefill,
            leadingIcon = {
                Icon(
                    if (hasActiveRefill) Icons.Filled.ArrowForward else Icons.Filled.Refresh,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                )
            },
            modifier = Modifier.weight(1f),
        )
        VMflowSecondaryButton(
            text = stringResource(R.string.nav_machines),
            onClick = onMachines,
            leadingIcon = {
                Icon(
                    Icons.Filled.Storefront,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                )
            },
            modifier = Modifier.weight(1f),
        )
    }
}

// ---------- Chart ----------

@Composable
private fun ChartCard(daily: List<DailySales>, monthRevenue: Double) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(
                        stringResource(R.string.dashboard_revenue_30_days),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        DateFormatting.formatCurrency(monthRevenue),
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(BrandLime400.copy(alpha = 0.18f))
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                ) {
                    Text(
                        "30d",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = BrandSlate900,
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            if (daily.isEmpty()) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(180.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(R.string.dashboard_no_sales_data),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                SimpleBarChart(daily, Modifier.fillMaxWidth().height(180.dp))
            }
        }
    }
}

@Composable
private fun SimpleBarChart(daily: List<DailySales>, modifier: Modifier = Modifier) {
    val max = daily.maxOf { it.revenue }.coerceAtLeast(1.0)
    androidx.compose.foundation.Canvas(modifier) {
        val barWidth = size.width / daily.size
        val pad = 2f
        daily.forEachIndexed { i, day ->
            val ratio = (day.revenue / max).toFloat()
            val barHeight = (size.height - 16f) * ratio
            drawRoundRect(
                color = BrandSlate900,
                topLeft = androidx.compose.ui.geometry.Offset(
                    x = i * barWidth + pad,
                    y = size.height - barHeight,
                ),
                size = androidx.compose.ui.geometry.Size(
                    width = (barWidth - pad * 2).coerceAtLeast(1f),
                    height = barHeight,
                ),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(4f, 4f),
            )
        }
    }
}

// ---------- Recent sales ----------

@Composable
private fun RecentSalesCard(sales: List<SaleWithMachine>, loading: Boolean) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp)) {
            Text(
                stringResource(R.string.dashboard_recent_sales),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(8.dp))
            if (sales.isEmpty() && !loading) {
                Text(
                    stringResource(R.string.dashboard_no_recent_sales),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 12.dp),
                )
            } else {
                sales.forEach { RecentSaleRow(it) }
            }
        }
    }
}

@Composable
private fun RecentSaleRow(item: SaleWithMachine) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProductImage(item.productImagePath, size = 40.dp)
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                item.productName ?: "Item #${item.sale.itemNumber ?: 0}",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            item.machineName?.let { name ->
                Text(
                    name,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(
                item.sale.formattedPrice(),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold,
                color = BrandSlate900,
            )
            Text(
                DateFormatting.formatTimeHms(item.sale.createdAt),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
