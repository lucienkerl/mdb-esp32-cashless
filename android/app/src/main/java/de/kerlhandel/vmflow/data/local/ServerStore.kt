package de.kerlhandel.vmflow.data.local

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json
import de.kerlhandel.vmflow.BuildConfig
import de.kerlhandel.vmflow.data.model.ServerEntry
import javax.inject.Inject
import javax.inject.Singleton

/** Persists the list of known Supabase servers and the currently selected one. */
@Singleton
class ServerStore @Inject constructor(
    private val dataStore: DataStore<androidx.datastore.preferences.core.Preferences>,
) {
    val defaultServer = ServerEntry(
        id = DEFAULT_SERVER_ID,
        name = BuildConfig.DEFAULT_SERVER_NAME,
        url = BuildConfig.SUPABASE_URL,
        anonKey = BuildConfig.SUPABASE_ANON_KEY,
        isDefault = true,
    )

    val customServers: Flow<List<ServerEntry>> = dataStore.data.map { prefs ->
        prefs[CUSTOM_SERVERS_KEY]?.let { runCatching { Json.decodeFromString<List<ServerEntry>>(it) }.getOrNull() }
            ?: emptyList()
    }

    val allServers: Flow<List<ServerEntry>> = customServers.map { listOf(defaultServer) + it }

    val selectedServer: Flow<ServerEntry> = combine(
        dataStore.data.map { it[SELECTED_SERVER_ID] },
        allServers,
    ) { selectedId, servers ->
        selectedId?.let { id -> servers.firstOrNull { it.id == id } } ?: defaultServer
    }

    suspend fun selectServer(id: String) {
        dataStore.edit { it[SELECTED_SERVER_ID] = id }
    }

    suspend fun addServer(entry: ServerEntry) {
        mutate { current ->
            val sanitized = entry.copy(url = entry.sanitizedUrl)
            current + sanitized
        }
    }

    suspend fun updateServer(entry: ServerEntry) {
        if (entry.isDefault) return
        mutate { current ->
            current.map { if (it.id == entry.id) entry.copy(url = entry.sanitizedUrl) else it }
        }
    }

    suspend fun deleteServer(id: String) {
        if (id == defaultServer.id) return
        mutate { current -> current.filterNot { it.id == id } }
        // If we just removed the currently selected one, fall back to default.
        dataStore.edit { prefs ->
            if (prefs[SELECTED_SERVER_ID] == id) prefs.remove(SELECTED_SERVER_ID)
        }
    }

    private suspend fun mutate(transform: (List<ServerEntry>) -> List<ServerEntry>) {
        dataStore.edit { prefs ->
            val raw = prefs[CUSTOM_SERVERS_KEY]
            val current = raw?.let { runCatching { Json.decodeFromString<List<ServerEntry>>(it) }.getOrNull() }
                ?: emptyList()
            val next = transform(current)
            prefs[CUSTOM_SERVERS_KEY] = Json.encodeToString(next)
        }
    }

    companion object {
        private const val DEFAULT_SERVER_ID = "00000000-0000-0000-0000-000000000001"
        private val CUSTOM_SERVERS_KEY = stringPreferencesKey("custom_servers")
        private val SELECTED_SERVER_ID = stringPreferencesKey("selected_server_id")
    }
}
