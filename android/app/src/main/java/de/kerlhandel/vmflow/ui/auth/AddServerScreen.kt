package de.kerlhandel.vmflow.ui.auth

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.ServerEntry
import de.kerlhandel.vmflow.ui.common.VMflowCenterTopAppBar
import de.kerlhandel.vmflow.ui.common.VMflowPrimaryButton
import java.util.UUID

@Composable
fun AddServerScreen(
    onBack: () -> Unit,
    onScanQr: () -> Unit,
    editServerId: String? = null,
    viewModel: ServerViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val initial = remember(editServerId, state.servers) {
        editServerId?.let { id -> state.servers.firstOrNull { it.id == id } }
            ?: ServerEntry(id = UUID.randomUUID().toString(), name = "", url = "", anonKey = "")
    }

    var name by remember { mutableStateOf(initial.name) }
    var url by remember { mutableStateOf(initial.url) }
    var anonKey by remember { mutableStateOf(initial.anonKey) }

    LaunchedEffect(initial) {
        name = initial.name; url = initial.url; anonKey = initial.anonKey
    }

    Scaffold(
        topBar = {
            VMflowCenterTopAppBar(
                title = stringResource(
                    if (editServerId == null) R.string.auth_add_server else R.string.auth_edit_server,
                ),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.cd_back),
                        )
                    }
                },
                actions = {
                    IconButton(onClick = onScanQr) {
                        Icon(
                            Icons.Filled.QrCode,
                            contentDescription = stringResource(R.string.auth_scan_qr),
                        )
                    }
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(inner)
                .padding(horizontal = 24.dp, vertical = 24.dp)
                .verticalScroll(rememberScrollState())
                .imePadding(),
        ) {
            FormField(
                value = name,
                onValueChange = { name = it },
                label = stringResource(R.string.auth_server_name),
                leadingIcon = Icons.Filled.Tag,
                imeAction = ImeAction.Next,
            )
            Spacer(Modifier.height(12.dp))

            FormField(
                value = url,
                onValueChange = { url = it },
                label = stringResource(R.string.auth_server_url),
                leadingIcon = Icons.Filled.Language,
                keyboardType = KeyboardType.Uri,
                imeAction = ImeAction.Next,
            )
            Spacer(Modifier.height(12.dp))

            FormField(
                value = anonKey,
                onValueChange = { anonKey = it },
                label = stringResource(R.string.auth_server_anon_key),
                leadingIcon = Icons.Filled.Key,
                imeAction = ImeAction.Done,
            )

            state.error?.let { err ->
                Spacer(Modifier.height(12.dp))
                Text(
                    err,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }

            Spacer(Modifier.height(28.dp))

            VMflowPrimaryButton(
                text = stringResource(R.string.common_save),
                onClick = {
                    viewModel.save(initial.copy(name = name, url = url, anonKey = anonKey))
                    onBack()
                },
                enabled = name.isNotBlank() && url.isNotBlank() && anonKey.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun FormField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    leadingIcon: ImageVector,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Done,
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        leadingIcon = {
            Icon(
                leadingIcon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        singleLine = true,
        shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction),
        textStyle = MaterialTheme.typography.bodyLarge,
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
            disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
            focusedTextColor = MaterialTheme.colorScheme.onSurface,
            unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}
