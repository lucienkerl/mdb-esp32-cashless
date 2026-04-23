package de.kerlhandel.vmflow.ui.root

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.realtime.RealtimeManager
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.data.repository.AuthRepository
import de.kerlhandel.vmflow.data.repository.NotificationRepository
import io.github.jan.supabase.auth.status.SessionStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import javax.inject.Inject

data class RootUiState(
    val session: SessionStatus = SessionStatus.Initializing,
    val organizationName: String? = null,
    val organizationLoaded: Boolean = false,
    val badgeCount: Int = 0,
    val supabaseUrl: String = "",
)

@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
@HiltViewModel
class RootViewModel @Inject constructor(
    private val authRepository: AuthRepository,
    private val notificationRepository: NotificationRepository,
    private val realtimeManager: RealtimeManager,
    private val clientProvider: SupabaseClientProvider,
) : ViewModel() {
    private val _uiState = MutableStateFlow(RootUiState())
    val uiState: StateFlow<RootUiState> = _uiState.asStateFlow()

    fun initialize() {
        clientProvider.initialize()
        combine(
            authRepository.sessionStatus,
            authRepository.organization,
            notificationRepository.openInboxCount,
            clientProvider.currentServer,
        ) { session, org, badge, server ->
            _uiState.value = _uiState.value.copy(
                session = session,
                organizationName = org?.name,
                organizationLoaded = (session is SessionStatus.Authenticated),
                badgeCount = badge,
                supabaseUrl = server?.sanitizedUrl ?: _uiState.value.supabaseUrl,
            )
        }.launchIn(viewModelScope)

        authRepository.sessionStatus
            .onEach { status ->
                if (status is SessionStatus.Authenticated) {
                    realtimeManager.start()
                    notificationRepository.fetchPreferences()
                    notificationRepository.refreshBadge()
                } else {
                    realtimeManager.stop()
                }
            }
            .launchIn(viewModelScope)
    }

    fun retryOrganization() {
        viewModelScope.launch { authRepository.fetchOrganization() }
    }

    fun logout() {
        viewModelScope.launch { authRepository.logout() }
    }
}
