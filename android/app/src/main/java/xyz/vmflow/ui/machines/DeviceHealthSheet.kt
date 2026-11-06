package xyz.vmflow.ui.machines

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import xyz.vmflow.R
import xyz.vmflow.data.ConnectivityState
import xyz.vmflow.data.StatusHistory
import xyz.vmflow.data.DeviceNetwork
import xyz.vmflow.data.connectivity
import xyz.vmflow.data.deviceNetwork
import xyz.vmflow.ui.components.ConnectionHistoryBar
import xyz.vmflow.ui.components.ConnectivityTimeLine
import xyz.vmflow.ui.components.SignalIcon
import xyz.vmflow.ui.components.StatusChip
import xyz.vmflow.ui.components.networkColor
import xyz.vmflow.ui.components.networkKindLabel
import xyz.vmflow.ui.components.networkQualityLabel
import xyz.vmflow.ui.components.agoText
import xyz.vmflow.ui.components.clockText
import xyz.vmflow.ui.components.durationText
import xyz.vmflow.ui.components.historyPercentLabel
import xyz.vmflow.ui.components.readerHint
import xyz.vmflow.ui.components.readerLabel
import xyz.vmflow.ui.components.rememberNow
import xyz.vmflow.data.RestartReason
import xyz.vmflow.data.formatUptimeSeconds
import xyz.vmflow.data.groupSuppressedByDay
import xyz.vmflow.data.parseRestartReason
import xyz.vmflow.models.DeviceRestart
import xyz.vmflow.models.Embedded
import xyz.vmflow.models.MdbDiagnostics
import xyz.vmflow.models.MdbLogEntry
import xyz.vmflow.models.SuppressedSale
import xyz.vmflow.models.Tray
import xyz.vmflow.ui.common.dayLabel
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed
import java.text.NumberFormat
import java.util.Locale

