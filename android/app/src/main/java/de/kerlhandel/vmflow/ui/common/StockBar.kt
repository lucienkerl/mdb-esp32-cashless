package de.kerlhandel.vmflow.ui.common

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import de.kerlhandel.vmflow.ui.theme.VMBlue
import de.kerlhandel.vmflow.ui.theme.VMGreen
import de.kerlhandel.vmflow.ui.theme.VMOrange
import de.kerlhandel.vmflow.ui.theme.VMRed
import de.kerlhandel.vmflow.ui.theme.VMYellow

@Composable
fun StockBar(
    current: Int,
    capacity: Int,
    modifier: Modifier = Modifier,
    showLabel: Boolean = true,
    height: Dp = 8.dp,
    minStock: Int? = null,
    fillWhenBelow: Int? = null,
) {
    val ratio = if (capacity > 0) (current.toFloat() / capacity).coerceIn(0f, 1f) else 0f
    val animatedRatio by animateFloatAsState(targetValue = ratio, label = "stockRatio")

    val color = when {
        ratio > 0.5f -> VMGreen
        ratio > 0.2f -> VMYellow
        else -> VMRed
    }

    Column(modifier = modifier.semantics { stateDescription = "$current of $capacity" }) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(height)
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(50)),
        ) {
            Canvas(modifier = Modifier.fillMaxWidth().height(height)) {
                // Track
                drawRoundedRect(
                    color = Color(0xFFE5E5EA),
                    topLeft = Offset.Zero,
                    size = Size(size.width, size.height),
                    radius = size.height / 2,
                )
                // Fill
                if (animatedRatio > 0f) {
                    drawRoundedRect(
                        color = color,
                        topLeft = Offset.Zero,
                        size = Size(size.width * animatedRatio, size.height),
                        radius = size.height / 2,
                    )
                }
                // Min-stock marker (amber)
                minStock?.let { v ->
                    if (v in 1 until capacity) {
                        val x = size.width * v / capacity
                        drawMarker(x, size.height, VMOrange)
                    }
                }
                // Fill-when-below marker (blue)
                fillWhenBelow?.let { v ->
                    if (v in 1 until capacity) {
                        val x = size.width * v / capacity
                        drawMarker(x, size.height, VMBlue)
                    }
                }
            }
        }

        if (showLabel) {
            Text(
                text = "$current/$capacity",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .padding(top = 4.dp)
                    .align(Alignment.End),
            )
        }
    }
}

private fun DrawScope.drawRoundedRect(color: Color, topLeft: Offset, size: Size, radius: Float) {
    drawRoundRect(color = color, topLeft = topLeft, size = size, cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius, radius))
}

private fun DrawScope.drawMarker(x: Float, h: Float, color: Color) {
    val width = 2f
    drawRect(
        color = color,
        topLeft = Offset(x - width / 2, 0f),
        size = Size(width, h),
    )
}
