package de.kerlhandel.vmflow.ui.warehouse

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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
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
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.Warehouse
import de.kerlhandel.vmflow.data.model.WarehouseProductSummary
import de.kerlhandel.vmflow.data.model.WarehouseStockBatch
import de.kerlhandel.vmflow.ui.common.ProductImage
import de.kerlhandel.vmflow.ui.common.VMflowCenterTopAppBar
import de.kerlhandel.vmflow.ui.common.VMflowPrimaryButton
import de.kerlhandel.vmflow.ui.theme.BrandLime400
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import de.kerlhandel.vmflow.ui.theme.VMGreen
import de.kerlhandel.vmflow.ui.theme.VMRed
import de.kerlhandel.vmflow.ui.theme.VMYellow

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WarehouseScreen(
    onBack: () -> Unit,
    viewModel: WarehouseViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { viewModel.load() }

    var showIntake by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            VMflowCenterTopAppBar(
                title = stringResource(R.string.nav_warehouse),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.cd_back),
                        )
                    }
                },
            )
        },
        floatingActionButton = {
            if (state.selectedWarehouseId != null) {
                ExtendedFloatingActionButton(
                    onClick = { showIntake = true },
                    containerColor = BrandSlate900,
                    contentColor = BrandLime400,
                    elevation = FloatingActionButtonDefaults.elevation(defaultElevation = 3.dp),
                    icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                    text = {
                        Text(
                            stringResource(R.string.warehouse_intake),
                            fontWeight = FontWeight.SemiBold,
                        )
                    },
                )
            }
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        Column(Modifier.fillMaxSize().padding(inner)) {
            WarehousePicker(state, onSelect = viewModel::selectWarehouse)
            SearchField(state.search, viewModel::setSearch)

            when {
                state.loading && state.summaries.isEmpty() -> Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator(color = BrandSlate900) }

                state.selectedWarehouseId == null -> Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            Icons.Filled.Business,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(48.dp),
                        )
                        Spacer(Modifier.height(10.dp))
                        Text(
                            stringResource(R.string.warehouse_select),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                state.filteredSummaries.isEmpty() -> Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(R.string.warehouse_empty),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                else -> LazyColumn(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(state.filteredSummaries, key = { it.productId }) { summary ->
                        SummaryRow(
                            summary = summary,
                            onClick = { viewModel.openProductDrilldown(summary.productId) },
                        )
                    }
                }
            }
        }
    }

    if (showIntake) {
        IntakeSheet(
            products = state.products,
            onDismiss = { showIntake = false },
            onConfirm = { productId, quantity, batch, exp ->
                viewModel.bookIntake(productId, quantity, batch, exp)
                showIntake = false
            },
        )
    }

    state.drilldownProductId?.let { productId ->
        BatchDrilldownSheet(
            productName = state.summaries.firstOrNull { it.productId == productId }?.productName ?: "",
            batches = state.drilldownBatches,
            onDismiss = viewModel::closeDrilldown,
        )
    }
}

// ------------ Pieces ------------

@Composable
private fun WarehousePicker(state: WarehouseUiState, onSelect: (String) -> Unit) {
    if (state.warehouses.size <= 1) return
    var expanded by remember { mutableStateOf(false) }
    val selected = state.warehouses.firstOrNull { it.id == state.selectedWarehouseId }

    Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        AssistChip(
            onClick = { expanded = true },
            leadingIcon = {
                Icon(
                    Icons.Filled.Business,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
            },
            trailingIcon = { Icon(Icons.Filled.ExpandMore, contentDescription = null) },
            label = { Text(selected?.name ?: stringResource(R.string.warehouse_select)) },
            colors = AssistChipDefaults.assistChipColors(
                containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                labelColor = MaterialTheme.colorScheme.onSurface,
                leadingIconContentColor = MaterialTheme.colorScheme.primary,
            ),
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            state.warehouses.forEach { w: Warehouse ->
                DropdownMenuItem(
                    text = { Text(w.name) },
                    onClick = { onSelect(w.id); expanded = false },
                )
            }
        }
    }
}