/**
 * Device Health + MDB diagnostics, opened from the "monitor heart" toolbar
 * icon on `MachineDetailScreen`. Android counterpart of
 * `ios/VMflow/Views/Machines/DeviceHealthSheet.swift`: uptime, restart
 * history, and the auto-removed-duplicates list are visible to every member;
 * live MDB diagnostics and the MDB state-change history are admin-only,
 * matching the same UI-only gating already used for the Sales tab's restore
 * action.
 *
 * Restart history and the MDB log are fetched only while the sheet is open
 * (a `LaunchedEffect` scoped to this composable, backed by [DeviceHealthViewModel])
 * rather than being folded into `MachineDetailViewModel.loadMachine()`'s
 * eager-load sequence — this data has no other consumer.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceHealthSheet(
    embedded: Embedded?,
    suppressedSales: List<SuppressedSale>,
    trays: List<Tray>,
    isAdmin: Boolean,
    currencyFormat: NumberFormat,
    onDismiss: () -> Unit,
    viewModel: DeviceHealthViewModel = viewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val zone = remember { TimeZone.currentSystemDefault() }

    val now by rememberNow()

    LaunchedEffect(embedded?.id, isAdmin) {
        embedded?.id?.let { viewModel.load(it, isAdmin) }
    }
    // A status change adds a log row: reload so the bar ends in the current state.
    LaunchedEffect(embedded?.status) {
        embedded?.id?.let { viewModel.loadStatusLog(it) }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Text(
                    text = stringResource(R.string.device_health_title),
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.padding(vertical = 8.dp)
                )
            }
            item { ConnectionSection(embedded, uiState, now) }
            embedded?.mdbDiagnostics.deviceNetwork?.let { net ->
                item { NetworkSection(net, offline = embedded.connectivity(now).state == ConnectivityState.OFFLINE, now = now) }
            }
            if (isAdmin) {
                item { MdbDiagnosticsSection(embedded?.mdbDiagnostics) }
            }
            item { RestartHistorySection(uiState.restarts, uiState.isLoadingRestarts, zone) }
            if (isAdmin) {
                item { MdbHistorySection(uiState.mdbLogs, uiState.isLoadingMdbLogs, zone) }
            }
            duplicatesSection(suppressedSales, trays, zone, currencyFormat)
        }
    }
}

// ─── Network ─────────────────────────────────────────────────────────────

/** WiFi or cellular with signal, IP and when it was measured — web `ConnectivityCard.vue` "Network" column. */
@Composable
private fun NetworkSection(net: DeviceNetwork, offline: Boolean, now: Instant) {
    val weak = !offline && net.isWeak
    val kind = networkKindLabel(net.kind)
    SectionCard(title = stringResource(R.string.net_section)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(networkColor(net.tone, muted = offline).copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                SignalIcon(net.kind, net.level, net.tone, muted = offline, size = 22.dp)
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column {
                Text(
                    text = net.name ?: kind,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    text = net.quality?.let { "$kind · ${networkQualityLabel(it)}" } ?: kind,
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = if (weak) FontWeight.Medium else null,
                    color = if (weak) networkColor(net.tone) else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        Spacer(modifier = Modifier.height(8.dp))
        net.rssi?.let { ConnRow(stringResource(R.string.net_signal), "$it dBm") }
        net.mode?.let { ConnRow(stringResource(R.string.net_mode), it) }
        net.ip?.let { ConnRow(stringResource(R.string.net_ip), it) }
        net.measuredAt?.let { ConnRow(stringResource(R.string.net_measured), agoText(it, now)) }
        if (weak) {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.net_weak_hint),
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(StockOrange.copy(alpha = 0.12f))
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            )
        }
    }
}

// ─── Connection ──────────────────────────────────────────────────────────

/**
 * Status, since when, last contact and the machine's reader state, plus the
 * 24-hour bar — the counterpart of the web's `ConnectivityCard.vue` and the
 * iOS sheet's connection/history sections.
 */
@Composable
private fun ConnectionSection(embedded: Embedded?, uiState: DeviceHealthUiState, now: Instant) {
    val c = embedded.connectivity(now)
    SectionCard(title = stringResource(R.string.conn_section_connection)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusChip(connectivity = c)
        }
        Spacer(modifier = Modifier.height(4.dp))
        ConnectivityTimeLine(connectivity = c, now = now, showsReader = false)
        Spacer(modifier = Modifier.height(8.dp))

        when (c.state) {
            ConnectivityState.ONLINE -> c.onlineSince?.let {
                ConnRow(stringResource(R.string.conn_online_since), durationText(now - it))
            }
            ConnectivityState.OFFLINE -> {
                c.since?.let {
                    ConnRow(stringResource(R.string.conn_offline_since), "${clockText(it, now)} (${agoText(it, now)})")
                }
                val start = c.onlineSince
                val end = c.since
                if (start != null && end != null && end > start) {
                    ConnRow(stringResource(R.string.conn_online_before), durationText(end - start))
                }
            }
            else -> {}
        }
        if (c.state != ConnectivityState.NEVER && c.state != ConnectivityState.NONE) {
            ConnRow(
                stringResource(R.string.conn_last_contact),
                c.lastContactAt?.let { "${clockText(it, now)} (${agoText(it, now)})" } ?: "—"
            )
        }
        ConnRow(
            stringResource(R.string.conn_machine_mdb),
            c.reader?.let { readerLabel(it) } ?: stringResource(R.string.device_health_unknown)
        )
        c.reader?.let {
            Text(
                text = readerHint(it),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        val reason = embedded?.lastRestartReason
        val at = embedded?.lastRestartAt
        if (reason != null && at != null) {
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = stringResource(
                    R.string.device_health_last_restart_summary,
                    reasonLabel(reason),
                    relativeTimeAgo(at)
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        val windowStart = uiState.statusWindowStart
        if (embedded != null && windowStart != null) {
            val history = remember(uiState.statusLog, embedded.status, now) {
                StatusHistory.build(uiState.statusLog, embedded.status, windowStart, now)
            }
            Spacer(modifier = Modifier.height(12.dp))
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(
                    text = stringResource(R.string.conn_history_title),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = historyPercentLabel(history),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(modifier = Modifier.height(6.dp))
            ConnectionHistoryBar(history)
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(stringResource(R.string.conn_history_24h_ago), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(stringResource(R.string.conn_history_now), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            history.outages.forEach { o ->
                Text(
                    text = stringResource(
                        R.string.conn_history_outage,
                        clockText(o.start, now),
                        clockText(o.end, now),
                        durationText(o.end - o.start)
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = StockRed
                )
            }
        }
    }
}

@Composable
private fun ConnRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 3.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.width(12.dp))
        Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
    }
}

// ─── MDB Status (admin) ────────────────────────────────────────────────

@Composable
private fun MdbDiagnosticsSection(diagnostics: MdbDiagnostics?) {
    SectionCard(title = stringResource(R.string.device_health_section_mdb_status)) {
        if (diagnostics == null) {
            EmptyRow(stringResource(R.string.device_health_no_mdb_diagnostics))
        } else {
            DeviceInfoRow(stringResource(R.string.device_health_mdb_state), mdbStateLabel(diagnostics.state))
            diagnostics.addr?.let { DeviceInfoRow(stringResource(R.string.device_health_mdb_address), it) }
            diagnostics.vmcLevel?.let { DeviceInfoRow(stringResource(R.string.device_health_mdb_vmc_level), it.toString()) }
            DeviceInfoRow(stringResource(R.string.device_health_mdb_polls), (diagnostics.polls ?: 0).toString())
            DeviceInfoRow(stringResource(R.string.device_health_mdb_checksum_errors), (diagnostics.chkErr ?: 0).toString())
            diagnostics.lastCmd?.let { DeviceInfoRow(stringResource(R.string.device_health_mdb_last_command), it) }
            // Same "Updated …" line the web shows under its MDB grid: the
            // snapshot is a last-known state, so its age is what tells you
            // whether it still means anything.
            diagnostics.updatedAt?.let {
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = stringResource(R.string.device_health_mdb_updated, relativeTimeAgo(it)),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

// ─── Restart history ────────────────────────────────────────────────────

@Composable
private fun RestartHistorySection(restarts: List<DeviceRestart>, isLoading: Boolean, zone: TimeZone) {
    SectionCard(title = stringResource(R.string.device_health_section_restart_history)) {
        when {
            isLoading && restarts.isEmpty() -> LoadingRow()
            restarts.isEmpty() -> EmptyRow(stringResource(R.string.device_health_no_restarts))
            else -> restarts.forEach { restart -> RestartRow(restart, zone) }
        }
    }
}

@Composable
private fun RestartRow(restart: DeviceRestart, zone: TimeZone) {
    Column(modifier = Modifier.padding(vertical = 4.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                text = reasonLabel(restart.reason),
                style = MaterialTheme.typography.bodyMedium
            )
            Text(
                text = formatDateTime(restart.createdAt, zone),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        val uptime = restart.uptimeSec
        val firmware = restart.firmwareVersion
        if (uptime != null || firmware != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                uptime?.let {
                    Text(
                        text = stringResource(R.string.device_health_restart_uptime, formatUptimeSeconds(it.toLong())),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                firmware?.let {
                    Text(
                        text = "v$it",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

// ─── MDB state change history (admin) ──────────────────────────────────

@Composable
private fun MdbHistorySection(logs: List<MdbLogEntry>, isLoading: Boolean, zone: TimeZone) {
    SectionCard(title = stringResource(R.string.device_health_section_mdb_state_changes)) {
        when {
            isLoading && logs.isEmpty() -> LoadingRow()
            logs.isEmpty() -> EmptyRow(stringResource(R.string.device_health_no_state_changes))
            else -> logs.forEach { entry -> MdbLogRow(entry, zone) }
        }
    }
}

@Composable
private fun MdbLogRow(entry: MdbLogEntry, zone: TimeZone) {
    Column(modifier = Modifier.padding(vertical = 4.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            val prev = entry.prevState
            val title = if (prev != null) {
                stringResource(R.string.device_health_state_transition, mdbStateLabel(prev), mdbStateLabel(entry.state))
            } else {
                stringResource(R.string.device_health_state_initial, mdbStateLabel(entry.state))
            }
            Text(text = title, style = MaterialTheme.typography.bodyMedium)
            Text(
                text = formatTimeOnly(entry.createdAt, zone),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        val cmd = entry.lastCmd
        val polls = entry.polls
        if (cmd != null || polls != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                cmd?.let {
                    Text(
                        text = stringResource(R.string.device_health_state_cmd, it),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                polls?.let {
                    Text(
                        text = pluralStringResource(R.plurals.device_health_polls_count, it, it),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

// ─── Auto-removed duplicates (read-only here, unlike the Sales tab) ────

private fun LazyListScope.duplicatesSection(
    suppressedSales: List<SuppressedSale>,
    trays: List<Tray>,
    zone: TimeZone,
    currencyFormat: NumberFormat
) {
    item {
        Text(
            text = stringResource(R.string.device_health_section_duplicates),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold
        )
    }
    if (suppressedSales.isEmpty()) {
        item {
            Text(
                text = stringResource(R.string.device_health_no_duplicates),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    } else {
        val groups = groupSuppressedByDay(suppressedSales, zone)
        groups.forEach { group ->
            item(key = "dh-day-${group.date}") {
                Text(
                    text = dayLabel(group.date, zone),
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            items(items = group.rows, key = { "dh-sup-${it.id}" }) { sale ->
                SuppressedSaleCard(
                    sale = sale,
                    instant = Instant.parse(sale.receivedAt),
                    trays = trays,
                    zone = zone,
                    currencyFormat = currencyFormat,
                    isAdmin = false,
                    onRestoreClick = {}
                )
            }
        }
    }
    item {
        Text(
            text = stringResource(R.string.device_health_duplicates_footer),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// ─── Shared row/section building blocks ─────────────────────────────────

/**
 * Shared by every sheet in this package (also used by `MachineSettingsSheet`)
 * — kept here since `DeviceHealthSheet` (Task 27b) defined it first.
 */
@Composable
internal fun SectionCard(title: String, content: @Composable () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(text = title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = Modifier.height(8.dp))
            content()
        }
    }
}

@Composable
private fun EmptyRow(text: String) {
    Text(text = text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun LoadingRow() {
    Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(modifier = Modifier.size(24.dp))
    }
}

// ─── Labels ──────────────────────────────────────────────────────────────

/**
 * Takes the raw reason string rather than a parsed [RestartReason] so an
 * unrecognised code can be shown verbatim instead of collapsing to
 * "Unknown" — same fallback the web uses (`reasonLabel()` in
 * `useDeviceRestarts.ts`), and the only way a future firmware's new reason
 * stays diagnosable on an old app build.
 */
@Composable
private fun reasonLabel(raw: String?): String = when (parseRestartReason(raw)) {
    RestartReason.MQTT_WATCHDOG -> stringResource(R.string.device_health_reason_mqtt_watchdog)
    RestartReason.OTA_UPDATE -> stringResource(R.string.device_health_reason_ota)
    RestartReason.CONFIG_CHANGE -> stringResource(R.string.device_health_reason_config)
    RestartReason.PROVISIONING -> stringResource(R.string.device_health_reason_provisioning)
    RestartReason.FACTORY_RESET -> stringResource(R.string.device_health_reason_factory_reset)
    RestartReason.POWER_ON -> stringResource(R.string.device_health_reason_power_on)
    RestartReason.PANIC -> stringResource(R.string.device_health_reason_panic)
    RestartReason.BROWNOUT -> stringResource(R.string.device_health_reason_brownout)
    RestartReason.HW_WATCHDOG -> stringResource(R.string.device_health_reason_hw_watchdog)
    RestartReason.UNKNOWN ->
        raw?.takeIf { it.isNotBlank() && it != "unknown" }
            ?: stringResource(R.string.device_health_unknown)
}

/** `state?.capitalized ?? "Unknown"` — mirrors iOS `stateLabel(_:)` (`DeviceHealthSheet.swift` ~L299-301). */
@Composable
private fun mdbStateLabel(state: String?): String {
    if (state.isNullOrBlank()) return stringResource(R.string.device_health_unknown)
    return state.lowercase().replaceFirstChar { it.titlecase(Locale.getDefault()) }
}

/** Shared with [xyz.vmflow.ui.warehouse.WarehouseIntakeTab]'s recent-intakes row — kept internal rather than duplicated. */
@Composable
internal fun relativeTimeAgo(iso: String): String {
    val instant = runCatching { Instant.parse(iso) }.getOrNull()
        ?: return stringResource(R.string.device_health_unknown)
    val diff = (Clock.System.now() - instant)
    val minutes = diff.inWholeMinutes.coerceAtLeast(0)
    val hours = diff.inWholeHours.coerceAtLeast(0)
    val days = diff.inWholeDays.coerceAtLeast(0)
    return when {
        minutes < 1 -> stringResource(R.string.device_health_just_now)
        minutes < 60 -> pluralStringResource(R.plurals.device_health_minutes_ago, minutes.toInt(), minutes.toInt())
        hours < 24 -> pluralStringResource(R.plurals.device_health_hours_ago, hours.toInt(), hours.toInt())
        else -> pluralStringResource(R.plurals.device_health_days_ago, days.toInt(), days.toInt())
    }
}

@Composable
private fun formatDateTime(iso: String, zone: TimeZone): String {
    return try {
        val ldt = Instant.parse(iso).toLocalDateTime(zone)
        val javaDateTime = java.time.LocalDateTime.of(ldt.year, ldt.monthNumber, ldt.dayOfMonth, ldt.hour, ldt.minute, ldt.second)
        val formatter = java.time.format.DateTimeFormatter
            .ofLocalizedDateTime(java.time.format.FormatStyle.MEDIUM, java.time.format.FormatStyle.SHORT)
            .withLocale(Locale.getDefault())
        javaDateTime.format(formatter)
    } catch (_: Exception) {
        iso
    }
}

@Composable
private fun formatTimeOnly(iso: String, zone: TimeZone): String {
    return try {
        val ldt = Instant.parse(iso).toLocalDateTime(zone)
        val javaTime = java.time.LocalTime.of(ldt.hour, ldt.minute, ldt.second)
        val formatter = java.time.format.DateTimeFormatter
            .ofLocalizedTime(java.time.format.FormatStyle.SHORT)
            .withLocale(Locale.getDefault())
        javaTime.format(formatter)
    } catch (_: Exception) {
        iso
    }
}
