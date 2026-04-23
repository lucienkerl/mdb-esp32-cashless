package de.kerlhandel.vmflow.ui.products

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.model.Product
import de.kerlhandel.vmflow.data.model.ProductCategory
import de.kerlhandel.vmflow.data.repository.ProductRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ProductsUiState(
    val loading: Boolean = false,
    val products: List<Product> = emptyList(),
    val categories: List<ProductCategory> = emptyList(),
    val search: String = "",
    val showDiscontinued: Boolean = true,
    val error: String? = null,
) {
    val filtered: List<Product>
        get() = products
            .filter { showDiscontinued || it.discontinued != true }
            .filter {
                search.isBlank() || (it.name ?: "").lowercase().contains(search.lowercase())
            }
}

@HiltViewModel
class ProductsViewModel @Inject constructor(
    private val repo: ProductRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(ProductsUiState())
    val state: StateFlow<ProductsUiState> = _state.asStateFlow()

    fun load() {
        _state.value = _state.value.copy(loading = true, error = null)
        viewModelScope.launch {
            runCatching {
                val products = repo.fetchProducts()
                val categories = repo.fetchCategories()
                products to categories
            }.onSuccess { (products, categories) ->
                _state.value = _state.value.copy(
                    loading = false,
                    products = products,
                    categories = categories,
                )
            }.onFailure {
                _state.value = _state.value.copy(loading = false, error = it.localizedMessage)
            }
        }
    }

    fun setSearch(v: String) { _state.value = _state.value.copy(search = v) }
    fun toggleDiscontinued() {
        _state.value = _state.value.copy(showDiscontinued = !_state.value.showDiscontinued)
    }

    fun saveProduct(
        id: String?,
        name: String,
        sellprice: Double?,
        categoryId: String?,
        discontinued: Boolean,
    ) {
        viewModelScope.launch {
            runCatching {
                if (id == null) repo.createProduct(name, sellprice, categoryId, discontinued)
                else repo.updateProduct(id, name, sellprice, categoryId, discontinued)
            }.onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    fun deleteProduct(id: String) {
        viewModelScope.launch {
            runCatching { repo.deleteProduct(id) }
                .onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    fun createCategory(name: String) {
        viewModelScope.launch {
            runCatching { repo.createCategory(name) }
                .onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    fun updateCategory(id: String, name: String) {
        viewModelScope.launch {
            runCatching { repo.updateCategory(id, name) }
                .onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }

    fun deleteCategory(id: String) {
        viewModelScope.launch {
            runCatching { repo.deleteCategory(id) }
                .onSuccess { load() }
                .onFailure { _state.value = _state.value.copy(error = it.localizedMessage) }
        }
    }
}
