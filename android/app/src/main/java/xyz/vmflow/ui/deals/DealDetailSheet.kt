package xyz.vmflow.ui.deals

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Event
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.Newspaper
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material.icons.filled.Warehouse
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import xyz.vmflow.R
import xyz.vmflow.data.DealStockTotals
import xyz.vmflow.data.DealValidityLogic
import xyz.vmflow.data.DealValidityStatus
import xyz.vmflow.data.DealsLogic
import xyz.vmflow.data.DedupedDeal
import xyz.vmflow.data.PurchaseComparison
import xyz.vmflow.ui.components.ProductImage
import xyz.vmflow.ui.theme.StockGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockYellow
import xyz.vmflow.ui.theme.VMflowBlue
import kotlin.math.roundToInt

/**
 * Deal detail: hero image, pin/archive, price, validity (with a "not valid
 * yet" callout for upcoming offers), loyalty-app notice, matched keyword
 * groups and products with stock + EK comparison, and leaflet links. Port of
 * iOS `DealDetailSheet`, as a `ModalBottomSheet` like the app's other detail
 * sheets. [deal] must be the live copy from [uiState] so pin/archive taps
 * update the buttons immediately.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DealDetailSheet(
    deal: DedupedDeal,
    uiState: DealsUiState,
    viewModel: DealsViewModel,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val primary = deal.primary
    val validity = DealValidityLogic.validity(primary, uiState.today)
    val upcoming = upcomingColors()

    LaunchedEffect(deal.key) { viewModel.loadStock(DealsLogic.dealProductIds(deal)) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 32.dp),
        ) {
            HeroImage(primary.imageUrlLarge ?: primary.imageUrl)

            Column(
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (validity.status == DealValidityStatus.UPCOMING && validity.from != null) {
                    NotValidYetNotice(
                        dateText = longDay(validity.from),
                        relText = validity.startsInDays?.let { startsInLabel(it) },
                    )
                }

                // Title + retailer
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (deal.pinned) {
                            Icon(
                                Icons.Filled.PushPin,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                        }
                        Text(primary.dealTitle, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Storefront, contentDescription = null, tint = VMflowBlue, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(deal.retailer, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, color = VMflowBlue)
                    }
                }

                // Pin / archive
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    val pinLabel = stringResource(if (deal.pinned) R.string.deals_unpin else R.string.deals_pin)
                    if (deal.pinned) {
                        OutlinedButton(onClick = { viewModel.unpin(deal) }, modifier = Modifier.weight(1f)) {
                            Icon(Icons.Outlined.PushPin, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(pinLabel)
                        }
                    } else {
                        Button(onClick = { viewModel.pin(deal) }, modifier = Modifier.weight(1f)) {
                            Icon(Icons.Filled.PushPin, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(pinLabel)
                        }
                    }
                    OutlinedButton(
                        onClick = {
                            if (deal.archived) {
                                viewModel.unarchive(deal)
                            } else {
                                viewModel.archive(deal)
                                onDismiss()
                            }
                        },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(
                            if (deal.archived) Icons.Filled.Unarchive else Icons.Filled.Archive,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(stringResource(if (deal.archived) R.string.deals_restore else R.string.deals_archive))
                    }
                }

                HorizontalDivider()

                // Price
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    primary.dealPrice?.let {
                        Text(
                            formatEuro(it),
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                            color = if (validity.status == DealValidityStatus.UPCOMING) MaterialTheme.colorScheme.onSurface else StockGreen,
                        )
                    }
                    primary.regularPrice?.let {
                        Text(
                            formatEuro(it),
                            style = MaterialTheme.typography.titleMedium,
                            textDecoration = TextDecoration.LineThrough,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    val discount = primary.discountPct
                    if (discount != null && discount > 0) {
                        SmallChip("-${discount.roundToInt()}%", container = StockGreen, content = Color.White)
                    }
                }

                HorizontalDivider()

                // Validity
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SectionLabel(Icons.Filled.Event, stringResource(R.string.deals_detail_validity))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        val range = listOfNotNull(validity.from?.let { shortDay(it) }, validity.until?.let { shortDay(it) })
                            .joinToString(" – ")
                        if (range.isNotEmpty()) Text(range, style = MaterialTheme.typography.bodyMedium)
                        Spacer(Modifier.weight(1f))
                        val color = validityColor(validity.status, upcoming.content)
                        Text(
                            if (validity.status == DealValidityStatus.UPCOMING) {
                                stringResource(R.string.deals_not_valid_yet)
                            } else {
                                validityLabel(validity)
                            },
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = color,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(
                                    if (validity.status == DealValidityStatus.UPCOMING) upcoming.container else color.copy(alpha = 0.12f),
                                )
                                .padding(horizontal = 8.dp, vertical = 3.dp),
                        )
                    }
                }

                if (primary.requiresApp) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(StockOrange.copy(alpha = 0.08f))
                            .padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.PhoneAndroid, contentDescription = null, tint = StockOrange)
                        Spacer(Modifier.width(10.dp))
                        Column {
                            Text(stringResource(R.string.deals_requires_app_title), style = MaterialTheme.typography.titleSmall)
                            Text(
                                stringResource(R.string.deals_requires_app_body),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }

                if (deal.matchedKeywords.isNotEmpty()) {
                    HorizontalDivider()
                    KeywordsSection(deal, uiState.stock)
                }

                if (deal.matchedProducts.isNotEmpty()) {
                    HorizontalDivider()
                    ProductsSection(deal, uiState)
                }

                val uriHandler = LocalUriHandler.current
                val sourceUrl = primary.sourceUrl
                val externalUrl = primary.externalUrl
                if (sourceUrl != null || externalUrl != null) {
                    HorizontalDivider()
                    if (sourceUrl != null) {
                        OutlinedButton(onClick = { uriHandler.openUri(sourceUrl) }, modifier = Modifier.fillMaxWidth()) {
                            Icon(Icons.Filled.Newspaper, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.deals_view_prospekt))
                        }
                    }
                    if (externalUrl != null) {
                        Button(onClick = { uriHandler.openUri(externalUrl) }, modifier = Modifier.fillMaxWidth()) {
                            Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.deals_view_all_offers))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun NotValidYetNotice(dateText: String, relText: String?) {
    val colors = upcomingColors()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.container.copy(alpha = 0.6f))
            .border(1.dp, colors.content.copy(alpha = 0.4f), RoundedCornerShape(10.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Event, contentDescription = null, tint = colors.content)
        Spacer(Modifier.width(10.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                stringResource(R.string.deals_not_valid_yet),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = colors.content,
            )
            Text(
                stringResource(R.string.deals_not_valid_yet_body, dateText, relText.orEmpty()),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

@Composable
private fun HeroImage(url: String?) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 160.dp, max = 250.dp)
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        if (url != null) {
            AsyncImage(
                model = url,
                contentDescription = null,
                modifier = Modifier.fillMaxWidth().heightIn(max = 250.dp),
                contentScale = ContentScale.Fit,
            )
        } else {
            Icon(
                Icons.Filled.LocalOffer,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(48.dp),
            )
        }
    }
}

@Composable
private fun SectionLabel(icon: ImageVector, text: String, trailing: (@Composable () -> Unit)? = null) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Medium)
        if (trailing != null) {
            Spacer(Modifier.weight(1f))
            trailing()
        }
    }
}

@Composable
private fun KeywordsSection(deal: DedupedDeal, stock: Map<String, DealStockTotals>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel(Icons.Filled.LocalOffer, stringResource(R.string.deals_keywords_title))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            deal.matchedKeywords.forEach { kw ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            kw.label ?: kw.terms?.firstOrNull().orEmpty(),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                        )
                        val term = deal.primary.matchedTerm
                        if (!term.isNullOrEmpty()) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                stringResource(R.string.deals_matched_via, term),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    if (kw.linkedProducts.isEmpty()) {
                        Text(
                            stringResource(R.string.deals_keyword_no_products),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        kw.linkedProducts.forEach { p ->
                            val name = p.name ?: return@forEach
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    "• $name",
                                    style = MaterialTheme.typography.bodySmall,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f),
                                )
                                p.id?.let { StockBadges(stock[it]) }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ProductsSection(deal: DedupedDeal, uiState: DealsUiState) {
    val count = deal.matchedProducts.size
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel(
            Icons.Filled.Inventory2,
            pluralStringResource(R.plurals.deals_matched_products_title, count, count),
        ) {
            Text(
                "${(deal.primary.confidence * 100).roundToInt()}%",
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
                color = confidenceColor(deal.primary.confidence),
            )
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            deal.matchedProducts.forEach { p ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ProductImage(imagePath = p.imagePath, contentDescription = null, size = 36.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(p.name, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        p.sellprice?.let {
                            Text(
                                formatEuro(it),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        StockBadges(uiState.stock[p.id])
                        ekComparisonLine(deal, p, uiState)?.let {
                            Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "${(p.confidence * 100).roundToInt()}%",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = confidenceColor(p.confidence),
                    )
                }
            }
        }
    }
}

/** "Offer 0.99 € vs usual cost 1.09 € · Margin 40% → 45%", mirroring iOS. */
@Composable
private fun ekComparisonLine(deal: DedupedDeal, p: DedupedDeal.MatchedProduct, uiState: DealsUiState): String? {
    val summary = uiState.ekSummaries[p.id] ?: return null
    if (summary.ekCount <= 0) return null
    val usual = summary.newestGross ?: return null
    val dealGross = deal.primary.dealPrice ?: 0.0
    var line = stringResource(R.string.deals_ek_offer_vs_usual, formatEuro(dealGross), formatEuro(usual))
    PurchaseComparison.marginDelta(p.sellprice, dealGross, summary)?.let {
        line += " · " + stringResource(R.string.deals_ek_margin, it.currentPct.roundToInt(), it.dealPct.roundToInt())
    }
    return line
}

/** Warehouse + machine stock chips; "—" until loaded. */
@Composable
private fun StockBadges(totals: DealStockTotals?) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        StockBadge(
            icon = Icons.Filled.Warehouse,
            text = totals?.warehouseQty?.toString() ?: "—",
            active = (totals?.warehouseQty ?: 0) > 0,
            color = VMflowBlue,
            contentDescription = stringResource(R.string.deals_stock_warehouse),
        )
        StockBadge(
            icon = Icons.Filled.Inventory2,
            text = when {
                totals == null -> "—"
                totals.trayCapacity > 0 -> "${totals.trayStock}/${totals.trayCapacity}"
                else -> totals.trayStock.toString()
            },
            active = (totals?.trayStock ?: 0) > 0,
            color = StockGreen,
            contentDescription = stringResource(R.string.deals_stock_machines),
        )
    }
}

@Composable
private fun StockBadge(icon: ImageVector, text: String, active: Boolean, color: Color, contentDescription: String) {
    val tint = if (active) color else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.12f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(3.dp))
        Text(text, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = tint)
    }
}

private fun confidenceColor(value: Double): Color = when {
    value >= 0.85 -> StockGreen
    value >= 0.65 -> StockYellow
    else -> StockOrange
}
