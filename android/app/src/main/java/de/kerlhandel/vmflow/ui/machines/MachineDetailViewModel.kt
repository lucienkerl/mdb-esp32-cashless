package de.kerlhandel.vmflow.ui.machines

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.navigation.toRoute
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.Sale
import de.kerlhandel.vmflow.data.model.Tray
import de.kerlhandel.vmflow.data.model.TrayUpsert
import de.kerlhandel.vmflow.data.model.VendingMachine
import de.kerlhandel.vmflow.data.realtime.RealtimeManager
import de.kerlhandel.vmflow.data.repository.MachineRepository
import de.kerlhandel.vmflow.data.repository.TrayRepository
import de.kerlhandel.vmflow.ui.navigation.MachineDetailRoute
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

data class MachineDetailState(
    val loading: Boolean = false,
    val machine: VendingMachine? = null,
    val trays: List<Tray> = emptyList(),
    val sales: List<Sale> = emptyList(),
    val products: List<Product> = emptyList(),
    val error: String? = null,
)

@HiltViewModel
class MachineDetailViewModel @Inject constructor(
    savedState: SavedStateHandle,
    private val machineRepository: MachineRepository,
    private val trayRepository: TrayRepository,
    private val realtimeManager: RealtimeManager,
) : ViewModel() {
    private val machineId: String = try {
        // Nav-Compose 2.8 type-safe route
        savedState.toRoute<MachineDetailRoute>().machineId
    } catch (_: Throwable) {
        savedState.get<String>("machineId") ?: error("missing machineId arg")
    }

    private val _state = MutableStateFlow(MachineDetailState())
    val state: StateFlow<MachineDetailState> = _state.asStateFlow()

    init {
        realtimeManager.versions
            .map { it.sales + it.trays + it.machines }
            .distinctUntilChanged()
            .drop(1)
            .onEach { load() }
            .launchIn(viewModelScope)
    }

    fun load() {
        _state.value = _state.value.copy(loading = true, error = null)
        viewModelScope.launch {
            runCatching {
                val machine = machineRepository.fetchMachine(machineId)
                val trays = trayRepository.fetchTrays(machineId)
                val sales = machineRepository.fetchSalesForMachine(machineId)
                val products = trayRepository.fetchActiveProducts()
                Loaded(machine, trays, sales, products)
            }.onSuccess { l ->
                _state.value = _state.value.copy(
                    loading = false,
                    machine = l.machine,
                    trays = l.trays,
                    sales = l.sales,
                    products = l.products,
                )
            }.onFailure {
                _state.value = _state.value.copy(loading = false, error = it.localizedMessage)
            }
        }
    }

    private data class Loaded(
        val machine: VendingMachine?,
        val trays: List<Tray>,
        val sales: List<Sale>,
        val products: List<Product>,
    )

    fun saveTray(payload: TrayUpsert, existingId: String?) {
        viewModelScope.launch {
            runCatching {
                if (existingId == null) trayRepository.createTray(payload)
                else trayRepository.updateTray(existingId, payload)
            }.onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    fun batchAddTrays(startSlot: Int, count: Int, capacity: Int) {
        viewModelScope.launch {
            runCatching { trayRepository.batchCreateTrays(machineId, startSlot, count, capacity) }
                .onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    fun deleteTray(trayId: String) {
        viewModelScope.launch {
            runCatching { trayRepository.deleteTray(trayId) }
                .onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    fun adjustStock(trayId: String, delta: Int) {
        val tray = _state.value.trays.firstOrNull { it.id == trayId } ?: return
        val newStock = (tray.currentStock + delta).coerceIn(0, tray.capacity)
        if (newStock == tray.currentStock) return
        viewModelScope.launch {
            runCatching { trayRepository.updateStock(trayId, newStock) }.onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    fun fillTray(trayId: String) {
        val tray = _state.value.trays.firstOrNull { it.id == trayId } ?: return
        if (tray.currentStock == tray.capacity) return
        viewModelScope.launch {
            runCatching { trayRepository.updateStock(trayId, tray.capacity) }.onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }
}
