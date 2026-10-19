package xyz.vmflow.ui.warehouse

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.AddShoppingCart
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import xyz.vmflow.R
import xyz.vmflow.data.OrderGroup
import xyz.vmflow.data.OrderLine
import xyz.vmflow.data.OrderProductInput
import xyz.vmflow.data.OrderSuggestion
import xyz.vmflow.data.OrderSupplier
import xyz.vmflow.data.PurchaseOrder
import xyz.vmflow.ui.components.ProductImage
import xyz.vmflow.ui.deals.formatEuro
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.max

/** Callbacks of the Order tab, bound to the ViewModel by `WarehouseScreen`. */
class OrderTabActions(
    val onCartons: (productId: String, cartons: Int) -> Unit,
    val onReset: (productId: String) -> Unit,
    val onAdd: (productId: String) -> Unit,
    val onRemove: (productId: String) -> Unit,
    val onAssignSupplier: (productId: String, supplierId: String) -> Unit,
    val onPlaceOrder: (OrderGroup) -> Unit,
    /** Asks for confirmation first (the screen shows [CancelOrderDialog]). */
    val onCancelOrder: (PurchaseOrder) -> Unit,
    val onCheckDelivery: (PurchaseOrder) -> Unit,
    val onNotice: (String) -> Unit,
    /** Opens the product sheet (batches, order list, supplier, carton size). */
    val onOpenProduct: (productId: String) -> Unit,
)

/**
 * Warehouse › Order: what to order per supplier so the stock lasts until the
 * delivery after next ([OrderSuggestion]), with manual entries, a carton
 * stepper, copying/sharing the list and "Mark as ordered", plus the orders on
 * the way. Mirrors iOS `WarehouseOrderView` and the web's `WarehouseOrderTab.vue`.
 */
@Composable
fun WarehouseOrderTab(uiState: WarehouseUiState, actions: OrderTabActions) {
    val groups = uiState.orderGroups

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val buffer = uiState.orderSettings.bufferDays
                Text(
                    text = if (uiState.orderSettings.countMachineStock) {
                        stringResource(R.string.warehouse_order_intro_machines, buffer)
                    } else {
                        stringResource(R.string.warehouse_order_intro, buffer)
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OrderBadge(manual = false)
                    OrderBadge(manual = true)
                }
                val listed = uiState.orderListProductIds
                val addable = uiState.orderInputs.filter { !it.discontinued && it.productId !in listed }
                if (addable.isNotEmpty()) {
                    var pickerOpen by remember { mutableStateOf(false) }
                    OutlinedButton(onClick = { pickerOpen = true }) {
                        Icon(Icons.Default.AddShoppingCart, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.warehouse_order_list_add))
                    }
                    if (pickerOpen) {
                        AddToOrderListSheet(
                            title = null,
                            products = addable,
                            onPick = { id ->
                                pickerOpen = false
                                actions.onAdd(id)
                            },
                            onDismiss = { pickerOpen = false }
                        )
                    }
                }
            }
        }

        if (OrderSuggestion.lineCount(groups) == 0) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = stringResource(R.string.warehouse_order_nothing),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        items(groups, key = { it.key }) { group ->
            OrderGroupCard(
                group = group,
                uiState = uiState,
                actions = actions
            )
        }

        if (uiState.openOrders.isNotEmpty()) {
            item {
                Text(
                    text = stringResource(R.string.warehouse_order_on_the_way),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(top = 8.dp)
                )
            }
            items(uiState.openOrders, key = { "order-" + it.id }) { order ->
                OpenOrderRow(
                    order = order,
                    isAdmin = uiState.isAdmin,
                    actionLabel = stringResource(R.string.warehouse_delivery_check),
                    onAction = { actions.onCheckDelivery(order) },
                    onCancel = { actions.onCancelOrder(order) }
                )
            }
        }
    }

}

/** Confirmation before an admin cancels an open order (its goods stop counting as on the way). */
@Composable
internal fun CancelOrderDialog(order: PurchaseOrder, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.warehouse_order_cancel)) },
        text = { Text(stringResource(R.string.warehouse_order_cancel_message, order.supplierName ?: "—")) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(stringResource(R.string.warehouse_order_cancel), color = StockRed)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.warehouse_order_keep)) }
        }
    )
}

