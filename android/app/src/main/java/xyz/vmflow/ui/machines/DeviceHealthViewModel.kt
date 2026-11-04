package xyz.vmflow.ui.machines

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import xyz.vmflow.data.MachineRepository
import xyz.vmflow.data.StatusLogRow
import kotlin.time.Duration.Companion.hours
import xyz.vmflow.models.DeviceRestart
import xyz.vmflow.models.MdbLogEntry

data class DeviceHealthUiState(
    val restarts: List<DeviceRestart> = emptyList(),
    val mdbLogs: List<MdbLogEntry> = emptyList(),
    val isLoadingRestarts: Boolean = false,
    val isLoadingMdbLogs: Boolean = false,
    /** Status changes of the last 24 hours, oldest first (for the history bar). */
    val statusLog: List<StatusLogRow> = emptyList(),
    /** Start of the window [statusLog] covers; null until loaded. */
    val statusWindowStart: Instant? = null,
    val error: String? = null
)

/**
 * Sheet-local state for [DeviceHealthSheet] — deliberately not folded into
 * `MachineDetailViewModel`: restart history and the MDB state-change log are
 * only needed while the sheet is open, mirroring iOS's `.task` on the sheet
 * itself (`DeviceHealthSheet.swift` ~L40-48) rather than on the whole screen.
 */
class DeviceHealthViewModel : ViewModel() {
    private val _uiState = MutableStateFlow(DeviceHealthUiState())
    val uiState: StateFlow<DeviceHealthUiState> = _uiState.asStateFlow()

    /**
     * Loads restart history for every role, and the MDB state-change log
     * only for admins — both fetches run concurrently (separate coroutines),
     * same as iOS's `async let` pair. The caller's `LaunchedEffect` re-runs
     * this once per sheet open (mirrors iOS's `.task`, which re-fires on
     * every appearance), so fresh data replaces whatever the sheet showed
     * last time it was open.
     */
    fun load(embeddedId: String, isAdmin: Boolean) {
        loadStatusLog(embeddedId)

        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingRestarts = true, error = null) }
            MachineRepository.fetchDeviceRestarts(embeddedId).fold(
                onSuccess = { restarts -> _uiState.update { it.copy(restarts = restarts, isLoadingRestarts = false) } },
                onFailure = { e -> _uiState.update { it.copy(isLoadingRestarts = false, error = e.message) } }
            )
        }

        if (isAdmin) {
            viewModelScope.launch {
                _uiState.update { it.copy(isLoadingMdbLogs = true, error = null) }
                MachineRepository.fetchMdbLog(embeddedId).fold(
                    onSuccess = { logs -> _uiState.update { it.copy(mdbLogs = logs, isLoadingMdbLogs = false) } },
                    onFailure = { e -> _uiState.update { it.copy(isLoadingMdbLogs = false, error = e.message) } }
                )
            }
        }
    }

    /** Reloaded whenever the device's status changes, so the bar ends in the current state. */
    fun loadStatusLog(embeddedId: String) {
        viewModelScope.launch {
            val windowStart = Clock.System.now() - 24.hours
            MachineRepository.fetchStatusLog(embeddedId, windowStart.toString()).onSuccess { rows ->
                _uiState.update { it.copy(statusLog = rows, statusWindowStart = windowStart) }
            }
        }
    }
}
