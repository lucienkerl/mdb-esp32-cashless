package de.kerlhandel.vmflow.ui.deals

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.Deal
import de.kerlhandel.vmflow.ui.common.VMflowCenterTopAppBar
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import de.kerlhandel.vmflow.ui.theme.VMGreen
import de.kerlhandel.vmflow.ui.theme.VMOrange
import de.kerlhandel.vmflow.ui.theme.VMRed
import de.kerlhandel.vmflow.ui.theme.VMYellow
import java.time.LocalDate
import java.time.temporal.ChronoUnit

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DealsScreen(
    onBack: () -> Unit,
    viewModel: DealsViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { viewModel.load() }

    Scaffold(
        topBar = {
            VMflowCenterTopAppBar(
                title = stringResource(R.string.nav_deals),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.cd_back),
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.fetchDeals(forceRefresh = true) }) {
                        Icon(
                            Icons.Filled.Refresh,
                            contentDescription = stringResource(R.string.deals_refresh),
                        )
                    }
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        if (!state.enabled) {
            DisabledState(Modifier.padding(inner))
            return@Scaffold
        }
        when {
            state.loading && state.deals.isEmpty() -> Box(
                Modifier.fillMaxSize().padding(inner),
                contentAlignment = Alignment.Center,
            ) { CircularProgressIndicator(color = BrandSlate900) }

            state.deals.isEmpty() -> Box(
                Modifier.fillMaxSize().padding(inner),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    stringResource(R.string.deals_empty),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            else -> DealsList(state, Modifier.padding(inner), viewModel)
        }
    }
}

@Composable
private fun DisabledState(modifier: Modifier) {
    Column(
        modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Filled.LocalOffer,
            contentDescription = null,
            modifier = Modifier.size(64.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.size(16.dp))
        Text(
            stringResource(R.string.settings_deals_enable),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.size(6.dp))
        Text(
            stringResource(R.string.settings_deals_desc),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DealsList(
    state: DealsUiState,
    modifier: Modifier,
    viewModel: DealsViewModel,
) {
    val filtered = remember(state.deals, state.search) {
        val base = state.deals.filter { isValid(it) }
        if (state.search.isBlank()) base else base.filter {
            it.dealTitle.contains(state.search, ignoreCase = true) ||
                it.retailer.contains(state.search, ignoreCase = true) ||
                it.productName.contains(state.search, ignoreCase = true)
        }
    }
    val grouped = remember(filtered, state.group) {
        val m = filtered.groupBy {
            when (state.group) {
                DealGroupMode.Retailer -> it.retailer
                DealGroupMode.Product -> it.productName
            }
        }
        m.toSortedMap()
    }

    Column(modifier.fillMaxSize()) {
        SingleChoiceSegmentedButtonRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
        ) {
            SegmentedButton(
                selected = state.group == DealGroupMode.Retailer,
                onClick = { viewModel.setGroup(DealGroupMode.Retailer) },
                shape = SegmentedButtonDefaults.itemShape(0, 2),
            ) { Text(stringResource(R.string.deals_group_retailer)) }
            SegmentedButton(
                selected = state.group == DealGroupMode.Product,
                onClick = { viewModel.setGroup(DealGroupMode.Product) },
                shape = SegmentedButtonDefaults.itemShape(1, 2),
            ) { Text(stringResource(R.string.deals_group_product)) }
        }

        Row(
            modifier = Modifier.padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            KpiPill("${filtered.size}", stringResource(R.string.nav_deals), BrandSlate900)
            KpiPill(
                "${filtered.map { it.retailer }.distinct().size}",
                stringResource(R.string.deals_group_retailer),
                VMGreen,
            )
            val avg = filtered.mapNotNull { it.discountPct }
                .average().takeUnless { it.isNaN() } ?: 0.0
            KpiPill("${avg.toInt()}%", "⌀", VMOrange)
        }

        Spacer(Modifier.size(12.dp))

        LazyColumn(
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            grouped.forEach { (key, group) ->
                item(key = "hdr-$key") { GroupHeader(key, group.size) }
                items(group, key = { it.id }) { deal -> DealCard(deal) }
            }
        }
    }
}

@Composable
private fun KpiPill(value: String, label: String, accent: Color) {
    Column(
        modifier = Modifier
            .clip(RoundedCornerShape(14.dp))
            .background(accent.copy(alpha = 0.12f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = accent)
        Text(label, style = MaterialTheme.typography.labelSmall, color = accent)
    }
}

@Composable
private fun GroupHeader(name: String, count: Int) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
        Text(
            name,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Spacer(Modifier.size(8.dp))
        Text(
            "($count)",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun DealCard(deal: Deal) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(14.dp),
    ) {
        if (!deal.imageUrl.isNullOrBlank()) {
            AsyncImage(
                model = deal.imageUrl,
                contentDescription = null,
                modifier = Modifier
                    .size(64.dp)
                    .clip(RoundedCornerShape(10.dp)),
                contentScale = ContentScale.Crop,
            )
            Spacer(Modifier.size(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(
                deal.productName,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                deal.dealTitle,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
            )
            Spacer(Modifier.size(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                deal.formattedDealPrice()?.let { price ->
                    Text(
                        price,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = BrandSlate900,
                    )
                }
                deal.formattedRegularPrice()?.let { reg ->
                    Spacer(Modifier.size(8.dp))
                    Text(
                        reg,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textDecoration = TextDecoration.LineThrough,
                    )
                }
                deal.formattedDiscount()?.let { disc ->
                    Spacer(Modifier.size(8.dp))
                    Text(
                        disc,
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                        color = VMGreen,
                    )
                }
            }
            Spacer(Modifier.size(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ValidityPill(validityStatus(deal))
                ConfidencePill(deal.confidenceLevel)
            }
        }
    }
}

@Composable
private fun ValidityPill(status: Deal.ValidityStatus) {
    val (label, color) = when (status) {
        Deal.ValidityStatus.Upcoming -> stringResource(R.string.deals_upcoming) to MaterialTheme.colorScheme.primary
        Deal.ValidityStatus.Active -> stringResource(R.string.deals_active) to VMGreen
        Deal.ValidityStatus.Expiring -> stringResource(R.string.deals_expiring) to VMYellow
        Deal.ValidityStatus.Expired -> stringResource(R.string.deals_expired) to VMRed
    }
    Pill(label, color)
}

@Composable
private fun ConfidencePill(level: Deal.ConfidenceLevel) {
    val color = when (level) {
        Deal.ConfidenceLevel.High -> VMGreen
        Deal.ConfidenceLevel.Medium -> VMYellow
        Deal.ConfidenceLevel.Low -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Pill(level.name, color)
}

@Composable
private fun Pill(label: String, color: Color) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = color,
        )
    }
}

// ---- Helpers (unified validity logic — Deal model exposes raw strings) ----

private fun validityStatus(deal: Deal): Deal.ValidityStatus {
    val today = LocalDate.now().toString()
    val until = deal.validUntil ?: return Deal.ValidityStatus.Active
    if (until < today) return Deal.ValidityStatus.Expired
    val from = deal.validFrom
    if (from != null && from > today) return Deal.ValidityStatus.Upcoming
    val untilDate = runCatching { LocalDate.parse(until) }.getOrNull()
        ?: return Deal.ValidityStatus.Active
    val daysLeft = ChronoUnit.DAYS.between(LocalDate.now(), untilDate)
    return if (daysLeft <= 2) Deal.ValidityStatus.Expiring else Deal.ValidityStatus.Active
}

private fun isValid(deal: Deal): Boolean = validityStatus(deal) != Deal.ValidityStatus.Expired
