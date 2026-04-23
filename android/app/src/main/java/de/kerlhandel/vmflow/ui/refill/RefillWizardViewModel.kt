package de.kerlhandel.vmflow.ui.refill

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.model.RefillMachine
import de.kerlhandel.vmflow.data.model.RefillStep
import de.kerlhandel.vmflow.data.model.RefillTray
import de.kerlhandel.vmflow.data.model.Tray
import de.kerlhandel.vmflow.data.model.TourLogEntry
import de.kerlhandel.vmflow.data.repository.RefillRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Simpler Android-seitiger Refill-Wizard ohne den kompletten iOS-Packing-State:
 *
 *  1. **Pack** — Alle Maschinen mit Deficits zeigen; jede Maschine wird per
 *     Checkbox in die Tour aufgenommen. (Kein Produkt-zentrischer Pick-Modus
 *     wie iOS — das folgt in einer späteren Iteration.)
 *  2. **Refill** — Pro angehakter Maschine: Fill-Amount je Tray anpassen und
 *     bestätigen → stock_update.
 *  3. **Summary** — Tour-Log zeigt was nachgefüllt wurde.
 */
data class RefillUiState(
    val loading: Boolean = false,
    val step: RefillStep = RefillStep.Packing,
    val machines: List<RefillMachine> = emptyList(),
    val currentMachineIndex: Int = 0,
    val tourLog: List<TourLogEntry> = emptyList(),
    val error: String? = null,
) {
    val packed: List<RefillMachine> get() = machines.filter { it.isPacked }
    val remaining: List<RefillMachine>
        get() = machines.filter { it.isPacked && !it.isRefilled && !it.isSkipped }
    val currentMachine: RefillMachine? get() = remaining.getOrNull(currentMachineIndex)

    val itemsTotal: Int get() = packed.sumOf { it.totalDeficit }
    val machinesVisited: Int get() = tourLog.count { !it.skipped }
    val traysRefilled: Int get() = tourLog.sumOf { it.traysRefilled }
    val itemsAdded: Int get() = tourLog.sumOf { it.totalAdded }
    val machinesSkipped: Int get() = tourLog.count { it.skipped }
}

@HiltViewModel
class RefillWizardViewModel @Inject constructor(
    private val repo: RefillRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(RefillUiState())
    val state: StateFlow<RefillUiState> = _state.asStateFlow()

    fun load() {
        _state.value = _state.value.copy(loading = true, error = null)
        viewModelScope.launch {
            runCatching { repo.loadAll() }
                .onSuccess { data ->
                    _state.value = _state.value.copy(
                        loading = false,
                        machines = buildRefillMachines(data.machines, data.trays),
                    )
                }
                .onFailure {
                    _state.value = _state.value.copy(loading = false, error = it.localizedMessage)
                }
        }
    }

    private fun buildRefillMachines(
        machines: List<de.kerlhandel.vmflow.data.model.VendingMachine>,
        trays: List<Tray>,
    ): List<RefillMachine> {
        val traysByMachine = trays.groupBy { it.machineId }
        val refill = mutableListOf<RefillMachine>()
        for (machine in machines) {
            val machineTrays = traysByMachine[machine.id].orEmpty()
            val hasEmptyOrLow = machineTrays.any { it.isEmpty || it.isBelowMinStock }
            if (!hasEmptyOrLow) continue

            val refillTrays = machineTrays.mapNotNull { tray ->
                val deficit = tray.deficit
                if (deficit <= 0) return@mapNotNull null
                val critOrLow = tray.isEmpty || tray.isBelowMinStock
                val belowFill = tray.isBelowFillThreshold
                if (!critOrLow && !belowFill) return@mapNotNull null
                RefillTray(tray = tray, fillAmount = deficit)
            }
            if (refillTrays.isEmpty()) continue
            refill.add(RefillMachine(machine = machine, trays = refillTrays))
        }
        // Sort by empty-trays count desc, then total deficit desc
        return refill.sortedWith(
            compareByDescending<RefillMachine> { it.trays.count { t -> t.tray.isEmpty } }
                .thenByDescending { it.totalDeficit },
        )
    }

    fun togglePacked(machineId: String) {
        _state.value = _state.value.copy(
            machines = _state.value.machines.map {
                if (it.machine.id == machineId) it.copy(isPacked = !it.isPacked) else it
            },
        )
    }

    fun packAll() {
        _state.value = _state.value.copy(
            machines = _state.value.machines.map { it.copy(isPacked = true) },
        )
    }

    fun startTour() {
        if (_state.value.packed.isEmpty()) return
        _state.value = _state.value.copy(step = RefillStep.Refill, currentMachineIndex = 0)
    }

    fun adjustFillAmount(machineId: String, trayId: String, amount: Int) {
        _state.value = _state.value.copy(
            machines = _state.value.machines.map { m ->
                if (m.machine.id != machineId) m else {
                    m.copy(
                        trays = m.trays.map { t ->
                            if (t.id != trayId) t else {
                                val maxFill = t.tray.capacity - t.tray.currentStock
                                t.copy(fillAmount = amount.coerceIn(0, maxFill))
                            }
                        },
                    )
                }
            },
        )
    }

    fun fillAllTraysToCapacity(machineId: String) {
        _state.value = _state.value.copy(
            machines = _state.value.machines.map { m ->
                if (m.machine.id != machineId) m else {
                    m.copy(
                        trays = m.trays.map { t ->
                            t.copy(fillAmount = t.tray.capacity - t.tray.currentStock)
                        },
                    )
                }
            },
        )
    }

    fun confirmCurrentMachine() {
        val current = _state.value.currentMachine ?: return
        viewModelScope.launch {
            var itemsAdded = 0
            var traysRefilled = 0
            current.trays.filter { it.fillAmount > 0 }.forEach { tray ->
                val newStock = (tray.tray.currentStock + tray.fillAmount)
                    .coerceAtMost(tray.tray.capacity)
                if (newStock > tray.tray.currentStock) {
                    runCatching { repo.updateTrayStock(tray.tray.id, newStock) }
                    itemsAdded += (newStock - tray.tray.currentStock)
                    traysRefilled += 1
                }
            }
            markMachineDone(
                current = current,
                entry = TourLogEntry(
                    machineId = current.machine.id,
                    machineName = current.machine.displayName,
                    traysRefilled = traysRefilled,
                    totalAdded = itemsAdded,
                    skipped = false,
                ),
                markSkipped = false,
            )
        }
    }

    fun skipCurrentMachine() {
        val current = _state.value.currentMachine ?: return
        markMachineDone(
            current = current,
            entry = TourLogEntry(
                machineId = current.machine.id,
                machineName = current.machine.displayName,
                traysRefilled = 0,
                totalAdded = 0,
                skipped = true,
            ),
            markSkipped = true,
        )
    }

    private fun markMachineDone(
        current: RefillMachine,
        entry: TourLogEntry,
        markSkipped: Boolean,
    ) {
        val updated = _state.value.machines.map {
            if (it.machine.id == current.machine.id)
                if (markSkipped) it.copy(isSkipped = true) else it.copy(isRefilled = true)
            else it
        }
        val newLog = _state.value.tourLog + entry
        val remaining = updated.filter { it.isPacked && !it.isRefilled && !it.isSkipped }
        val nextStep = if (remaining.isEmpty()) RefillStep.Summary else RefillStep.Refill
        _state.value = _state.value.copy(
            machines = updated,
            tourLog = newLog,
            step = nextStep,
            currentMachineIndex = 0,
        )
    }

    fun reset() {
        _state.value = RefillUiState()
        load()
    }
}
