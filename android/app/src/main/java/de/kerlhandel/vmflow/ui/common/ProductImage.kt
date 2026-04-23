package de.kerlhandel.vmflow.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import de.kerlhandel.vmflow.R

@Composable
fun ProductImage(
    imagePath: String?,
    modifier: Modifier = Modifier,
    size: Dp = 44.dp,
) {
    val supabaseUrl = LocalSupabaseUrl.current
    val url = remember(imagePath, supabaseUrl) {
        if (imagePath.isNullOrBlank()) null
        else "$supabaseUrl/storage/v1/object/public/product-images/$imagePath"
    }

    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh),
        contentAlignment = Alignment.Center,
    ) {
        if (url != null) {
            AsyncImage(
                model = ImageRequest.Builder(androidx.compose.ui.platform.LocalContext.current)
                    .data(url)
                    .crossfade(true)
                    .build(),
                contentDescription = stringResource(R.string.cd_product_image),
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(size).clip(RoundedCornerShape(8.dp)),
            )
        } else {
            Icon(
                Icons.Filled.Inventory2,
                contentDescription = stringResource(R.string.cd_product_image),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
