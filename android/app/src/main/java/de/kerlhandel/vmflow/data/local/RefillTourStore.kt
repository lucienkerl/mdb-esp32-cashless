package de.kerlhandel.vmflow.data.local

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.first
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import de.kerlhandel.vmflow.data.model.RefillMachine
import de.kerlhandel.vmflow.data.model.TourLogEntry
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Persists in-progress refill tour state — mirrors iOS RefillWizardViewModel
 * persistence with a 24-hour TTL.
 */
@Singleton
class RefillTourStore @Inject constructor(
    private val dataStore: DataStore<Preferences>,
) {
    @Serializable
    data class PersistedState(
        val currentStep: String,
        val machines: List<RefillMachine>,
        val currentMachineIndex: Int,
        val selectedWarehouseId: String?,
        val tourId: String,
        val tourLog: List<TourLogEntry>,
        val savedAt: Instant,
    )

    suspend fun hasSavedTour(): Boolean {
        val raw = dataStore.data.first()[KEY] ?: return false
        val state = runCatching { Json.decodeFromString<PersistedState>(raw) }.getOrNull() ?: return false
        if (Clock.System.now() - state.savedAt > MAX_AGE) return false
        return state.currentStep == "refill" || state.currentStep == "summary"
    }

    suspend fun load(): PersistedState? {
        val raw = dataStore.data.first()[KEY] ?: return null
        val state = runCatching { Json.decodeFromString<PersistedState>(raw) }.getOrNull() ?: return null
        if (Clock.System.now() - state.savedAt > MAX_AGE) {
            clear()
            return null
        }
        return state
    }

    suspend fun save(state: PersistedState) {
        dataStore.edit { it[KEY] = Json.encodeToString(state) }
    }

    suspend fun clear() {
        dataStore.edit { it.remove(KEY) }
    }

    companion object {
        private val KEY = stringPreferencesKey("refill_tour_state")
        private val MAX_AGE = kotlin.time.Duration.parse("PT24H")
    }
}
