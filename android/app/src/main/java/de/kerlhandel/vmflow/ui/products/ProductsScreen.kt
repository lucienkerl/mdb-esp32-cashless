package de.kerlhandel.vmflow.ui.products

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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.ProductCategory
import de.kerlhandel.vmflow.ui.common.ProductImage
import de.kerlhandel.vmflow.ui.common.VMflowCenterTopAppBar
import de.kerlhandel.vmflow.ui.theme.BrandLime400
import de.kerlhandel.vmflow.ui.theme.BrandSlate900

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProductsScreen(
    onBack: () -> Unit,
    viewModel: ProductsViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { viewModel.load() }

    var tabIndex by remember { mutableIntStateOf(0) }
    var editingProduct by remember { mutableStateOf<Product?>(null) }
    var showAddProduct by remember { mutableStateOf(false) }
    var showAddCategory by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            VMflowCenterTopAppBar(
                title = stringResource(R.string.nav_products),
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
            ExtendedFloatingActionButton(
                onClick = {
                    if (tabIndex == 0) showAddProduct = true
                    else showAddCategory = true
                },
                containerColor = BrandSlate900,
                contentColor = BrandLime400,
                elevation = FloatingActionButtonDefaults.elevation(defaultElevation = 3.dp),
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = {
                    Text(
                        if (tabIndex == 0) stringResource(R.string.products_add)
                        else stringResource(R.string.products_tab_categories),
                        fontWeight = FontWeight.SemiBold,
                    )
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        Column(Modifier.fillMaxSize().padding(inner)) {
            PrimaryTabRow(selectedTabIndex = tabIndex) {
                Tab(
                    selected = tabIndex == 0,
                    onClick = { tabIndex = 0 },
                    text = { Text(stringResource(R.string.products_tab_products)) },
                )
                Tab(
                    selected = tabIndex == 1,
                    onClick = { tabIndex = 1 },
                    text = { Text(stringResource(R.string.products_tab_categories)) },
                )
            }

            when {
                state.loading && state.products.isEmpty() -> Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator(color = BrandSlate900) }

                tabIndex == 0 -> ProductsTab(
                    state = state,
                    onSearch = viewModel::setSearch,
                    onEdit = { editingProduct = it },
                )

                else -> CategoriesTab(
                    state = state,
                    onSave = { id, name ->
                        if (id == null) viewModel.createCategory(name)
                        else viewModel.updateCategory(id, name)
                    },
                    onDelete = viewModel::deleteCategory,
                )
            }
        }
    }

    // ----- Sheets -----
    editingProduct?.let { p ->
        ProductEditSheet(
            product = p,
            categories = state.categories,
            onDismiss = { editingProduct = null },
            onSave = { id, name, price, catId, disc ->
                viewModel.saveProduct(id, name, price, catId, disc)
                editingProduct = null
            },
            onDelete = { id ->
                viewModel.deleteProduct(id)
                editingProduct = null
            },
        )
    }

    if (showAddProduct) {
        ProductEditSheet(
            product = null,
            categories = state.categories,
            onDismiss = { showAddProduct = false },
            onSave = { _, name, price, catId, disc ->
                viewModel.saveProduct(null, name, price, catId, disc)
                showAddProduct = false
            },
        )
    }

    if (showAddCategory) {
        CategoryAddDialog(
            onDismiss = { showAddCategory = false },
            onConfirm = { name ->
                viewModel.createCategory(name)
                showAddCategory = false
            },
        )
    }
}

@Composable
private fun ProductsTab(
    state: ProductsUiState,
    onSearch: (String) -> Unit,
    onEdit: (Product) -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        TextField(
            value = state.search,
            onValueChange = onSearch,
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
                .padding(horizontal = 16.dp, vertical = 8.dp),
        )

        if (state.filtered.isEmpty() && !state.loading) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        Icons.Filled.Inventory2,
                        contentDescription = null,
                        modifier = Modifier.size(44.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        stringResource(R.string.products_empty),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        } else {
            LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(state.filtered, key = { it.id }) { product ->
                    ProductRow(product = product, onClick = { onEdit(product) })
                }
            }
        }
    }
}

@Composable
private fun ProductRow(product: Product, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProductImage(product.imagePath, size = 48.dp)
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    product.name ?: "",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                )
                if (product.discontinued == true) {
                    Spacer(Modifier.size(6.dp))
                    DcBadge()
                }
            }
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

@Composable
private fun DcBadge() {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(MaterialTheme.colorScheme.surfaceContainerHighest)
            .padding(horizontal = 6.dp, vertical = 1.dp),
    ) {
        Text(
            "DC",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun CategoriesTab(
    state: ProductsUiState,
    onSave: (id: String?, name: String) -> Unit,
    onDelete: (String) -> Unit,
) {
    if (state.categories.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                stringResource(R.string.products_tab_categories) + " —",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        return
    }
    var editing by remember { mutableStateOf<ProductCategory?>(null) }
    LazyColumn(
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(state.categories, key = { it.id }) { cat ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainer)
                    .clickable { editing = cat }
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    cat.name,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                val count = state.products.count { it.category == cat.id }
                Text(
                    "$count",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
    editing?.let { cat ->
        CategoryAddDialog(
            initialName = cat.name,
            onDismiss = { editing = null },
            onConfirm = { name -> onSave(cat.id, name); editing = null },
            onDelete = { onDelete(cat.id); editing = null },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CategoryAddDialog(
    initialName: String = "",
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
    onDelete: (() -> Unit)? = null,
) {
    val sheetState = androidx.compose.material3.rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var name by remember { mutableStateOf(initialName) }
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp)
                .padding(bottom = 8.dp),
        ) {
            Text(
                stringResource(R.string.products_tab_categories),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.size(16.dp))
            TextField(
                value = name,
                onValueChange = { name = it },
                label = { Text(stringResource(R.string.products_name)) },
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
            Spacer(Modifier.size(20.dp))
            de.kerlhandel.vmflow.ui.common.VMflowPrimaryButton(
                text = stringResource(R.string.common_save),
                onClick = { onConfirm(name.trim()) },
                enabled = name.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            )
            if (onDelete != null) {
                Spacer(Modifier.size(6.dp))
                androidx.compose.material3.TextButton(
                    onClick = { onDelete() },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        stringResource(R.string.trays_delete),
                        color = MaterialTheme.colorScheme.error,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            Spacer(Modifier.size(12.dp))
        }
    }
}
