package de.kerlhandel.vmflow.ui.products

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
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.ProductCategory
import de.kerlhandel.vmflow.ui.common.ProductImage
import de.kerlhandel.vmflow.ui.common.VMflowPrimaryButton

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProductEditSheet(
    product: Product?,
    categories: List<ProductCategory>,
    onDismiss: () -> Unit,
    onSave: (id: String?, name: String, sellprice: Double?, categoryId: String?, discontinued: Boolean) -> Unit,
    onDelete: ((String) -> Unit)? = null,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var name by remember(product) { mutableStateOf(product?.name ?: "") }
    var price by remember(product) { mutableStateOf(product?.sellprice?.let { String.format("%.2f", it) } ?: "") }
    var categoryId by remember(product) { mutableStateOf(product?.category) }
    var discontinued by remember(product) { mutableStateOf(product?.discontinued == true) }
    var showCategoryPicker by remember { mutableStateOf(false) }

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
            Row(verticalAlignment = Alignment.CenterVertically) {
                ProductImage(product?.imagePath, size = 56.dp)
                Spacer(Modifier.size(12.dp))
                Text(
                    text = if (product == null)
                        stringResource(R.string.products_add)
                    else stringResource(R.string.products_tab_products),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Spacer(Modifier.size(20.dp))

            FormField(
                value = name,
                onValueChange = { name = it },
                label = stringResource(R.string.products_name),
            )
            Spacer(Modifier.size(10.dp))

            FormField(
                value = price,
                onValueChange = { price = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                label = stringResource(R.string.products_price),
                keyboardType = KeyboardType.Decimal,
            )
            Spacer(Modifier.size(10.dp))

            // Category picker
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                    .clickable { showCategoryPicker = true }
                    .padding(horizontal = 14.dp, vertical = 14.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.products_category),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(
                            categories.firstOrNull { it.id == categoryId }?.name ?: "—",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                    if (categoryId != null) {
                        IconButton(onClick = { categoryId = null }) {
                            Icon(Icons.Filled.Close, contentDescription = null)
                        }
                    }
                    Icon(Icons.Filled.ExpandMore, contentDescription = null)
                }
            }
            Spacer(Modifier.size(10.dp))

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        stringResource(R.string.products_discontinued),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
                Switch(checked = discontinued, onCheckedChange = { discontinued = it })
            }

            Spacer(Modifier.size(24.dp))

            VMflowPrimaryButton(
                text = stringResource(R.string.common_save),
                onClick = {
                    onSave(
                        product?.id,
                        name.trim(),
                        price.replace(',', '.').toDoubleOrNull(),
                        categoryId,
                        discontinued,
                    )
                },
                enabled = name.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            )

            if (product != null && onDelete != null) {
                Spacer(Modifier.size(8.dp))
                TextButton(
                    onClick = { onDelete(product.id) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        stringResource(R.string.trays_delete),
                        color = MaterialTheme.colorScheme.error,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }

    if (showCategoryPicker) {
        CategoryPickerSheet(
            categories = categories,
            onDismiss = { showCategoryPicker = false },
            onPick = { categoryId = it.id; showCategoryPicker = false },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CategoryPickerSheet(
    categories: List<ProductCategory>,
    onDismiss: () -> Unit,
    onPick: (ProductCategory) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 500.dp)
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            items(categories, key = { it.id }) { cat ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onPick(cat) }
                        .padding(vertical = 12.dp, horizontal = 8.dp),
                ) {
                    Text(cat.name, style = MaterialTheme.typography.bodyLarge)
                }
            }
        }
    }
}

@Composable
private fun FormField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Next,
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction),
        textStyle = MaterialTheme.typography.bodyLarge,
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            focusedTextColor = MaterialTheme.colorScheme.onSurface,
            unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}
