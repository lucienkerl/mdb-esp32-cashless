package xyz.vmflow.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import xyz.vmflow.R
import xyz.vmflow.data.DeviceNetwork
import xyz.vmflow.ui.theme.OfflineGray
import xyz.vmflow.ui.theme.OnlineGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed

// Android counterpart of the web's `NetworkBadge.vue` / `SignalIcon.vue` and
// iOS `Views/Components/NetworkViews.swift`. Logic: `data/DeviceNetwork.kt`.

@Composable
fun networkKindLabel(kind: DeviceNetwork.Kind): String = stringResource(
    when (kind) {
        DeviceNetwork.Kind.WIFI -> R.string.net_kind_wifi
        DeviceNetwork.Kind.CELLULAR -> R.string.net_kind_cellular
    }
)

@Composable
fun networkQualityLabel(quality: DeviceNetwork.Quality): String = stringResource(
    when (quality) {
        DeviceNetwork.Quality.EXCELLENT -> R.string.net_quality_excellent
        DeviceNetwork.Quality.GOOD -> R.string.net_quality_good
        DeviceNetwork.Quality.FAIR -> R.string.net_quality_fair
        DeviceNetwork.Quality.WEAK -> R.string.net_quality_weak
        DeviceNetwork.Quality.NONE -> R.string.net_quality_none
    }
)

fun networkColor(tone: DeviceNetwork.Tone?, muted: Boolean = false): Color = when {
    muted -> OfflineGray
    tone == DeviceNetwork.Tone.OK -> OnlineGreen
    tone == DeviceNetwork.Tone.WEAK -> StockOrange
    tone == DeviceNetwork.Tone.BAD -> StockRed
    else -> OfflineGray
}

/** WiFi fan (dot + 3 arcs) or cellular bars, with 0–4 filled steps. */
@Composable
fun SignalIcon(
    kind: DeviceNetwork.Kind,
    level: Int?,
    tone: DeviceNetwork.Tone?,
    modifier: Modifier = Modifier,
    muted: Boolean = false,
    size: Dp = 14.dp,
    tint: Color? = null,
) {
    val color = tint ?: networkColor(tone, muted)
    fun on(step: Int): Boolean = level != null && (if (kind == DeviceNetwork.Kind.WIFI && step == 1) true else level >= step)
    Canvas(modifier = modifier.size(size).clearAndSetSemantics { }) {
        val s = this.size.width / 16f
        if (kind == DeviceNetwork.Kind.WIFI) {
            // Arcs around the dot at (8, 13), radii 4 / 7.2 / 10.2, ±45°.
            listOf(2 to 4f, 3 to 7.2f, 4 to 10.2f).forEach { (step, r) ->
                val d = r * 0.7071f
                val path = Path().apply {
                    moveTo((8 - d) * s, (13 - d) * s)
                    quadraticBezierTo(8 * s, (13 - r * 1.4142f) * s, (8 + d) * s, (13 - d) * s)
                }
                drawPath(
                    path,
                    color = color.copy(alpha = if (on(step)) 1f else 0.25f),
                    style = Stroke(width = 1.9f * s, cap = StrokeCap.Round),
                )
            }
            drawCircle(
                color = color.copy(alpha = if (on(1)) 1f else 0.25f),
                radius = 1.7f * s,
                center = Offset(8 * s, 13 * s),
            )
        } else {
            val barW = 2.6f * s
            val gap = (16 * s - 4 * barW) / 3
            for (i in 1..4) {
                val h = 16 * s * 0.85f * i / 4
                drawRoundRect(
                    color = color.copy(alpha = if (on(i)) 1f else 0.25f),
                    topLeft = Offset((i - 1) * (barW + gap), 16 * s - h),
                    size = Size(barW, h),
                    cornerRadius = CornerRadius(s, s),
                )
            }
        }
    }
}

/**
 * Compact "[icon] Office-WiFi" for the line under the status chip. A weak
 * signal names the problem instead of the SSID; offline shows the last known
 * network greyed out.
 */
@Composable
fun NetworkInline(network: DeviceNetwork, offline: Boolean, modifier: Modifier = Modifier) {
    val weak = !offline && network.isWeak
    val kind = networkKindLabel(network.kind)
    val name = network.name ?: kind
    val label = when {
        offline -> stringResource(R.string.net_last, name)
        weak && network.quality != null -> "$kind · ${networkQualityLabel(network.quality)}"
        network.kind == DeviceNetwork.Kind.CELLULAR && network.mode != null -> "$name · ${network.mode}"
        else -> name
    }
    val color = when {
        weak -> networkColor(network.tone)
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Row(
        modifier = modifier.semantics(mergeDescendants = true) { contentDescription = "$kind: $label" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        SignalIcon(network.kind, network.level, network.tone, muted = offline, size = 12.dp)
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = if (weak) FontWeight.SemiBold else null,
            color = color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
