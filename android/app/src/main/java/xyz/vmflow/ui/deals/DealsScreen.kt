package xyz.vmflow.ui.deals

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Event
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.AsyncImage
import xyz.vmflow.R
import xyz.vmflow.data.DealGroup
import xyz.vmflow.data.DealGroupMode
import xyz.vmflow.data.DealListMode
import xyz.vmflow.data.DealValidityLogic
import xyz.vmflow.data.DealValidityStatus
import xyz.vmflow.data.DedupedDeal
import xyz.vmflow.ui.theme.StockGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed
import xyz.vmflow.ui.theme.StockYellow
import kotlin.math.roundToInt

/**
 * Retailer offers matching the company's products. Port of iOS `DealsView`:
 * active/archived lists, grouping by validity (default) / retailer / product,
 * pin + archive, NEW markers and the purchase-price (EK) comparison.
 *
 * Deals that only start later are the one thing this screen must never let
 * anyone misread — they get their own sections ("valid from Mon, 28.09."), an
 * amber badge as the first line of the card, a neutral instead of green price,
 * and a callout in the detail sheet.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DealsScreen(
    onNavigateBack: () -> Unit,
    viewModel: DealsViewModel = viewModel(),
) {
    val uiState by viewModel.uiState.collectAsState()
    var selectedKey by remember { mutableStateOf<String?>(null) }
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(uiState.error) {
        uiState.error?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearError()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.deals_title)) },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
                actions = {
                    if (uiState.dealsEnabled) {
                        IconButton(onClick = { viewModel.refresh() }, enabled = !uiState.isLoading) {
                            Icon(Icons.Filled.Refresh, contentDescription = stringResource(R.string.deals_refresh))
                        }
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        when {
            uiState.settingsLoading && uiState.deals.isEmpty() -> CenteredProgress(Modifier.padding(padding))
            !uiState.dealsEnabled -> MessageState(
                icon = Icons.Filled.LocalOffer,
                title = stringResource(R.string.deals_disabled_title),
                body = stringResource(R.string.deals_disabled_body),
                modifier = Modifier.padding(padding),
            )
            else -> PullToRefreshBox(
                isRefreshing = uiState.isRefreshing,
                onRefresh = { viewModel.refresh() },
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                DealsList(
                    uiState = uiState,
                    viewModel = viewModel,
                    onOpen = { selectedKey = it.key },
                )
            }
        }
    }

    val selected = selectedKey?.let { key -> uiState.deduped.firstOrNull { it.key == key } }
    if (selected != null) {
        DealDetailSheet(
            deal = selected,
            uiState = uiState,
            viewModel = viewModel,
            onDismiss = { selectedKey = null },
        )
    }
}

@Composable
private fun DealsList(
    uiState: DealsUiState,
    viewModel: DealsViewModel,
    onOpen: (DedupedDeal) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item(key = "controls") { ListControls(uiState, viewModel) }

        when {
            uiState.noProviders -> item(key = "no-providers") {
                MessageState(
                    icon = Icons.Filled.LocalOffer,
                    title = stringResource(R.string.deals_no_providers_title),
                    body = stringResource(R.string.deals_no_providers_body),
                )
            }
            uiState.isLoading && uiState.deals.isEmpty() -> item(key = "loading") {
                Box(Modifier.fillMaxWidth().padding(vertical = 40.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
            uiState.filteredDeals.isEmpty() -> item(key = "empty") { EmptyResults(uiState) }
            else -> {
                uiState.groups.forEach { group ->
                    item(key = "header-${group.id}") { GroupHeader(group) }
                    items(group.deals, key = { "${group.id}|${it.key}" }) { deal ->
                        DealCard(
                            deal = deal,
                            uiState = uiState,
                            onClick = { onOpen(deal) },
                            onTogglePin = { if (deal.pinned) viewModel.unpin(deal) else viewModel.pin(deal) },
                            onToggleArchive = { if (deal.archived) viewModel.unarchive(deal) else viewModel.archive(deal) },
                        )
                    }
                }

                if (uiState.listMode == DealListMode.ACTIVE && uiState.suppressedActiveDeals.isNotEmpty()) {
                    item(key = "suppressed-header") {
                        val n = uiState.suppressedActiveDeals.size
                        SectionTitle(
                            text = pluralStringResource(R.plurals.deals_ek_hidden, n, n),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    items(uiState.suppressedActiveDeals, key = { "suppressed|${it.key}" }) { deal ->
                        DealCard(
                            deal = deal,
                            uiState = uiState,
                            overridePill = EkPill(stringResource(R.string.deals_ek_likely_mismatch), StockRed),
                            onClick = { onOpen(deal) },
                            onTogglePin = { if (deal.pinned) viewModel.unpin(deal) else viewModel.pin(deal) },
                            onToggleArchive = { if (deal.archived) viewModel.unarchive(deal) else viewModel.archive(deal) },
                        )
                    }
                }
            }
        }

        if (uiState.fromCache) {
            item(key = "from-cache") {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Filled.History,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        stringResource(R.string.deals_from_cache),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ListControls(uiState: DealsUiState, viewModel: DealsViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            SegmentedButton(
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
                selected = uiState.listMode == DealListMode.ACTIVE,
                onClick = { viewModel.setListMode(DealListMode.ACTIVE) },
                label = { Text(stringResource(R.string.deals_list_active)) },
            )
            SegmentedButton(
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
                selected = uiState.listMode == DealListMode.ARCHIVED,
                onClick = { viewModel.setListMode(DealListMode.ARCHIVED) },
                label = {
                    Text(
                        if (uiState.archivedCount > 0) {
                            stringResource(R.string.deals_list_archived_count, uiState.archivedCount)
                        } else {
                            stringResource(R.string.deals_list_archived)
                        },
                    )
                },
            )
        }

        OutlinedTextField(
            value = uiState.searchText,
            onValueChange = viewModel::setSearchText,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            placeholder = { Text(stringResource(R.string.deals_search_hint)) },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (uiState.searchText.isNotEmpty()) {
                    IconButton(onClick = { viewModel.setSearchText("") }) {
                        Icon(Icons.Filled.Clear, contentDescription = null)
                    }
                }
            },
        )

        val modes = listOf(
            DealGroupMode.VALIDITY to R.string.deals_group_validity,
            DealGroupMode.RETAILER to R.string.deals_group_retailer,
            DealGroupMode.PRODUCT to R.string.deals_group_product,
        )
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            modes.forEachIndexed { index, (mode, label) ->
                SegmentedButton(
                    shape = SegmentedButtonDefaults.itemShape(index = index, count = modes.size),
                    selected = uiState.groupMode == mode,
                    onClick = { viewModel.setGroupMode(mode) },
                    label = { Text(stringResource(label), maxLines = 1) },
                )
            }
        }

        if (uiState.filteredDeals.isNotEmpty()) {
            SummaryLine(uiState)
        }
    }
}

/** "12 deals · avg. −23% · 3 not valid yet" — the last part in amber. */
@Composable
private fun SummaryLine(uiState: DealsUiState) {
    val count = uiState.filteredDeals.size
    val parts = mutableListOf(pluralStringResource(R.plurals.deals_count, count, count))
    if (uiState.avgDiscount > 0) parts += stringResource(R.string.deals_avg_discount, uiState.avgDiscount)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            parts.joinToString(" · "),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        val upcoming = uiState.upcomingCount
        if (uiState.listMode == DealListMode.ACTIVE && upcoming > 0) {
            Text(
                " · " + pluralStringResource(R.plurals.deals_upcoming_hint, upcoming, upcoming),
                style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.SemiBold,
                color = upcomingColors().content,
            )
        }
    }
}

