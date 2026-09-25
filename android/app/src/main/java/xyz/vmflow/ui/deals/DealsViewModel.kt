package xyz.vmflow.ui.deals

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import kotlinx.datetime.LocalDate
import kotlinx.datetime.TimeZone
import kotlinx.datetime.todayIn
import xyz.vmflow.data.DealEk
import xyz.vmflow.data.DealGroup
import xyz.vmflow.data.DealGroupMode
import xyz.vmflow.data.DealListMode
import xyz.vmflow.data.DealStockTotals
import xyz.vmflow.data.DealUserState
import xyz.vmflow.data.DealValidityLogic
import xyz.vmflow.data.DealValidityStatus
import xyz.vmflow.data.DealsDataSource
import xyz.vmflow.data.DealsLogic
import xyz.vmflow.data.DealsRepository
import xyz.vmflow.data.DedupedDeal
import xyz.vmflow.models.Deal
import xyz.vmflow.models.ProductPurchaseSummary

/** Message the backend returns when no deal-source provider is active (same check as the web). */
private const val NO_PROVIDERS_MESSAGE = "No deal-source providers enabled"

data class DealsUiState(
    val settingsLoading: Boolean = true,
    val dealsEnabled: Boolean = false,
    val isLoading: Boolean = false,
    val isRefreshing: Boolean = false,
    val error: String? = null,
    val fromCache: Boolean = false,
    val noProviders: Boolean = false,
    val deals: List<Deal> = emptyList(),
    val userStates: Map<String, DealUserState> = emptyMap(),
    val newDealKeys: Set<String> = emptySet(),
    val ekSummaries: Map<String, ProductPurchaseSummary> = emptyMap(),
    val stock: Map<String, DealStockTotals> = emptyMap(),
    val searchText: String = "",
    /** Validity first so "can I buy this today?" is answered before anything else. */
    val groupMode: DealGroupMode = DealGroupMode.VALIDITY,
    val listMode: DealListMode = DealListMode.ACTIVE,
    val today: LocalDate = LocalDate(1970, 1, 1),
) {
    // Derived once per state instance (not per recomposition).
    val deduped: List<DedupedDeal> = DealsLogic.dedupe(deals, userStates, today)
    private val ekByKey: Map<String, DealEk> = deduped.associate { it.key to DealsLogic.dealEk(it, ekSummaries) }
    private val active: List<DedupedDeal> = DealsLogic.activeDeals(deduped)

    val archivedDeals: List<DedupedDeal> = DealsLogic.archivedDeals(deduped)
    val visibleActiveDeals: List<DedupedDeal> = active.filter { ekByKey[it.key]?.suppressed != true }
    /** Cards hidden because every matched product's EK makes the offer implausible. */
    val suppressedActiveDeals: List<DedupedDeal> = active.filter { ekByKey[it.key]?.suppressed == true }

    val filteredDeals: List<DedupedDeal> =
        (if (listMode == DealListMode.ARCHIVED) archivedDeals else visibleActiveDeals)
            .filter { DealsLogic.matchesSearch(it, searchText) }

    val groups: List<DealGroup> = DealsLogic.group(filteredDeals, groupMode, listMode, today)

    val archivedCount: Int get() = archivedDeals.size
    val avgDiscount: Int get() = DealsLogic.avgDiscount(filteredDeals)
    val upcomingCount: Int
        get() = visibleActiveDeals.count {
            DealValidityLogic.validity(it.primary, today).status == DealValidityStatus.UPCOMING
        }

    fun ek(deal: DedupedDeal): DealEk = ekByKey[deal.key] ?: DealsLogic.dealEk(deal, ekSummaries)

    /** NEW until pinned or archived — clears optimistically on either. */
    fun isNew(deal: DedupedDeal): Boolean = deal.key in newDealKeys && !deal.archived && !deal.pinned

    /** Live copy of [deal] (pin/archive state changes while its detail sheet is open). */
    fun live(deal: DedupedDeal): DedupedDeal = deduped.firstOrNull { it.key == deal.key } ?: deal
}

/**
 * State + effects for the Deals screen, free of Android types so it runs in a
 * plain JVM test. Mirrors iOS `DealsViewModel`.
 */
