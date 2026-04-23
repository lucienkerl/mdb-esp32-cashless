package de.kerlhandel.vmflow.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.local.ServerStore
import de.kerlhandel.vmflow.data.model.ServerEntry
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import java.util.UUID
import javax.inject.Inject

data class ServerUiState(
    val servers: List<ServerEntry> = emptyList(),
    val selectedId: String? = null,
    val editing: ServerEntry? = null,
    val error: String? = null,
)

@HiltViewModel
class ServerViewModel @Inject constructor(
    private val serverStore: ServerStore,
    private val clientProvider: SupabaseClientProvider,
) : ViewModel() {
    private val _state = MutableStateFlow(ServerUiState())
    val state: StateFlow<ServerUiState> = _state.asStateFlow()

    init {
        combine(serverStore.allServers, serverStore.selectedServer) { all, selected ->
            _state.value = _state.value.copy(servers = all, selectedId = selected.id)
        }.launchIn(viewModelScope)
    }

    fun select(id: String) {
        viewModelScope.launch {
            serverStore.selectServer(id)
            val entry = _state.value.servers.firstOrNull { it.id == id } ?: return@launch
            clientProvider.reconfigure(entry)
        }
    }

    fun delete(id: String) {
        viewModelScope.launch { serverStore.deleteServer(id) }
    }

    fun startEdit(id: String) {
        _state.value = _state.value.copy(editing = _state.value.servers.firstOrNull { it.id == id })
    }

    fun startAdd() {
        _state.value = _state.value.copy(
            editing = ServerEntry(id = UUID.randomUUID().toString(), name = "", url = "", anonKey = ""),
        )
    }

    fun save(entry: ServerEntry) {
        viewModelScope.launch {
            if (!entry.isValid) {
                _state.value = _state.value.copy(error = "Invalid server entry")
                return@launch
            }
            val existing = _state.value.servers.firstOrNull { it.id == entry.id }
            if (existing == null) serverStore.addServer(entry) else serverStore.updateServer(entry)
            _state.value = _state.value.copy(editing = null)
        }
    }
}
