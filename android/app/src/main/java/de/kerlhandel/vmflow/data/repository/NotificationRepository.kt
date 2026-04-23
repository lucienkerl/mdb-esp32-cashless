package de.kerlhandel.vmflow.data.repository

import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.ktor.client.request.setBody
import io.ktor.http.HttpMethod
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.datetime.Clock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import de.kerlhandel.vmflow.BuildConfig
import de.kerlhandel.vmflow.data.local.PushTokenStore
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.IoDispatcher
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class NotificationRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    private val inboxRepository: InboxRepository,
    private val tokenStore: PushTokenStore,
    @IoDispatcher private val io: CoroutineDispatcher,
) {
    @Serializable
    data class NotificationPreference(
        val id: String,
        @SerialName("user_id") val userId: String,
        @SerialName("notification_type") val notificationType: String,
        val enabled: Boolean,
    )

    @Serializable
    private data class RegisterBody(
        val fcm_token: String,
        val platform: String,
        val bundle_id: String?,
    )

    @Serializable
    private data class UnregisterBody(val fcm_token: String)

    private val _preferences = MutableStateFlow<List<NotificationPreference>>(emptyList())
    val preferences: StateFlow<List<NotificationPreference>> = _preferences.asStateFlow()

    private val _openInboxCount = MutableStateFlow(0)
    val openInboxCount: StateFlow<Int> = _openInboxCount.asStateFlow()

    suspend fun registerToken(token: String) = withContext(io) {
        val current = tokenStore.currentToken.collectOneOrNull()
        if (current == token) return@withContext
        runCatching {
            clientProvider.require().functions.invoke("register-push") {
                setBody(RegisterBody(
                    fcm_token = token,
                    platform = "android",
                    bundle_id = BuildConfig.APPLICATION_ID,
                ))
            }
            tokenStore.setToken(token)
        }.onFailure { println("[NotificationRepository] registerToken failed: ${it.message}") }
    }

    suspend fun unregisterToken() = withContext(io) {
        val token = tokenStore.currentToken.collectOneOrNull() ?: return@withContext
        runCatching {
            clientProvider.require().functions.invoke("register-push") {
                method = HttpMethod.Delete
                setBody(UnregisterBody(fcm_token = token))
            }
        }
        tokenStore.setToken(null)
    }

    suspend fun fetchPreferences() = withContext(io) {
        runCatching {
            _preferences.value = clientProvider.require().from("notification_preferences").select(
                Columns.raw("id, user_id, notification_type, enabled")
            ).decodeList()
        }
    }

    fun isTypeEnabled(type: String): Boolean =
        _preferences.value.firstOrNull { it.notificationType == type }?.enabled ?: true

    suspend fun togglePreference(type: String, enabled: Boolean) = withContext(io) {
        val client = clientProvider.require()
        val userId = client.auth.currentUserOrNull()?.id ?: return@withContext
        runCatching {
            client.from("notification_preferences").upsert(
                mapOf(
                    "user_id" to userId,
                    "notification_type" to type,
                    "enabled" to enabled,
                    "updated_at" to Clock.System.now().toString(),
                ),
            ) {
                onConflict = "user_id,notification_type"
            }
            fetchPreferences()
        }
    }

    suspend fun sendTestPush() = withContext(io) {
        clientProvider.require().functions.invoke("test-push") { /* POST */ }
    }

    suspend fun refreshBadge() = withContext(io) {
        runCatching { _openInboxCount.value = inboxRepository.countOpen() }
    }
}

/** Collects the first value from a StateFlow-like stream, nullable-safe for our use. */
private suspend fun <T> kotlinx.coroutines.flow.Flow<T>.collectOneOrNull(): T? {
    var result: T? = null
    try { this.collect { result = it; throw kotlinx.coroutines.CancellationException("one-shot") } }
    catch (_: kotlinx.coroutines.CancellationException) {}
    return result
}
