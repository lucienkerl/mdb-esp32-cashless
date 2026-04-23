package de.kerlhandel.vmflow.ui.trays

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.Tray
import de.kerlhandel.vmflow.data.model.TrayUpsert
import de.kerlhandel.vmflow.ui.common.ProductImage
import de.kerlhandel.vmflow.ui.common.VMflowPrimaryButton
import de.kerlhandel.vmflow.ui.common.VMflowSecondaryButton
import de.kerlhandel.vmflow.ui.theme.BrandSlate900

/**
 * ModalBottomSheet for creating or editing a machine_trays row. Handles slot
 * number, product picker (with fuzzy search), capacity / current stock / min
 * stock / fill-when-below. Delete is exposed only when editing an existing row.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrayEditSheet(
    tray: Tray?,
    machineId: String,
    products: List<Product>,
    onDismiss: () -> Unit,
    onSave: (TrayUpsert, existingId: String?) -> Unit,
    onDelete: ((String) -> Unit)? = null,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var itemNumber by remember(tray) { mutableStateOf(tray?.itemNumber?.toString() ?: "") }
    var productId by remember(tray) { mutableStateOf(tray?.productId) }
    var capacity by remember(tray) { mutableStateOf(tray?.capacity?.toString() ?: "10") }
    var currentStock by remember(tray) { mutableStateOf(tray?.currentStock?.toString() ?: "0") }
    var minStock by remember(tray) { mutableStateOf(tray?.minStock?.toString() ?: "0") }
    var fillBelow by remember(tray) { mutableStateOf(tray?.fillWhenBelow?.toString() ?: "0") }

    var showProductPicker by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 16.dp)
                .verticalScroll(rememberScrollState())
                .imePadding()
                .navigationBarsPadding(),
        ) {
            Text(
                text = stringResource(
                    if (tray == null) R.string.trays_add else R.string.trays_tab,
                ),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.size(16.dp))

            NumberField(
                value = itemNumber,
                onValueChange = { itemNumber = it.filter(Char::isDigit) },
                label = stringResource(R.string.trays_slot, 0).replace("0", "").trim(),
            )
            Spacer(Modifier.size(10.dp))

            // Product selector
            ProductSelector(
                selectedProduct = products.firstOrNull { it.id == productId },
                onClick = { showProductPicker = true },
                onClear = { productId = null },
            )
            Spacer(Modifier.size(10.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                NumberField(
                    value = capacity,
                    onValueChange = { capacity = it.filter(Char::isDigit) },
                    label = stringResource(R.string.trays_capacity),
                    modifier = Modifier.weight(1f),
                )
                NumberField(
                    value = currentStock,
                    onValueChange = { currentStock = it.filter(Char::isDigit) },
                    label = stringResource(R.string.trays_stock),
                    modifier = Modifier.weight(1f),
                )
            }
            Spacer(Modifier.size(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                NumberField(
                    value = minStock,
                    onValueChange = { minStock = it.filter(Char::isDigit) },
                    label = stringResource(R.string.trays_min_stock),
                    modifier = Modifier.weight(1f),
                )
                NumberField(
                    value = fillBelow,
                    onValueChange = { fillBelow = it.filter(Char::isDigit) },
                    label = stringResource(R.string.trays_fill_when_below),
                    modifier = Modifier.weight(1f),
                )
            }

            Spacer(Modifier.size(24.dp))

            VMflowPrimaryButton(
                text = stringResource(R.string.trays_save),
                onClick = {
                    val payload = TrayUpsert(
                        machineId = machineId,
                        itemNumber = itemNumber.toIntOrNull() ?: 0,
                        productId = productId,
                        capacity = capacity.toIntOrNull() ?: 0,
                        currentStock = currentStock.toIntOrNull() ?: 0,
                        minStock = minStock.toIntOrNull() ?: 0,
                        fillWhenBelow = fillBelow.toIntOrNull() ?: 0,
                    )
                    onSave(payload, tray?.id)
                },
                enabled = itemNumber.isNotBlank() && capacity.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            )

            if (tray != null && onDelete != null) {
                Spacer(Modifier.size(8.dp))
                TextButton(
                    onClick = { onDelete(tray.id) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        stringResource(R.string.trays_delete),
                        color = MaterialTheme.colorScheme.error,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            } else {
                Spacer(Modifier.size(8.dp))
                VMflowSecondaryButton(
                    text = stringResource(R.string.trays_cancel),
                    onClick = onDismiss,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }

    if (showProductPicker) {
        ProductPickerSheet(
            products = products,
            onDismiss = { showProductPicker = false },
            onPick = { selected ->
                productId = selected.id
                showProductPicker = false
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProductPickerSheet(
    products: List<Product>,
    onDismiss: () -> Unit,
    onPick: (Product) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var query by remember { mutableStateOf("") }
    val filtered = remember(products, query) {
        if (query.isBlank()) products else products.filter {
            (it.name ?: "").lowercase().contains(query.lowercase())
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .imePadding()
                .navigationBarsPadding(),
        ) {
            TextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text(stringResource(R.string.common_search)) },
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
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.size(12.dp))
            LazyColumn(
                modifier = Modifier.heightIn(max = 420.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(filtered, key = { it.id }) { product ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onPick(product) }
                            .padding(vertical = 8.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        ProductImage(product.imagePath, size = 40.dp)
                        Spacer(Modifier.size(12.dp))
                        Text(
                            product.name ?: "",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.weight(1f),
                        )
                        product.sellprice?.let {
                            Text(
                                String.format("%.2f €", it),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.size(16.dp))
        }
    }
}

@Composable
private fun ProductSelector(
    selectedProduct: Product?,
    onClick: () -> Unit,
    onClear: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ProductImage(selectedProduct?.imagePath, size = 40.dp)
            Spacer(Modifier.size(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.trays_product),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    selectedProduct?.name ?: stringResource(R.string.trays_no_product),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            if (selectedProduct != null) {
                IconButton(onClick = onClear) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun NumberField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Number,
            imeAction = ImeAction.Next,
        ),
        textStyle = MaterialTheme.typography.bodyLarge,
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            focusedTextColor = MaterialTheme.colorScheme.onSurface,
            unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = modifier.fillMaxWidth(),
    )
}

/** Batch-Add dialog content — pack into a ModalBottomSheet from the caller. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BatchAddSheet(
    machineId: String,
    onDismiss: () -> Unit,
    onConfirm: (startSlot: Int, count: Int, capacity: Int) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var startSlot by remember { mutableStateOf("1") }
    var count by remember { mutableStateOf("10") }
    var capacity by remember { mutableStateOf("10") }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 16.dp)
                .imePadding()
                .navigationBarsPadding(),
        ) {
            Text(
                stringResource(R.string.trays_batch_add),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.size(16.dp))

            NumberField(
                value = startSlot,
                onValueChange = { startSlot = it.filter(Char::isDigit) },
                label = stringResource(R.string.trays_start_slot),
            )
            Spacer(Modifier.size(10.dp))
            NumberField(
                value = count,
                onValueChange = { count = it.filter(Char::isDigit) },
                label = stringResource(R.string.trays_count),
            )
            Spacer(Modifier.size(10.dp))
            NumberField(
                value = capacity,
                onValueChange = { capacity = it.filter(Char::isDigit) },
                label = stringResource(R.string.trays_capacity),
            )

            Spacer(Modifier.size(20.dp))

            VMflowPrimaryButton(
                text = stringResource(R.string.trays_batch_add),
                onClick = {
                    onConfirm(
                        startSlot.toIntOrNull() ?: 1,
                        count.toIntOrNull() ?: 1,
                        capacity.toIntOrNull() ?: 10,
                    )
                },
                enabled = startSlot.isNotBlank() && count.isNotBlank() && capacity.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