@Composable
private fun SearchField(value: String, onValueChange: (String) -> Unit) {
    TextField(
        value = value,
        onValueChange = onValueChange,
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
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

@Composable
private fun SummaryRow(summary: WarehouseProductSummary, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProductImage(summary.imagePath, size = 44.dp)
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                summary.productName,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            val expText = summary.earliestExpiration ?: "—"
            Text(
                "${summary.batchCount} × · MHD: $expText",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        StockPill(summary)
    }
}

@Composable
private fun StockPill(summary: WarehouseProductSummary) {
    val (label, color) = when {
        summary.isOutOfStock -> stringResource(R.string.warehouse_out_of_stock) to VMRed
        summary.isLow -> stringResource(R.string.warehouse_low_stock) to VMYellow
        else -> "${summary.totalQuantity}" to VMGreen
    }
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = color,
        )
    }
}

// ------------ Intake Sheet ------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun IntakeSheet(
    products: List<Product>,
    onDismiss: () -> Unit,
    onConfirm: (productId: String, quantity: Int, batchNumber: String?, expirationDate: String?) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var productId by remember { mutableStateOf<String?>(null) }
    var quantity by remember { mutableStateOf("1") }
    var batchNumber by remember { mutableStateOf("") }
    var expiration by remember { mutableStateOf("") }
    var pickerOpen by remember { mutableStateOf(false) }
    val selectedProduct = products.firstOrNull { it.id == productId }

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
                stringResource(R.string.warehouse_intake),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.size(16.dp))

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                    .clickable { pickerOpen = true }
                    .padding(horizontal = 14.dp, vertical = 12.dp),
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
                        )
                    }
                    Icon(Icons.Filled.ExpandMore, contentDescription = null)
                }
            }

            Spacer(Modifier.size(10.dp))
            NumField(quantity, { quantity = it.filter(Char::isDigit) }, stringResource(R.string.warehouse_quantity))
            Spacer(Modifier.size(10.dp))
            NumField(batchNumber, { batchNumber = it }, stringResource(R.string.warehouse_batch_number), numeric = false)
            Spacer(Modifier.size(10.dp))
            NumField(expiration, { expiration = it }, stringResource(R.string.warehouse_expiration) + " (YYYY-MM-DD)", numeric = false)

            Spacer(Modifier.size(24.dp))

            VMflowPrimaryButton(
                text = stringResource(R.string.warehouse_intake),
                onClick = {
                    val pid = productId ?: return@VMflowPrimaryButton
                    onConfirm(
                        pid,
                        quantity.toIntOrNull() ?: 0,
                        batchNumber.takeIf { it.isNotBlank() },
                        expiration.takeIf { it.isNotBlank() },
                    )
                },
                enabled = productId != null && (quantity.toIntOrNull() ?: 0) > 0,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }

    if (pickerOpen) {
        ProductPickerSheet(
            products = products,
            onDismiss = { pickerOpen = false },
            onPick = { productId = it.id; pickerOpen = false },
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
                modifier = Modifier.height(420.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
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
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}

// ------------ Drilldown Sheet ------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BatchDrilldownSheet(
    productName: String,
    batches: List<WarehouseStockBatch>,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 12.dp)
                .navigationBarsPadding(),
        ) {
            Text(
                productName,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.size(12.dp))
            if (batches.isEmpty()) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(120.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(R.string.warehouse_empty),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                LazyColumn(
                    modifier = Modifier.height(420.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(batches, key = { it.id }) { batch ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                                .padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(
                                    batch.batchNumber ?: "—",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Medium,
                                )
                                Text(
                                    "MHD: ${batch.expirationDate ?: "—"}",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Text(
                                "${batch.quantity}",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = BrandSlate900,
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
private fun NumField(value: String, onChange: (String) -> Unit, label: String, numeric: Boolean = true) {
    TextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(
            keyboardType = if (numeric) KeyboardType.Number else KeyboardType.Text,
            imeAction = ImeAction.Next,
        ),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}