@Composable
private fun OrderGroupCard(group: OrderGroup, uiState: WarehouseUiState, actions: OrderTabActions) {
    val settings = uiState.orderSettings
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            // Header
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = group.supplier?.name ?: stringResource(R.string.warehouse_order_no_supplier),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (group.lines.isNotEmpty()) {
                        Text(
                            text = " · " + pluralStringResource(R.plurals.warehouse_order_items, group.lines.size, group.lines.size),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                group.supplier?.let { s ->
                    Text(
                        text = stringResource(
                            R.string.warehouse_order_rhythm,
                            OrderSuggestion.leadDays(s, settings),
                            OrderSuggestion.intervalDays(s, settings)
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            if (group.lines.isEmpty()) {
                Text(
                    text = stringResource(R.string.warehouse_order_nothing_due),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            group.lines.forEachIndexed { index, line ->
                if (index > 0) HorizontalDivider()
                OrderLineRow(
                    line = line,
                    showsSupplierPicker = group.supplier == null && uiState.isAdmin,
                    suppliers = uiState.orderSuppliers,
                    actions = actions
                )
            }

            if (group.others.isNotEmpty()) {
                var pickerOpen by remember { mutableStateOf(false) }
                TextButton(onClick = { pickerOpen = true }) {
                    Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(stringResource(R.string.warehouse_order_add_product))
                }
                if (pickerOpen) {
                    AddToOrderListSheet(
                        title = group.supplier?.name,
                        products = group.others,
                        onPick = { id ->
                            pickerOpen = false
                            actions.onAdd(id)
                        },
                        onDismiss = { pickerOpen = false }
                    )
                }
            }

            if (group.lines.isNotEmpty()) {
                GroupActions(group = group, isAdmin = uiState.isAdmin, busySupplierId = uiState.busySupplierId, actions = actions)
            }

            // Footer
            if (group.supplier == null) {
                Text(
                    text = if (uiState.isAdmin) stringResource(R.string.warehouse_order_no_supplier_hint_admin)
                    else stringResource(R.string.warehouse_order_no_supplier_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (group.hasEmpty) {
                FooterNote(Icons.Default.Warning, stringResource(R.string.warehouse_order_has_empty), StockRed)
            }
            val min = group.supplier?.minOrderValue
            if (group.belowMinOrder && min != null) {
                FooterNote(Icons.Default.Info, stringResource(R.string.warehouse_order_below_min, formatEuro(min)), StockOrange)
            }
        }
    }
}

@Composable
private fun FooterNote(icon: ImageVector, text: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(text = text, style = MaterialTheme.typography.bodySmall, color = color)
    }
}

@Composable
private fun OrderLineRow(
    line: OrderLine,
    showsSupplierPicker: Boolean,
    suppliers: List<OrderSupplier>,
    actions: OrderTabActions
) {
    val productId = line.product.productId
    val size = max(1, line.product.unitSize)
    var menuOpen by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { actions.onOpenProduct(productId) },
                verticalAlignment = Alignment.CenterVertically
            ) {
                ProductImage(imagePath = line.product.imagePath, contentDescription = line.product.productName, size = 40.dp)
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = line.product.productName,
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OrderBadge(manual = line.manual != null)
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = reasonText(line),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    val stock = buildString {
                        append(stringResource(R.string.warehouse_order_available, line.available))
                        if (line.product.onOrder > 0) {
                            append(" · ")
                            append(stringResource(R.string.warehouse_order_on_the_way_units, line.product.onOrder))
                        }
                    }
                    Text(
                        text = stock,
                        style = MaterialTheme.typography.labelSmall,
                        color = if (line.product.warehouseQty == 0) StockRed else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.outline
                )
            }
            if (line.manual != null || line.overridden) {
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.warehouse_order_more))
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        if (line.manual != null) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.warehouse_order_list_remove)) },
                                onClick = {
                                    menuOpen = false
                                    actions.onRemove(productId)
                                }
                            )
                        }
                        if (line.overridden) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.warehouse_order_reset_quantity)) },
                                onClick = {
                                    menuOpen = false
                                    actions.onReset(productId)
                                }
                            )
                        }
                    }
                }
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            FilledTonalIconButton(
                onClick = { actions.onCartons(productId, line.cartons - 1) },
                enabled = line.cartons > 0
            ) {
                Icon(Icons.Default.Remove, contentDescription = stringResource(R.string.warehouse_order_less))
            }
            Text(
                text = if (size > 1) "${line.cartons} × $size" else "${line.cartons}",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .widthIn(min = 64.dp)
                    .padding(horizontal = 8.dp),
                textAlign = TextAlign.Center
            )
            FilledTonalIconButton(onClick = { actions.onCartons(productId, line.cartons + 1) }) {
                Icon(Icons.Default.Add, contentDescription = stringResource(R.string.warehouse_order_more_units))
            }
            Spacer(Modifier.width(12.dp))
            Column {
                Text(
                    text = if (size > 1) stringResource(R.string.warehouse_order_carton_units, size, line.units)
                    else pluralStringResource(R.plurals.warehouse_order_units, line.units, line.units),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (line.overridden) {
                    Text(
                        text = stringResource(R.string.warehouse_order_reset_quantity),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(4.dp))
                            .clickable { actions.onReset(productId) }
                    )
                }
            }
        }

        if (showsSupplierPicker) {
            var pickerOpen by remember { mutableStateOf(false) }
            Box {
                TextButton(onClick = { pickerOpen = true }, enabled = suppliers.isNotEmpty()) {
                    Icon(Icons.Default.PersonAdd, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.warehouse_order_assign_supplier))
                }
                DropdownMenu(expanded = pickerOpen, onDismissRequest = { pickerOpen = false }) {
                    suppliers.forEach { s ->
                        DropdownMenuItem(
                            text = { Text(s.name) },
                            onClick = {
                                pickerOpen = false
                                actions.onAssignSupplier(productId, s.id)
                            }
                        )
                    }
                }
            }
        }
    }
}

