package xyz.vmflow.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toJavaInstant
import xyz.vmflow.R
import xyz.vmflow.data.ConnectivityState
import xyz.vmflow.data.DeviceConnectivity
import xyz.vmflow.data.DeviceNetwork
import xyz.vmflow.data.DurationParts
import xyz.vmflow.data.ReaderState
import xyz.vmflow.data.SegmentState
import xyz.vmflow.data.StatusHistory
import xyz.vmflow.ui.theme.OfflineGray
import xyz.vmflow.ui.theme.OnlineGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.time.Duration

// Android counterpart of the web's `useConnectivity()` / DeviceStatusChip and
// iOS `Views/Components/StatusBadge.swift`. The logic lives in
// `data/DeviceConnectivity.kt`; this file only turns it into words and colour.

private val UpdatingPurple = Color(0xFF9C27B0)

/** "Now", re-read every 30 s so "contact 2 min ago" and the online → no response switch move on by themselves. */
@Composable
fun rememberNow(intervalMillis: Long = 30_000): State<Instant> {
    val now = remember { mutableStateOf(Clock.System.now()) }
    LaunchedEffect(intervalMillis) {
        while (true) {
            delay(intervalMillis)
            now.value = Clock.System.now()
        }
    }
    return now
}

fun connectivityColor(state: ConnectivityState): Color = when (state) {
    ConnectivityState.ONLINE -> OnlineGreen
    ConnectivityState.STALE -> StockOrange
    ConnectivityState.OFFLINE -> StockRed
    ConnectivityState.UPDATING -> UpdatingPurple
    ConnectivityState.NEVER, ConnectivityState.NONE -> OfflineGray
}

fun segmentColor(state: SegmentState): Color = when (state) {
    SegmentState.ONLINE -> OnlineGreen
    SegmentState.OFFLINE -> StockRed
    SegmentState.UPDATING -> UpdatingPurple
    SegmentState.UNKNOWN -> OfflineGray.copy(alpha = 0.3f)
}

@Composable
fun connectivityStateLabel(state: ConnectivityState): String = stringResource(
    when (state) {
        ConnectivityState.ONLINE -> R.string.conn_state_online
        ConnectivityState.STALE -> R.string.conn_state_stale
        ConnectivityState.OFFLINE -> R.string.conn_state_offline
        ConnectivityState.UPDATING -> R.string.conn_state_updating
        ConnectivityState.NEVER -> R.string.conn_state_never
        ConnectivityState.NONE -> R.string.conn_state_none
    }
)

@Composable
fun readerLabel(reader: ReaderState): String = stringResource(
    when (reader) {
        ReaderState.READY -> R.string.conn_reader_ready
        ReaderState.DISABLED -> R.string.conn_reader_disabled
        ReaderState.INACTIVE -> R.string.conn_reader_inactive
    }
)

@Composable
fun readerHint(reader: ReaderState): String = stringResource(
    when (reader) {
        ReaderState.READY -> R.string.conn_reader_ready_hint
        ReaderState.DISABLED -> R.string.conn_reader_disabled_hint
        ReaderState.INACTIVE -> R.string.conn_reader_inactive_hint
    }
)

/** "just now", "5 minutes ago", "2 hours ago", "3 days ago". */
@Composable
fun agoText(at: Instant?, now: Instant): String {
    if (at == null) return "—"
    val diff = now - at
    val minutes = diff.inWholeMinutes.coerceAtLeast(0).toInt()
    val hours = diff.inWholeHours.coerceAtLeast(0).toInt()
    val days = diff.inWholeDays.coerceAtLeast(0).toInt()
    return when {
        minutes < 1 -> stringResource(R.string.device_health_just_now)
        minutes < 60 -> pluralStringResource(R.plurals.device_health_minutes_ago, minutes, minutes)
        hours < 24 -> pluralStringResource(R.plurals.device_health_hours_ago, hours, hours)
        else -> pluralStringResource(R.plurals.device_health_days_ago, days, days)
    }
}

/** "14:32" today, "Mon 14:32" within the last six days, "12.10. 14:32" before that. */
fun clockText(at: Instant, now: Instant, locale: Locale = Locale.getDefault()): String {
    val zone = ZoneId.of(TimeZone.currentSystemDefault().id)
    val date = at.toJavaInstant().atZone(zone)
    val today = now.toJavaInstant().atZone(zone).toLocalDate()
    val time = date.format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale))
    val day = date.toLocalDate()
    return when {
        !day.isBefore(today) -> time
        !day.isBefore(today.minusDays(6)) -> "${date.format(DateTimeFormatter.ofPattern("EEE", locale))} $time"
        else -> "${date.format(DateTimeFormatter.ofPattern("dd.MM.", locale))} $time"
    }
}

/** "3 T 4 Std.", "2 Std. 5 Min.", "12 Min." in the user's language. */
@Composable
fun durationText(duration: Duration): String {
    val p = DurationParts.of(duration)
    return when {
        p.days > 0 -> stringResource(R.string.conn_duration_dh, p.days.toInt(), p.hours.toInt())
        p.hours > 0 -> stringResource(R.string.conn_duration_hm, p.hours.toInt(), p.minutes.toInt())
        else -> stringResource(R.string.conn_duration_m, p.minutes.coerceAtLeast(1).toInt())
    }
}

