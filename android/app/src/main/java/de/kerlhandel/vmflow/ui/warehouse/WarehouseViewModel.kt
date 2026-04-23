package de.kerlhandel.vmflow.ui.warehouse

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.Warehouse
import de.kerlhandel.vmflow.data.model.WarehouseProductSummary
import de.kerlhandel.vmflow.data.model.WarehouseStockBatch
import de.kerlhandel.vmflow.data.repository.WarehouseRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class WarehouseUiState(
    val loading: Boolean = false,
    val warehouses: List<Warehouse> = emptyList(),
    val selectedWarehouseId: String? = null,
    val products: List<Product> = emptyList(),
    val summaries: List<WarehouseProductSummary> = emptyList(),
    val drilldownBatches: List<WarehouseStockBatch> = emptyList(),
    val drilldownProductId: String? = null,
    val search: String = "",
    val error: String? = null,
) {
    val filteredSummaries: List<WarehouseProductSummary>
        get() = if (search.isBlank()) summaries
        else summaries.filter { it.productName.lowercase().contains(search.lowercase()) }
}

@HiltViewModel
class WarehouseViewModel @Inject constructor(
    private val repo: WarehouseRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(WarehouseUiState())
    val state: StateFlow<WarehouseUiState> = _state.asStateFlow()

    fun load() {
        _state.value = _state.value.copy(loading = true, error = null)
        viewModelScope.launch {
            runCatching {
                val warehouses = repo.fetchWarehouses()
                val products = repo.fetchActiveProducts()
                Pair(warehouses, products)
            }.onSuccess { (ws, ps) ->
                val selected = _state.value.selectedWarehouseId ?: ws.firstOrNull()?.id
                _state.value = _state.value.copy(
                    warehouses = ws,
                    products = ps,
                    selectedWarehouseId = selected,
                )
                selected?.let { loadSummaries(it) } ?: run {
                    _state.value = _state.value.copy(loading = false)
                }
            }.onFailure {
                _state.value = _state.value.copy(loading = false, error = it.localizedMessage)
            }
        }
    }

    fun selectWarehouse(id: String) {
        _state.value = _state.value.copy(selectedWarehouseId = id)
        loadSummaries(id)
    }

    private fun loadSummaries(warehouseId: String) {
        viewModelScope.launch {
            runCatching { repo.fetchProductSummaries(warehouseId) }
                .onSuccess {
                    _state.value = _state.value.copy(loading = false, summaries = it)
                }
                .onFailure {
                    _state.value = _state.value.copy(loading = false, error = it.localizedMessage)
                }
        }
    }

    fun openProductDrilldown(productId: String) {
        val warehouse = _state.value.selectedWarehouseId ?: return
        _state.value = _state.value.copy(drilldownProductId = productId, drilldownBatches = emptyList())
        viewModelScope.launch {
            runCatching { repo.fetchBatchesForProduct(warehouse, productId) }
                .onSuccess { _state.value = _state.value.copy(drilldownBatches = it) }
        }
    }

    fun closeDrilldown() {
        _state.value = _state.value.copy(drilldownProductId = null, drilldownBatches = emptyList())
    }

    fun setSearch(s: String) { _state.value = _state.value.copy(search = s) }

    fun bookIntake(
        productId: String,
        quantity: Int,
        batchNumber: String?,
        expirationDate: String?,
    ) {
        val warehouseId = _state.value.selectedWarehouseId ?: return
        viewModelScope.launch {
            runCatching {
                repo.bookIntake(warehouseId, productId, quantity, batchNumber, expirationDate)
            }.onSuccess { loadSummaries(warehouseId) }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    suspend fun lookupBarcode(barcode: String): String? = repo.lookupBarcode(barcode)
}
