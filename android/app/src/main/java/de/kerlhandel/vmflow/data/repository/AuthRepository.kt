package de.kerlhandel.vmflow.data.repository

import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.functions.functions
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpMethod
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import de.kerlhandel.vmflow.data.model.Organization
import de.kerlhandel.vmflow.data.model.OrganizationResponse
import de.kerlhandel.vmflow.data.model.OrganizationRole
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.ApplicationScope
import javax.inject.Inject
import javax.inject.Singleton

@OptIn(ExperimentalCoroutinesApi::class)
@Singleton
class AuthRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @ApplicationScope private val appScope: CoroutineScope,
) {
    private val _organization = MutableStateFlow<Organization?>(null)
    val organization: StateFlow<Organization?> = _organization.asStateFlow()

    private val _role = MutableStateFlow<OrganizationRole?>(null)
    val role: StateFlow<OrganizationRole?> = _role.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    /** Current auth session, automatically updated when client is rebuilt. */
    val sessionStatus: StateFlow<SessionStatus> = clientProvider.client
        .filterNotNull()
        .flatMapLatest { it.auth.sessionStatus }
        .stateIn(appScope, SharingStarted.Eagerly, SessionStatus.Initializing)

    init {
        // Re-fetch organization whenever we're authenticated.
        appScope.launch {
            sessionStatus.collect { status ->
                if (status is SessionStatus.Authenticated) {
                    fetchOrganization()
                } else if (status is SessionStatus.NotAuthenticated) {
                    _organization.value = null
                    _role.value = null
                }
            }
        }
    }

    suspend fun login(email: String, password: String): Result<Unit> = runCatching {
        _error.value = null
        clientProvider.require().auth.signInWith(Email) {
            this.email = email
            this.password = password
        }
        fetchOrganization()
    }.onFailure { _error.value = it.localizedMessage }

    suspend fun register(
        email: String,
        password: String,
        firstName: String,
        lastName: String,
    ): Result<Unit> = runCatching {
        _error.value = null
        clientProvider.require().auth.signUpWith(Email) {
            this.email = email
            this.password = password
            this.data = buildJsonObject {
                put("first_name", JsonPrimitive(firstName))
                put("last_name", JsonPrimitive(lastName))
            }
        }
        fetchOrganization()
    }.onFailure { _error.value = it.localizedMessage }

    suspend fun logout() {
        runCatching { clientProvider.require().auth.signOut() }
        _organization.value = null
        _role.value = null
        _error.value = null
    }

    suspend fun fetchOrganization() {
        val client = clientProvider.require()
        runCatching {
            val raw = client.functions.invoke("get-my-organization") {
                method = HttpMethod.Get
            }.bodyAsText()
            val parsed = Json { ignoreUnknownKeys = true }.decodeFromString(
                OrganizationResponse.serializer(), raw
            )
            _organization.value = parsed.organization
            _role.value = OrganizationRole.parse(parsed.role)
        }.onFailure {
            _organization.value = null
            _role.value = null
        }
    }

    fun clearError() { _error.value = null }
}