/**
 * Bottom sheet with a searchable product list (image, stock, sales) for
 * putting a product on the order list: every product not on it yet, or one
 * supplier's ([title]).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddToOrderListSheet(
    title: String?,
    products: List<OrderProductInput>,
    onPick: (productId: String) -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var query by remember { mutableStateOf("") }
    val shown = products
        .filter { query.isBlank() || it.productName.contains(query.trim(), ignoreCase = true) }
        .sortedBy { it.productName.lowercase() }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(
                text = title ?: stringResource(R.string.warehouse_order_list_add),
                style = MaterialTheme.typography.titleLarge
            )
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text(stringResource(R.string.warehouse_order_search_product)) },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(bottom = 32.dp)
            ) {
                items(shown, key = { it.productId }) { p ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onPick(p.productId) }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        ProductImage(imagePath = p.imagePath, contentDescription = p.productName, size = 48.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = p.productName,
                                style = MaterialTheme.typography.bodyLarge,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                            val details = buildList {
                                add(stringResource(R.string.warehouse_order_in_stock, p.warehouseQty))
                                if (p.avgDailySales > 0) {
                                    add(stringResource(R.string.warehouse_stock_per_day, String.format(Locale.getDefault(), "%.1f", p.avgDailySales)))
                                }
                                if (p.onOrder > 0) add(stringResource(R.string.warehouse_order_on_the_way_units, p.onOrder))
                            }
                            Text(
                                text = details.joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall,
                                color = if (p.warehouseQty == 0) StockRed else MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        Icon(
                            Icons.Default.AddCircle,
                            contentDescription = stringResource(R.string.warehouse_order_list_add),
                            tint = MaterialTheme.colorScheme.primary
                        )
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun reasonText(line: OrderLine): String {
    val manual = line.manual
    if (manual != null) {
        return "${manual.addedByName ?: "—"}, ${viaLabel(manual.addedVia)}"
    }
    val reach = line.reachDays
    return if (reach != null) stringResource(R.string.warehouse_order_lasts, reach, line.targetDays)
    else stringResource(R.string.warehouse_stock_no_sales)
}

@Composable
internal fun viaLabel(via: String): String = when (via) {
    "ios" -> stringResource(R.string.warehouse_order_via_ios)
    "android" -> stringResource(R.string.warehouse_order_via_android)
    else -> stringResource(R.string.warehouse_order_via_web)
}

@Composable
private fun GroupActions(group: OrderGroup, isAdmin: Boolean, busySupplierId: String?, actions: OrderTabActions) {
    val context = LocalContext.current
    val customerNo = stringResource(R.string.warehouse_order_customer_no)
    val copied = stringResource(R.string.warehouse_order_copied)
    val text = OrderSuggestion.orderText(group, customerNo) { n, size -> "$n × $size" }
    val hasCartons = group.lines.any { it.cartons > 0 }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        HorizontalDivider()
        if (group.value > 0) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(R.string.warehouse_order_net_cost),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                Text(text = formatEuro(group.value), style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = {
                    copyToClipboard(context, text)
                    actions.onNotice(copied)
                },
                enabled = hasCartons,
                contentPadding = PaddingValues(horizontal = 12.dp)
            ) {
                Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.warehouse_order_copy))
            }
            IconButton(onClick = { shareText(context, text) }, enabled = hasCartons) {
                Icon(Icons.Default.Share, contentDescription = stringResource(R.string.warehouse_order_share))
            }
            Spacer(Modifier.weight(1f))
            if (isAdmin && group.supplier != null) {
                Button(
                    onClick = { actions.onPlaceOrder(group) },
                    enabled = hasCartons && busySupplierId == null
                ) {
                    if (busySupplierId == group.supplier.id) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Text(stringResource(R.string.warehouse_order_mark_ordered))
                    }
                }
            }
        }
    }
}

/** One open order: supplier, date, items/units, who ordered; [onAction] = check delivery. */
@Composable
internal fun OpenOrderRow(
    order: PurchaseOrder,
    isAdmin: Boolean,
    actionLabel: String,
    onAction: () -> Unit,
    onCancel: () -> Unit
) {
    var menuOpen by remember { mutableStateOf(false) }
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)
    ) {
        Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(text = order.supplierName ?: "—", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
                Text(
                    text = orderSummary(order),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (!order.orderedByName.isNullOrBlank()) {
                    Text(
                        text = order.orderedByName,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.outline
                    )
                }
            }
            OutlinedButton(onClick = onAction, contentPadding = PaddingValues(horizontal = 12.dp)) {
                Text(actionLabel, style = MaterialTheme.typography.labelMedium)
            }
            if (isAdmin) {
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.warehouse_order_more))
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.warehouse_order_cancel), color = StockRed) },
                            onClick = {
                                menuOpen = false
                                onCancel()
                            }
                        )
                    }
                }
            }
        }
    }
}

