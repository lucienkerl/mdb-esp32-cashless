package de.kerlhandel.vmflow.ui.dashboard

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.realtime.RealtimeManager
import de.kerlhandel.vmflow.data.repository.AuthRepository
import de.kerlhandel.vmflow.data.repository.DashboardKpis
import de.kerlhandel.vmflow.data.repository.DashboardRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import javax.inject.Inject

data class DashboardUiState(
    val loading: Boolean = false,
    val error: String? = null,
    val kpis: DashboardKpis? = null,
    val organizationName: String? = null,
)

@HiltViewModel
class DashboardViewModel @Inject constructor(
    private val dashboardRepository: DashboardRepository,
    private val authRepository: AuthRepository,
    private val realtimeManager: RealtimeManager,
) : ViewModel() {
    private val _state = MutableStateFlow(DashboardUiState())
    val state: StateFlow<DashboardUiState> = _state.asStateFlow()

    init {
        authRepository.organization
            .onEach { _state.value = _state.value.copy(organizationName = it?.name) }
            .launchIn(viewModelScope)

        // Trigger reloads on any relevant realtime change.
        realtimeManager.versions
            .map { it.sales + it.machines + it.embedded }
            .distinctUntilChanged()
            .drop(1) // skip initial
            .onEach { load() }
            .launchIn(viewModelScope)
    }

    fun load() {
        _state.value = _state.value.copy(loading = true, error = null)
        viewModelScope.launch {
            runCatching { dashboardRepository.loadDashboard() }
                .onSuccess { _state.value = _state.value.copy(loading = false, kpis = it) }
                .onFailure { _state.value = _state.value.copy(loading = false, error = it.localizedMessage) }
        }
    }

    fun logout() {
        viewModelScope.launch { authRepository.logout() }
    }
}
