package de.kerlhandel.vmflow.ui.root

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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.ui.common.VMflowTopAppBar
import de.kerlhandel.vmflow.ui.theme.BrandLime400
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import de.kerlhandel.vmflow.ui.theme.VMBlue
import de.kerlhandel.vmflow.ui.theme.VMOrange
import de.kerlhandel.vmflow.ui.theme.VMTeal

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MoreScreen(
    onProducts: () -> Unit,
    onWarehouse: () -> Unit,
    onDeals: () -> Unit,
    onSettings: () -> Unit,
) {
    Scaffold(
        topBar = { VMflowTopAppBar(title = stringResource(R.string.nav_more)) },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(inner),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item {
                MoreItem(
                    icon = Icons.Filled.Inventory2,
                    accent = VMBlue,
                    title = stringResource(R.string.nav_products),
                    onClick = onProducts,
                )
            }
            item {
                MoreItem(
                    icon = Icons.Filled.Business,
                    accent = VMTeal,
                    title = stringResource(R.string.nav_warehouse),
                    onClick = onWarehouse,
                )
            }
            item {
                MoreItem(
                    icon = Icons.Filled.LocalOffer,
                    accent = VMOrange,
                    title = stringResource(R.string.nav_deals),
                    onClick = onDeals,
                )
            }
            item {
                MoreItem(
                    icon = Icons.Filled.Settings,
                    accent = BrandSlate900,
                    title = stringResource(R.string.nav_settings),
                    onClick = onSettings,
                )
            }
        }
    }
}

@Composable
private fun MoreItem(
    icon: ImageVector,
    accent: Color,
    title: String,
    onClick: () -> Unit,
) {
    Card(
        onClick = onClick,
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(42.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(accent.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null, tint = accent)
            }
            Spacer(Modifier.width(14.dp))
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
