package de.kerlhandel.vmflow.ui.machines

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.model.MachineStats
import de.kerlhandel.vmflow.data.realtime.RealtimeManager
import de.kerlhandel.vmflow.data.repository.MachineRepository
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

data class MachineListState(
    val loading: Boolean = false,
    val error: String? = null,
    val machines: List<MachineStats> = emptyList(),
    val search: String = "",
) {
    val filtered: List<MachineStats>
        get() = if (search.isBlank()) machines else machines.filter {
            it.machine.displayName.lowercase().contains(search.lowercase())
        }
}

@HiltViewModel
class MachineListViewModel @Inject constructor(
    private val machineRepository: MachineRepository,
    private val realtimeManager: RealtimeManager,
) : ViewModel() {
    private val _state = MutableStateFlow(MachineListState())
    val state: StateFlow<MachineListState> = _state.asStateFlow()

    init {
        realtimeManager.versions
            .map { it.combined }
            .distinctUntilChanged()
            .drop(1)
            .onEach { load() }
            .launchIn(viewModelScope)
    }

    fun load() {
        _state.value = _state.value.copy(loading = true, error = null)
        viewModelScope.launch {
            runCatching { machineRepository.fetchMachinesWithStats() }
                .onSuccess { _state.value = _state.value.copy(loading = false, machines = it) }
                .onFailure { _state.value = _state.value.copy(loading = false, error = it.localizedMessage) }
        }
    }

    fun setSearch(q: String) { _state.value = _state.value.copy(search = q) }
}
