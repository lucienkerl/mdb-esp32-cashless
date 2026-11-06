package xyz.vmflow.ui.dashboard

import xyz.vmflow.data.connectivity

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.minus
import kotlinx.datetime.toLocalDateTime
import xyz.vmflow.data.ActivityFeedBuilder
import xyz.vmflow.data.AuthRepository
import xyz.vmflow.data.CashBookSummary
import xyz.vmflow.data.DailySales
import xyz.vmflow.data.DashboardDataSource
import xyz.vmflow.data.DashboardKpis
import xyz.vmflow.data.DashboardRepository
import xyz.vmflow.data.MachineRepository
import xyz.vmflow.data.SalesKpis
import xyz.vmflow.models.ActivityFeedItem
import xyz.vmflow.models.MachineWithStats
import xyz.vmflow.models.Organization
import xyz.vmflow.models.Sale

/**
 * Activity window progression: 0 (today only) -> 6 -> 13 -> 20 -> ... The
 * first expansion adds 6 days (today -> last 7 days), every later one adds
 * 7. Pure so the load-more state machine is unit-testable without a fake
 * network. Mirrors `loadMoreRecentActivity()` in
 * `ios/VMflow/ViewModels/DashboardViewModel.swift` (Z. 452-489).
 */
fun nextDaysBack(current: Int): Int = if (current == 0) 6 else current + 7

data class DashboardUiState(
    // false, not true: mirrors iOS's `@Published var isLoading = false`.
    // loadDashboard() flips this true itself once it actually starts: with
    // a true default here, the load-more guard below (`!state.isLoading`)
    // would block every call made before the first loadDashboard() — which
    // is also exactly the state DashboardEngine starts in when driven
    // directly from a test.
    val isLoading: Boolean = false,
    val isRefreshing: Boolean = false,
    val organization: Organization? = null,
    val role: String? = null,
    val machines: List<MachineWithStats> = emptyList(),
    val recentSales: List<Sale> = emptyList(),
    val error: String? = null,

    // Dashboard depth (phase 2): KPIs, 30-day chart, merged activity feed.
    val kpis: SalesKpis = SalesKpis(),
    val dailySales: List<DailySales> = emptyList(),
    val activity: List<ActivityFeedItem> = emptyList(),
    /** Days back from start-of-today the activity window currently covers. */
    val activityDaysBack: Int = 0,
    /** False once widening the window brought no additional raw source rows. */
    val hasMoreActivity: Boolean = true,
    /** Drives the feed's bottom-sentinel spinner. */
    val isLoadingMoreActivity: Boolean = false,
    /** True after a real (non-cancellation) load-more failure; UI should offer manual retry. */
    val loadMoreFailed: Boolean = false,
    val newDealsCount: Int = 0,
    /** Machines with >=1 refillable product sold out in every slot ([xyz.vmflow.data.StockHealth.buckets]). */
    val stockCriticalCount: Int = 0,
    /** Machines with >=1 refillable product at/under its summed min_stock, that aren't already critical. */
    val stockLowCount: Int = 0,
    /** Dashboard cash-book (Barkasse) summary tile. */
    val cashBookSummary: CashBookSummary = CashBookSummary(hasCashBook = false),
) {
    val todayRevenue: Double get() = machines.sumOf { it.todayRevenue }
    val todaySalesCount: Int get() = machines.sumOf { it.todaySalesCount }
    /** Online / no response / offline over the whole fleet ([xyz.vmflow.data.DeviceConnectivity]). */
    val fleet: xyz.vmflow.data.FleetConnectivity
        get() = xyz.vmflow.data.FleetConnectivity.of(machines.map { it.machine.connectivity() })
    val machinesOnline: Int get() = fleet.online
    /** Machines that have a device: one without a device is not "offline". */
    val totalMachines: Int get() = fleet.devices
    val stockAlerts: Int get() = machines.count {
        it.stockHealth != MachineWithStats.StockHealth.OK
    }
}

/**
 * Dashboard state machine: KPI/chart/activity loading plus infinite-scroll
 * expansion of the activity window. Deliberately independent of
 * [androidx.lifecycle.ViewModel]/`viewModelScope` so it is unit-testable
 * with plain JUnit + `runBlocking` — touching `viewModelScope` in a JVM test
 * crashes on the missing `Dispatchers.Main`, and this project has neither
 * Robolectric nor `kotlinx-coroutines-test` to work around that. Tests
 * substitute a fake [DashboardDataSource]; see `DashboardLoadMoreTest`.
 */
internal class DashboardEngine(private val repository: DashboardDataSource) {
    private val _uiState = MutableStateFlow(DashboardUiState())
    val uiState: StateFlow<DashboardUiState> = _uiState.asStateFlow()

    /** user_id -> display name cache for intake attribution. Mirrors iOS's `userNameCache`. */
    private val userNameCache = mutableMapOf<String, String>()
    /** Product names for slot change feed rows, keyed by lowercased product id. */
    private val productNameCache = mutableMapOf<String, String>()