/** The one line under a status: "Contact 2 min ago", "Offline since Mon 14:32 · 2 hours ago", … */
@Composable
fun connectivityTimeLabel(c: DeviceConnectivity, now: Instant): String = when (c.state) {
    ConnectivityState.ONLINE -> stringResource(R.string.conn_time_contact, agoText(c.lastContactAt, now))
    ConnectivityState.STALE -> stringResource(R.string.conn_time_last_contact, agoText(c.lastContactAt, now))
    ConnectivityState.OFFLINE -> c.since?.let {
        stringResource(R.string.conn_time_offline_since, clockText(it, now), agoText(it, now))
    } ?: connectivityStateLabel(c.state)
    ConnectivityState.UPDATING -> stringResource(R.string.conn_time_update_started, agoText(c.since, now))
    ConnectivityState.NEVER -> stringResource(R.string.conn_time_never)
    ConnectivityState.NONE -> stringResource(R.string.conn_time_none)
}

/** Colour of the time line: only a problem carries colour. */
@Composable
fun connectivityTimeColor(state: ConnectivityState): Color = when (state) {
    ConnectivityState.OFFLINE -> StockRed
    ConnectivityState.STALE -> StockOrange
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

/** Dot + word for a device's connectivity — never colour alone. */
@Composable
fun StatusChip(
    connectivity: DeviceConnectivity,
    modifier: Modifier = Modifier
) {
    val color = connectivityColor(connectivity.state)
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(color.copy(alpha = 0.12f))
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(color)
        )
        Text(
            text = connectivityStateLabel(connectivity.state),
            style = MaterialTheme.typography.labelSmall,
            color = color,
            maxLines = 1,
            modifier = Modifier.padding(start = 6.dp)
        )
    }
}

/** The time line, plus the "machine not responding" pill when the reader is inactive. */
@Composable
fun ConnectivityTimeLine(
    connectivity: DeviceConnectivity,
    now: Instant,
    modifier: Modifier = Modifier,
    showsReader: Boolean = true,
    network: DeviceNetwork? = null,
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = connectivityTimeLabel(connectivity, now),
                style = MaterialTheme.typography.bodySmall,
                color = connectivityTimeColor(connectivity.state),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false)
            )
            if (network != null) {
                Text(
                    text = "  •  ",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.outline
                )
                NetworkInline(network = network, offline = connectivity.state == ConnectivityState.OFFLINE)
            }
        }
        if (showsReader && connectivity.reader == ReaderState.INACTIVE) {
            Text(
                text = readerLabel(ReaderState.INACTIVE),
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = StockOrange,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .background(StockOrange.copy(alpha = 0.12f))
                    .padding(horizontal = 8.dp, vertical = 3.dp)
            )
        }
    }
}

/** What the state means and what to check — only for a device that is not simply online. */
@Composable
fun ConnectivityNotice(
    connectivity: DeviceConnectivity,
    now: Instant,
    modifier: Modifier = Modifier,
) {
    val texts: Pair<String, String?>? = when (connectivity.state) {
        ConnectivityState.OFFLINE -> {
            val at = connectivity.since?.let { clockText(it, now) } ?: "—"
            stringResource(R.string.conn_notice_offline, at) to stringResource(R.string.conn_notice_offline_check)
        }
        ConnectivityState.STALE ->
            stringResource(R.string.conn_notice_stale) to stringResource(R.string.conn_notice_stale_check)
        ConnectivityState.UPDATING -> stringResource(R.string.conn_notice_updating) to null
        ConnectivityState.ONLINE ->
            if (connectivity.reader == ReaderState.INACTIVE) readerHint(ReaderState.INACTIVE) to null else null
        else -> null
    }
    if (texts == null) return
    val color = if (connectivity.state == ConnectivityState.ONLINE) StockOrange else connectivityColor(connectivity.state)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(color.copy(alpha = 0.08f))
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Box(
            modifier = Modifier
                .padding(top = 5.dp)
                .size(8.dp)
                .clip(CircleShape)
                .background(color)
        )
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = if (connectivity.state == ConnectivityState.ONLINE) readerLabel(ReaderState.INACTIVE)
                else connectivityTimeLabel(connectivity, now),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = color
            )
            Text(
                text = texts.first,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            texts.second?.let {
                Text(text = it, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

/** "96% online"; never rounds a real outage up to 100 %. */
@Composable
fun historyPercentLabel(history: StatusHistory): String {
    val pct = history.onlinePercent ?: return stringResource(R.string.conn_history_no_data)
    val shown = if (pct < 100) minOf(pct.toInt(), 99) else 100
    return stringResource(R.string.conn_history_percent, shown)
}

/** The connection history of the last 24 hours as one bar. */
@Composable
fun ConnectionHistoryBar(history: StatusHistory, modifier: Modifier = Modifier) {
    val label = historyPercentLabel(history)
    val total = history.segments.sumOf { (it.end - it.start).inWholeMilliseconds }.toFloat()
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(12.dp)
            .clip(RoundedCornerShape(3.dp))
            .semantics { contentDescription = label },
        horizontalArrangement = Arrangement.spacedBy(1.dp)
    ) {
        if (total > 0f) {
            for (seg in history.segments) {
                val share = (seg.end - seg.start).inWholeMilliseconds / total
                Box(
                    modifier = Modifier
                        .weight(share.coerceAtLeast(0.004f))
                        .fillMaxHeight()
                        .background(segmentColor(seg.state))
                )
            }
        } else {
            Box(Modifier.fillMaxWidth().fillMaxHeight().background(segmentColor(SegmentState.UNKNOWN)))
        }
    }
}
