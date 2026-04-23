package de.kerlhandel.vmflow.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.data.repository.AuthRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class AuthUiState(
    val email: String = "",
    val password: String = "",
    val firstName: String = "",
    val lastName: String = "",
    val isLoading: Boolean = false,
    val error: String? = null,
)

@HiltViewModel
class AuthViewModel @Inject constructor(
    private val authRepository: AuthRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(AuthUiState())
    val state: StateFlow<AuthUiState> = _state.asStateFlow()

    fun setEmail(v: String) { _state.value = _state.value.copy(email = v) }
    fun setPassword(v: String) { _state.value = _state.value.copy(password = v) }
    fun setFirstName(v: String) { _state.value = _state.value.copy(firstName = v) }
    fun setLastName(v: String) { _state.value = _state.value.copy(lastName = v) }
    fun clearError() { _state.value = _state.value.copy(error = null); authRepository.clearError() }

    fun login() {
        val s = _state.value
        if (s.email.isBlank() || s.password.isBlank()) return
        _state.value = s.copy(isLoading = true, error = null)
        viewModelScope.launch {
            val result = authRepository.login(s.email.trim(), s.password)
            _state.value = _state.value.copy(
                isLoading = false,
                error = result.exceptionOrNull()?.localizedMessage,
            )
        }
    }

    fun register() {
        val s = _state.value
        _state.value = s.copy(isLoading = true, error = null)
        viewModelScope.launch {
            val result = authRepository.register(
                email = s.email.trim(),
                password = s.password,
                firstName = s.firstName.trim(),
                lastName = s.lastName.trim(),
            )
            _state.value = _state.value.copy(
                isLoading = false,
                error = result.exceptionOrNull()?.localizedMessage,
            )
        }
    }
}