    /**
     * Raw source-row count (sales + activity rows + intake transactions) of
     * the last activity load. Exhaustion compares RAW rows, not merged
     * items: new transactions merging into an existing intake group leave
     * the merged count unchanged and would falsely signal "no more history".
     */
    private var rawSourceRowCount = 0

    // MARK: - Load all

    suspend fun loadDashboard() {
        _uiState.update { it.copy(isLoading = true, error = null) }
        try {
            coroutineScope {
                launch { loadIsolated { loadOrganization() } }
                launch { loadIsolated { loadLegacyMachinesAndSales() } }
                launch { loadIsolated { loadStockHealth() } }
                launch { loadIsolated { loadSalesKpisAndChart() } }
                launch { loadIsolated { loadRecentActivity() } }
                launch { loadIsolated { loadNewDealsCount() } }
                launch { loadIsolated { loadCashBookSummary() } }
            }
        } finally {
            _uiState.update { it.copy(isLoading = false) }
        }
    }

    /**
     * Runs one dashboard sub-fetch and isolates its failure from its
     * siblings. [loadDashboard] launches seven of these as sibling
     * coroutines under one `coroutineScope` — without this wrapper, an
     * uncaught exception in ANY of them (structured concurrency) cancels
     * every other in-flight `launch`, so one broken widget (e.g. a
     * `products(...)` select missing a required column) blanks the entire
     * dashboard — KPIs, chart and activity that fetched fine included —
     * instead of just leaving its own section empty. `CancellationException`
     * is rethrown so cooperative cancellation (e.g. leaving the screen)
     * still works normally; only genuine failures are swallowed here.
     */
    internal suspend fun loadIsolated(block: suspend () -> Unit) {
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _uiState.update { it.copy(error = it.error ?: e.message) }
        }
    }

    suspend fun refresh() {
        _uiState.update { it.copy(isRefreshing = true) }
        loadDashboard()
        _uiState.update { it.copy(isRefreshing = false) }
    }

    // MARK: - Legacy (pre-existing, not part of the iOS-mirrored pipeline)

    private suspend fun loadOrganization() {
        AuthRepository.fetchOrganization().onSuccess { response ->
            _uiState.update { it.copy(organization = response.organization, role = response.role) }
        }
    }

    private suspend fun loadLegacyMachinesAndSales() {
        MachineRepository.fetchMachinesWithStats().onSuccess { machines ->
            _uiState.update { it.copy(machines = machines) }
        }
        MachineRepository.fetchRecentSales(10).onSuccess { sales ->
            _uiState.update { it.copy(recentSales = sales) }
        }
    }

    // MARK: - Stock health

    private suspend fun loadStockHealth() {
        val health = repository.fetchMachineStockHealth()
        _uiState.update {
            it.copy(stockCriticalCount = health.criticalMachines, stockLowCount = health.lowMachines)
        }
    }

    // MARK: - New deals

    private suspend fun loadNewDealsCount() {
        val count = repository.fetchNewDealsCount()
        _uiState.update { it.copy(newDealsCount = count) }
    }

    // MARK: - Cash book summary tile

    private suspend fun loadCashBookSummary() {
        val summary = repository.fetchCashBookSummary()
        _uiState.update { it.copy(cashBookSummary = summary) }
    }

    // MARK: - Sales KPIs + 30-day chart

    /**
     * One shared fetch covers both windows: the KPI lower bound (up to ~2
     * months back, for the "last month" bucket) and the chart's fixed
     * 30-day-back window. [DashboardKpis.bucketSales] / [buildDailyChart]
     * then filter the same list into their own buckets — cheaper than the
     * two separate fetches iOS makes for the same data.
     */
    private suspend fun loadSalesKpisAndChart() {
        val zone = TimeZone.currentSystemDefault()
        val now = Clock.System.now().toLocalDateTime(zone)
        val thirtyDaysAgo = now.date.minus(30, DateTimeUnit.DAY).atStartOfDayIn(zone)
        val kpiBound = DashboardKpis.queryLowerBound(now, zone)
        val since = minOf(kpiBound, thirtyDaysAgo)

        val sales = repository.fetchSalesSince(since)
        val kpis = DashboardKpis.bucketSales(sales, now, zone)
        val dailySales = DashboardKpis.buildDailyChart(sales, now, zone)
        _uiState.update { it.copy(kpis = kpis, dailySales = dailySales) }
    }

    // MARK: - Recent activity (sales + refills + tour starts + intakes)

    /**
     * Fetches the three activity sources for the current window, merges
     * them, and updates [rawSourceRowCount]. Exposed at `internal` (not
     * `private`) so tests can drive it directly without going through
     * [loadDashboard]'s legacy/network-singleton fan-out.
     */
    internal suspend fun loadRecentActivity() {
        val zone = TimeZone.currentSystemDefault()
        val today = Clock.System.now().toLocalDateTime(zone).date
        val daysBack = _uiState.value.activityDaysBack
        val windowStart = today.minus(daysBack, DateTimeUnit.DAY).atStartOfDayIn(zone)

        coroutineScope {
            val salesDeferred = async { repository.fetchRecentSaleItems(windowStart) }
            val activityDeferred = async { repository.fetchActivityRows(windowStart) }
            val intakeDeferred = async { repository.fetchIntakeRows(windowStart) }

            val (sales, rawSalesCount) = salesDeferred.await()
            val activityRows = activityDeferred.await()
            val intakeRows = intakeDeferred.await()

            val groups = ActivityFeedBuilder.groupIntakes(intakeRows).toMutableList()
            val names = resolveUserNames(groups.mapNotNull { it.userId })
            for (i in groups.indices) {
                val uid = groups[i].userId
                if (uid != null) groups[i] = groups[i].copy(userDisplay = names[uid])
            }

            // Slot change rows carry ids only: name their authors and products.
            val slotChangeIds = ActivityFeedBuilder.slotChangeLookupIds(activityRows)
            val slotChangeUsers = resolveUserNames(slotChangeIds.users)
            val productNames = resolveProductNames(slotChangeIds.products)

            val rawBefore = rawSourceRowCount
            rawSourceRowCount = rawSalesCount + activityRows.size + intakeRows.size
            val merged = ActivityFeedBuilder.mergeFeed(
                sales = sales,
                activityRows = activityRows,
                intakeGroups = groups,
                userNames = slotChangeUsers,
                productNames = productNames,
            )

            _uiState.update { state ->
                state.copy(
                    activity = merged,
                    loadMoreFailed = false,
                    // Recovery: a reload that brought in more raw rows than
                    // before (e.g. realtime delivery into the current
                    // window) un-exhausts the infinite scroll.
                    hasMoreActivity = if (rawSourceRowCount > rawBefore) true else state.hasMoreActivity,
                )
            }
        }
    }

    /** Resolve + cache display names for intake attribution; never throws. */
    private suspend fun resolveUserNames(ids: List<String>): Map<String, String> {
        val missing = ids.filter { it !in userNameCache }.distinct()
        if (missing.isNotEmpty()) {
            userNameCache.putAll(repository.resolveUserNames(missing))
        }
        return ids.mapNotNull { id -> userNameCache[id]?.let { id to it } }.toMap()
    }

    /** Resolve + cache product names for slot change rows; never throws. */
    private suspend fun resolveProductNames(ids: List<String>): Map<String, String> {
        val missing = ids.filter { it !in productNameCache }.distinct()
        if (missing.isNotEmpty()) {
            productNameCache.putAll(repository.resolveProductNames(missing))
        }
        return ids.mapNotNull { id -> productNameCache[id]?.let { id to it } }.toMap()
    }

    // MARK: - Load more (infinite scroll)

    suspend fun loadMoreActivity() {
        val state = _uiState.value
        if (state.isLoadingMoreActivity || state.isLoading || !state.hasMoreActivity) return

        val previousDaysBack = state.activityDaysBack
        val next = nextDaysBack(previousDaysBack)

        _uiState.update { it.copy(isLoadingMoreActivity = true, loadMoreFailed = false) }
        val rawBefore = rawSourceRowCount
        // Widen the window before fetching: a concurrent loadDashboard() that
        // reads it mid-flight should see the widened value, not the stale
        // one — reverting on our own cancellation would otherwise make the
        // sentinel re-fetch the same window and falsely flag "exhausted".
        _uiState.update { it.copy(activityDaysBack = next) }

        try {
            loadRecentActivity()
            // Same raw row count in a wider window -> history exhausted.
            if (rawSourceRowCount == rawBefore) {
                _uiState.update { it.copy(hasMoreActivity = false) }
            }
        } catch (e: CancellationException) {
            // Cancelled (e.g. the sentinel left composition, or a concurrent
            // reload superseded this one). Do NOT revert the window — see
            // the comment above — and rethrow so the coroutine actually
            // stops instead of silently continuing past its own cancellation.
            throw e
        } catch (e: Exception) {
            // Real network/server error: revert the window so the retry
            // re-fetches the same step, and flag it so the UI can offer a
            // manual retry — a bare spinner would sit idle forever since
            // nothing re-fires it after a failure.
            _uiState.update {
                it.copy(activityDaysBack = previousDaysBack, loadMoreFailed = true, error = e.message)
            }
        } finally {
            _uiState.update { it.copy(isLoadingMoreActivity = false) }
        }
    }
}

class DashboardViewModel @JvmOverloads constructor(
    repository: DashboardDataSource = DashboardRepository,
) : ViewModel() {
    private val engine = DashboardEngine(repository)
    val uiState: StateFlow<DashboardUiState> = engine.uiState

    init {
        viewModelScope.launch { engine.loadDashboard() }
    }

    fun refresh() {
        viewModelScope.launch { engine.refresh() }
    }

    fun loadMoreActivity() {
        viewModelScope.launch { engine.loadMoreActivity() }
    }

    suspend fun signOut() {
        AuthRepository.signOut()
    }
}
