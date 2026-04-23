package de.kerlhandel.vmflow.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.repository.AuthRepository
import de.kerlhandel.vmflow.data.repository.NotificationRepository
import de.kerlhandel.vmflow.ui.common.VMflowCenterTopAppBar
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class SettingsViewModel @Inject constructor(
    val authRepository: AuthRepository,
    val notificationRepository: NotificationRepository,
) : ViewModel() {
    fun logout() { viewModelScope.launch { authRepository.logout() } }
    fun togglePreference(type: String, enabled: Boolean) {
        viewModelScope.launch { notificationRepository.togglePreference(type, enabled) }
    }
    fun sendTest() { viewModelScope.launch { notificationRepository.sendTestPush() } }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onBack: () -> Unit, viewModel: SettingsViewModel = hiltViewModel()) {
    var confirmLogout by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            VMflowCenterTopAppBar(
                title = stringResource(R.string.nav_settings),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.cd_back),
                        )
                    }
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        Column(Modifier.fillMaxSize().padding(inner)) {
            // Push Notifications Section
            ListItem(
                headlineContent = { Text(stringResource(R.string.settings_push), style = MaterialTheme.typography.titleMedium) },
            )
            NotifRow("sale", R.string.settings_notif_sale, R.string.settings_notif_sale_desc, viewModel)
            NotifRow("low_stock", R.string.settings_notif_low_stock, R.string.settings_notif_low_stock_desc, viewModel)
            NotifRow("inbox", R.string.settings_notif_inbox, R.string.settings_notif_inbox_desc, viewModel)

            ListItem(
                headlineContent = { Text(stringResource(R.string.settings_push_test)) },
                leadingContent = { Icon(Icons.Filled.NotificationsActive, contentDescription = null) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                trailingContent = {
                    TextButton(onClick = { viewModel.sendTest() }) { Text("Send") }
                },
            )

            HorizontalDivider()

            // Sign Out
            ListItem(
                headlineContent = { Text(stringResource(R.string.auth_sign_out), color = MaterialTheme.colorScheme.error) },
                leadingContent = { Icon(Icons.AutoMirrored.Filled.Logout, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                trailingContent = {
                    TextButton(onClick = { confirmLogout = true }) { Text(stringResource(R.string.auth_sign_out)) }
                },
            )
        }
    }

    if (confirmLogout) {
        AlertDialog(
            onDismissRequest = { confirmLogout = false },
            title = { Text(stringResource(R.string.auth_sign_out)) },
            text = { Text(stringResource(R.string.settings_sign_out_confirm)) },
            confirmButton = {
                TextButton(onClick = { confirmLogout = false; viewModel.logout() }) {
                    Text(stringResource(R.string.auth_sign_out))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmLogout = false }) { Text(stringResource(R.string.common_cancel)) }
            },
        )
    }
}

@Composable
private fun NotifRow(type: String, titleRes: Int, descRes: Int, viewModel: SettingsViewModel) {
    val enabled = viewModel.notificationRepository.isTypeEnabled(type)
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.padding(end = 8.dp).weight(1f)) {
            Text(stringResource(titleRes), style = MaterialTheme.typography.bodyMedium)
            Text(stringResource(descRes), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = enabled, onCheckedChange = { viewModel.togglePreference(type, it) })
    }
}
