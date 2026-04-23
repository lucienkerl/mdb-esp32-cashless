package de.kerlhandel.vmflow.ui.deals

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.model.Deal
import de.kerlhandel.vmflow.data.repository.DealRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

enum class DealGroupMode { Retailer, Product }

data class DealsUiState(
    val loading: Boolean = false,
    val enabled: Boolean = false,
    val zipCode: String = "",
    val deals: List<Deal> = emptyList(),
    val group: DealGroupMode = DealGroupMode.Retailer,
    val search: String = "",
    val fromCache: Boolean = false,
    val error: String? = null,
)

@HiltViewModel
class DealsViewModel @Inject constructor(
    private val repo: DealRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(DealsUiState())
    val state: StateFlow<DealsUiState> = _state.asStateFlow()

    fun load() {
        _state.value = _state.value.copy(loading = true, error = null)
        viewModelScope.launch {
            runCatching { repo.fetchSettings() }
                .onSuccess { s ->
                    _state.value = _state.value.copy(
                        enabled = s.dealsEnabled == true,
                        zipCode = s.dealsZipCode ?: "",
                    )
                    if (s.dealsEnabled == true) fetchDeals()
                    else _state.value = _state.value.copy(loading = false)
                }
                .onFailure {
                    _state.value = _state.value.copy(loading = false, error = it.localizedMessage)
                }
        }
    }

    fun fetchDeals(forceRefresh: Boolean = false) {
        _state.value = _state.value.copy(loading = true)
        viewModelScope.launch {
            runCatching { repo.searchDeals(forceRefresh) }
                .onSuccess { r ->
                    _state.value = _state.value.copy(
                        loading = false,
                        deals = r.deals,
                        fromCache = r.fromCache,
                    )
                }
                .onFailure {
                    _state.value = _state.value.copy(loading = false, error = it.localizedMessage)
                }
        }
    }

    fun setEnabled(enabled: Boolean) {
        _state.value = _state.value.copy(enabled = enabled)
        viewModelScope.launch {
            runCatching { repo.saveSettings(enabled, _state.value.zipCode) }
                .onSuccess { if (enabled) fetchDeals() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    fun setZip(zip: String) { _state.value = _state.value.copy(zipCode = zip) }
    fun saveZip() {
        viewModelScope.launch {
            runCatching { repo.saveSettings(_state.value.enabled, _state.value.zipCode) }
        }
    }

    fun setGroup(group: DealGroupMode) { _state.value = _state.value.copy(group = group) }
    fun setSearch(q: String) { _state.value = _state.value.copy(search = q) }
}
