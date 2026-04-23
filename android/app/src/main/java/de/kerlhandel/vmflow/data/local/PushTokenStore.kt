package de.kerlhandel.vmflow.data.local

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

/** Persists the last registered FCM token so we can detect token rotation. */
@Singleton
class PushTokenStore @Inject constructor(
    private val dataStore: DataStore<Preferences>,
) {
    val currentToken: Flow<String?> = dataStore.data.map { it[TOKEN_KEY] }

    suspend fun setToken(token: String?) {
        dataStore.edit { prefs ->
            if (token == null) prefs.remove(TOKEN_KEY) else prefs[TOKEN_KEY] = token
        }
    }

    companion object {
        private val TOKEN_KEY = stringPreferencesKey("fcm_token")
    }
}