@Composable
private fun GroupHeader(group: DealGroup) {
    val upcoming = upcomingColors()
    val (icon: ImageVector?, color: Color) = when (group.kind) {
        DealGroup.Kind.PINNED -> Icons.Filled.PushPin to MaterialTheme.colorScheme.primary
        DealGroup.Kind.VALID_NOW -> Icons.Filled.CheckCircle to StockGreen
        DealGroup.Kind.UPCOMING -> Icons.Filled.Event to upcoming.content
        DealGroup.Kind.EXPIRED -> Icons.Filled.History to MaterialTheme.colorScheme.onSurfaceVariant
        DealGroup.Kind.PLAIN -> null to MaterialTheme.colorScheme.onSurface
    }
    val label = when (group.kind) {
        DealGroup.Kind.PINNED -> stringResource(R.string.deals_section_pinned)
        DealGroup.Kind.VALID_NOW -> stringResource(R.string.deals_section_valid_now)
        DealGroup.Kind.EXPIRED -> stringResource(R.string.deals_section_expired)
        DealGroup.Kind.UPCOMING -> group.from?.let { validFromLabel(it) }.orEmpty()
            .replaceFirstChar { it.uppercase() }
        DealGroup.Kind.PLAIN -> group.label.orEmpty()
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = color)
        val days = group.startsInDays
        if (group.kind == DealGroup.Kind.UPCOMING && days != null) {
            Spacer(Modifier.width(6.dp))
            Text(startsInLabel(days), style = MaterialTheme.typography.bodySmall, color = upcoming.content)
        }
        Spacer(Modifier.weight(1f))
        Text(
            group.deals.size.toString(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun SectionTitle(text: String, color: Color) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = color,
        modifier = Modifier.padding(top = 16.dp, bottom = 2.dp),
    )
}

@Composable
private fun DealCard(
    deal: DedupedDeal,
    uiState: DealsUiState,
    onClick: () -> Unit,
    onTogglePin: () -> Unit,
    onToggleArchive: () -> Unit,
    overridePill: EkPill? = null,
) {
    val validity = DealValidityLogic.validity(deal.primary, uiState.today)
    val isUpcoming = validity.status == DealValidityStatus.UPCOMING
    val upcoming = upcomingColors()
    val ek = uiState.ek(deal)
    val pill = overridePill ?: ekPill(ek)

    Card(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (deal.archived) 0.55f else 1f)
            .then(
                if (isUpcoming) {
                    Modifier.border(1.dp, upcoming.content.copy(alpha = 0.5f), CardDefaults.shape)
                } else {
                    Modifier
                },
            ),
        colors = CardDefaults.cardColors(
            containerColor = if (isUpcoming) {
                upcoming.container.copy(alpha = 0.35f)
            } else {
                MaterialTheme.colorScheme.surfaceContainerLow
            },
        ),
    ) {
        Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.Top) {
            DealThumbnail(deal)
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                // Not valid yet: first thing on the card, so nobody drives to
                // the store for a price that only starts in a few days.
                upcomingLabel(validity)?.let { UpcomingBadge(it) }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (uiState.isNew(deal)) {
                        SmallChip(stringResource(R.string.deals_new), container = StockGreen, content = Color.White)
                        Spacer(Modifier.width(4.dp))
                    }
                    if (deal.pinned) {
                        Icon(
                            Icons.Filled.PushPin,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.width(4.dp))
                    }
                    Text(
                        deal.primary.dealTitle,
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                Text(
                    "${deal.retailer} · ${matchedTargetLabel(deal)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )

                PriceRow(deal, isUpcoming = isUpcoming, pill = pill)

                ek.usualEkGross?.let {
                    Text(
                        stringResource(R.string.deals_ek_cost, formatEuro(it)),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (!isUpcoming) {
                        Text(
                            validityLabel(validity),
                            style = MaterialTheme.typography.labelSmall,
                            color = validityColor(validity.status, upcoming.content),
                        )
                    }
                    if (deal.primary.requiresApp) {
                        SmallChip(
                            stringResource(R.string.deals_app),
                            container = StockOrange.copy(alpha = 0.15f),
                            content = StockOrange,
                        )
                    }
                    if (deal.primary.confidence < 0.65) {
                        Box(
                            Modifier
                                .size(6.dp)
                                .clip(CircleShape)
                                .background(StockYellow),
                        )
                    }
                }
            }
            Column {
                IconButton(onClick = onTogglePin, modifier = Modifier.size(36.dp)) {
                    Icon(
                        if (deal.pinned) Icons.Filled.PushPin else Icons.Outlined.PushPin,
                        contentDescription = stringResource(if (deal.pinned) R.string.deals_unpin else R.string.deals_pin),
                        tint = if (deal.pinned) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
                IconButton(onClick = onToggleArchive, modifier = Modifier.size(36.dp)) {
                    Icon(
                        if (deal.archived) Icons.Filled.Unarchive else Icons.Outlined.Archive,
                        contentDescription = stringResource(if (deal.archived) R.string.deals_restore else R.string.deals_archive),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

@Composable
internal fun UpcomingBadge(text: String) {
    val colors = upcomingColors()
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(colors.container)
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Event, contentDescription = null, tint = colors.content, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(4.dp))
        Text(
            text,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = colors.content,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun PriceRow(deal: DedupedDeal, isUpcoming: Boolean, pill: EkPill?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        deal.primary.dealPrice?.let {
            Text(
                formatEuro(it),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                // Neutral instead of green while the price isn't live yet.
                color = if (isUpcoming) MaterialTheme.colorScheme.onSurface else StockGreen,
            )
        }
        deal.primary.regularPrice?.let {
            Text(
                formatEuro(it),
                style = MaterialTheme.typography.bodySmall,
                textDecoration = TextDecoration.LineThrough,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        val discount = deal.primary.discountPct
        if (discount != null && discount > 0) {
            SmallChip("-${discount.roundToInt()}%", container = StockGreen, content = Color.White)
        }
        if (pill != null) {
            Text(
                pill.text,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = pill.color,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** Keyword group label, single product name, or "N matched products" — mirrors iOS/web. */
@Composable
private fun matchedTargetLabel(deal: DedupedDeal): String {
    val kwLabel = deal.matchedKeywords.firstOrNull()?.label
    return when {
        !kwLabel.isNullOrEmpty() -> kwLabel
        deal.matchedProducts.size > 1 -> pluralStringResource(
            R.plurals.deals_matched_products_count,
            deal.matchedProducts.size,
            deal.matchedProducts.size,
        )
        deal.matchedProducts.size == 1 -> deal.matchedProducts.first().name
        else -> deal.primary.matchedTerm.orEmpty()
    }
}

@Composable
private fun DealThumbnail(deal: DedupedDeal) {
    val url = deal.primary.imageUrl ?: deal.primary.imageUrlLarge
    Box(
        modifier = Modifier
            .size(56.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        if (url != null) {
            AsyncImage(
                model = url,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        } else {
            Icon(Icons.Filled.LocalOffer, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
internal fun SmallChip(text: String, container: Color, content: Color) {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.Bold,
        color = content,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(container)
            .padding(horizontal = 6.dp, vertical = 1.dp),
    )
}

@Composable
private fun EmptyResults(uiState: DealsUiState) {
    val archived = uiState.listMode == DealListMode.ARCHIVED
    MessageState(
        icon = if (archived) Icons.Filled.Archive else Icons.Filled.Search,
        title = stringResource(if (archived) R.string.deals_empty_archived else R.string.deals_empty_active),
        body = stringResource(
            when {
                uiState.searchText.isNotBlank() -> R.string.deals_empty_search
                archived -> R.string.deals_empty_archived_hint
                else -> R.string.deals_empty_active_hint
            },
        ),
    )
}

@Composable
private fun MessageState(icon: ImageVector, title: String, body: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(48.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Text(
            body,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun CenteredProgress(modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
}
