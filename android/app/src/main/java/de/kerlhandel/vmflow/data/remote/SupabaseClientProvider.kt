package de.kerlhandel.vmflow.data.remote

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime
import io.github.jan.supabase.storage.Storage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import de.kerlhandel.vmflow.data.local.ServerStore
import de.kerlhandel.vmflow.data.model.ServerEntry
import de.kerlhandel.vmflow.di.ApplicationScope
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Provides the current SupabaseClient. Rebuilds when the selected server changes.
 * Consumers should always read `client.value` lazily (not cached) so a rebuild
 * after server switch is picked up.
 */
@Singleton
class SupabaseClientProvider @Inject constructor(
    private val serverStore: ServerStore,
    @ApplicationScope private val appScope: CoroutineScope,
) {
    private val _currentServer = MutableStateFlow<ServerEntry?>(null)
    val currentServer: StateFlow<ServerEntry?> = _currentServer

    private val _client = MutableStateFlow<SupabaseClient?>(null)
    val client: StateFlow<SupabaseClient?> = _client

    /** Resolved non-null client — callers MUST ensure provider is initialized first. */
    fun require(): SupabaseClient = _client.value
        ?: error("SupabaseClient not initialized — call initialize() from Application.onCreate()")

    val baseUrl: String get() = _currentServer.value?.sanitizedUrl ?: ""

    fun initialize() {
        appScope.launch {
            val initial = serverStore.selectedServer.first()
            rebuild(initial)
        }
    }

    /** Switch the client to a different server. Only call from login — avoids torn sessions. */
    suspend fun reconfigure(server: ServerEntry) {
        rebuild(server)
    }

    private fun rebuild(server: ServerEntry) {
        _currentServer.value = server
        _client.value = createSupabaseClient(
            supabaseUrl = server.sanitizedUrl,
            supabaseKey = server.anonKey,
        ) {
            install(Auth) {
                alwaysAutoRefresh = true
                autoLoadFromStorage = true
            }
            install(Postgrest)
            install(Realtime)
            install(Storage)
            install(Functions) {
                serializer = io.github.jan.supabase.serializer.KotlinXSerializer(
                    Json { ignoreUnknownKeys = true; isLenient = true; explicitNulls = false }
                )
            }
            defaultSerializer = io.github.jan.supabase.serializer.KotlinXSerializer(
                Json { ignoreUnknownKeys = true; isLenient = true; explicitNulls = false }
            )
        }
    }
}
