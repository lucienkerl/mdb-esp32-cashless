package de.kerlhandel.vmflow.data.realtime

import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.ApplicationScope
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import io.github.jan.supabase.realtime.realtime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Central realtime subscription manager. Publishes lightweight version counters
 * that ViewModels watch to trigger reloads. Mirrors iOS RealtimeService.
 *
 * IMPORTANT: All postgresChange listeners MUST be registered before subscribe()
 * because the subscribe call builds the join payload from the currently-registered
 * listeners. See iOS RealtimeService.swift:32 for the backstory.
 */
@Singleton
class RealtimeManager @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @ApplicationScope private val scope: CoroutineScope,
) {
    data class Versions(
        val sales: Int = 0,
        val trays: Int = 0,
        val machines: Int = 0,
        val embedded: Int = 0,
        val warehouse: Int = 0,
    ) {
        val combined: Int get() = sales + trays + machines + embedded + warehouse
    }

    private val _versions = MutableStateFlow(Versions())
    val versions: StateFlow<Versions> = _versions.asStateFlow()

    private var job: Job? = null

    fun start() {
        if (job?.isActive == true) return
        job = scope.launch {
            val client = clientProvider.require()
            val channel = client.realtime.channel("app-realtime")

            // Register all listeners BEFORE subscribe.
            val salesFlow = channel.postgresChangeFlow<PostgresAction.Insert>(schema = "public") { table = "sales" }
            val traysFlow = channel.postgresChangeFlow<PostgresAction>(schema = "public") { table = "machine_trays" }
            val machinesFlow = channel.postgresChangeFlow<PostgresAction>(schema = "public") { table = "vendingMachine" }
            val embeddedFlow = channel.postgresChangeFlow<PostgresAction.Update>(schema = "public") { table = "embeddeds" }
            val warehouseFlow = channel.postgresChangeFlow<PostgresAction>(schema = "public") { table = "warehouse_stock_batches" }

            channel.subscribe()

            launch { salesFlow.collect { _versions.update { it.copy(sales = it.sales + 1) } } }
            launch { traysFlow.collect { _versions.update { it.copy(trays = it.trays + 1) } } }
            launch { machinesFlow.collect { _versions.update { it.copy(machines = it.machines + 1) } } }
            launch { embeddedFlow.collect { _versions.update { it.copy(embedded = it.embedded + 1) } } }
            launch { warehouseFlow.collect { _versions.update { it.copy(warehouse = it.warehouse + 1) } } }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
    }
}