internal class DealsEngine(
    private val repository: DealsDataSource,
    private val today: () -> LocalDate = { Clock.System.todayIn(TimeZone.currentSystemDefault()) },
    private val now: () -> String = { Clock.System.now().toString() },
) {
    private val _uiState = MutableStateFlow(DealsUiState(today = today()))
    val uiState: StateFlow<DealsUiState> = _uiState.asStateFlow()

    suspend fun loadAll() {
        _uiState.update { it.copy(settingsLoading = true, today = today()) }
        val enabled = try {
            repository.fetchDealsEnabled()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _uiState.update { it.copy(error = e.message) }
            false
        }
        _uiState.update { it.copy(settingsLoading = false, dealsEnabled = enabled) }
        if (enabled) loadDeals(forceRefresh = false)
    }

    /** Pull-to-refresh: forces a fresh provider fetch, like the iOS refresh button. */
    suspend fun refresh() {
        _uiState.update { it.copy(isRefreshing = true) }
        try {
            loadDeals(forceRefresh = true)
        } finally {
            _uiState.update { it.copy(isRefreshing = false) }
        }
    }

    private suspend fun loadDeals(forceRefresh: Boolean) {
        _uiState.update { it.copy(isLoading = true, error = null, today = today()) }
        // User state and NEW keys are best-effort: a backend without those
        // migrations must still show the list (same as iOS).
        val states = bestEffort { repository.fetchUserStates() }
        try {
            val response = repository.searchDeals(forceRefresh)
            _uiState.update {
                it.copy(
                    deals = response.deals,
                    fromCache = response.fromCache,
                    noProviders = response.message == NO_PROVIDERS_MESSAGE,
                    userStates = states ?: it.userStates,
                )
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _uiState.update { it.copy(error = e.message, userStates = states ?: it.userStates) }
        } finally {
            _uiState.update { it.copy(isLoading = false) }
        }
        bestEffort { repository.fetchNewDealKeys() }?.let { keys -> _uiState.update { it.copy(newDealKeys = keys) } }
        val ids = DealsLogic.rawProductIds(_uiState.value.deals)
        bestEffort { repository.fetchPurchaseSummaries(ids) }?.let { s -> _uiState.update { it.copy(ekSummaries = s) } }
    }

    fun setSearchText(text: String) = _uiState.update { it.copy(searchText = text) }
    fun setGroupMode(mode: DealGroupMode) = _uiState.update { it.copy(groupMode = mode) }
    fun setListMode(mode: DealListMode) = _uiState.update { it.copy(listMode = mode) }
    fun clearError() = _uiState.update { it.copy(error = null) }

    suspend fun archive(deal: DedupedDeal) = applyUserState(deal, archivedAt = now(), pinnedAt = current(deal)?.pinnedAt)
    suspend fun unarchive(deal: DedupedDeal) = applyUserState(deal, archivedAt = null, pinnedAt = current(deal)?.pinnedAt)
    suspend fun pin(deal: DedupedDeal) = applyUserState(deal, archivedAt = current(deal)?.archivedAt, pinnedAt = now())
    suspend fun unpin(deal: DedupedDeal) = applyUserState(deal, archivedAt = current(deal)?.archivedAt, pinnedAt = null)

    private fun current(deal: DedupedDeal): DealUserState? = _uiState.value.userStates[deal.key]

    /**
     * Full-row semantics: the caller passes the final value of both columns,
     * so toggling one never clobbers the other. Optimistic, rolled back on failure.
     */
    private suspend fun applyUserState(deal: DedupedDeal, archivedAt: String?, pinnedAt: String?) {
        val key = deal.key
        val previous = _uiState.value.userStates[key]
        _uiState.update { it.copy(userStates = it.userStates + (key to DealUserState(archivedAt, pinnedAt))) }
        try {
            repository.upsertUserState(deal.retailer, deal.offerId, archivedAt, pinnedAt)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _uiState.update {
                val rolledBack = if (previous == null) it.userStates - key else it.userStates + (key to previous)
                it.copy(userStates = rolledBack, error = e.message)
            }
        }
    }

    /** Loads stock totals for products not loaded yet (detail sheet). */
    suspend fun loadStock(productIds: List<String>) {
        val missing = productIds.filter { it !in _uiState.value.stock }
        if (missing.isEmpty()) return
        val totals = bestEffort { repository.fetchStockTotals(missing) } ?: return
        _uiState.update { it.copy(stock = it.stock + totals) }
    }

    private suspend fun <T> bestEffort(block: suspend () -> T): T? =
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        }
}

class DealsViewModel @JvmOverloads constructor(
    repository: DealsDataSource = DealsRepository,
) : ViewModel() {
    private val engine = DealsEngine(repository)
    val uiState: StateFlow<DealsUiState> = engine.uiState

    init {
        viewModelScope.launch { engine.loadAll() }
    }

    fun refresh() { viewModelScope.launch { engine.refresh() } }
    fun setSearchText(text: String) = engine.setSearchText(text)
    fun setGroupMode(mode: DealGroupMode) = engine.setGroupMode(mode)
    fun setListMode(mode: DealListMode) = engine.setListMode(mode)
    fun clearError() = engine.clearError()
    fun archive(deal: DedupedDeal) { viewModelScope.launch { engine.archive(deal) } }
    fun unarchive(deal: DedupedDeal) { viewModelScope.launch { engine.unarchive(deal) } }
    fun pin(deal: DedupedDeal) { viewModelScope.launch { engine.pin(deal) } }
    fun unpin(deal: DedupedDeal) { viewModelScope.launch { engine.unpin(deal) } }
    fun loadStock(productIds: List<String>) { viewModelScope.launch { engine.loadStock(productIds) } }
}