/** "ordered 19.10.26 · 3 items · 96 units" */
@Composable
internal fun orderSummary(order: PurchaseOrder): String {
    val count = order.lines.size
    return stringResource(R.string.warehouse_order_ordered_on, formatShortDate(order.createdAt)) + " · " +
        pluralStringResource(R.plurals.warehouse_order_items, count, count) + " · " +
        pluralStringResource(R.plurals.warehouse_order_units, order.totalUnits, order.totalUnits)
}

/** "Automatic" (from stock and reach) or "Manual" (added on purpose). */
@Composable
internal fun OrderBadge(manual: Boolean) {
    val color = if (manual) Color(0xFF8B5CF6) else Color(0xFF3B82F6)
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 6.dp, vertical = 2.dp)
    ) {
        Text(
            text = stringResource(if (manual) R.string.warehouse_order_badge_manual else R.string.warehouse_order_badge_auto),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = color
        )
    }
}

/** A timestamptz (or plain date) as the device's short local date; raw string when it doesn't parse. */
internal fun formatShortDate(iso: String): String {
    val formatter = DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT).withLocale(Locale.getDefault())
    return runCatching {
        OffsetDateTime.parse(iso).atZoneSameInstant(java.time.ZoneId.systemDefault()).toLocalDate().format(formatter)
    }.recoverCatching { LocalDate.parse(iso.take(10)).format(formatter) }.getOrDefault(iso)
}

private fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("order", text))
}

private fun shareText(context: Context, text: String) {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }
    context.startActivity(Intent.createChooser(send, null))
}
