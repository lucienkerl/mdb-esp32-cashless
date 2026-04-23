package de.kerlhandel.vmflow.ui.root

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Business
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.ui.common.LocalSupabaseUrl
import de.kerlhandel.vmflow.ui.common.VMflowPrimaryButton
import de.kerlhandel.vmflow.ui.common.VMflowSecondaryButton
import de.kerlhandel.vmflow.ui.navigation.AuthNavHost
import de.kerlhandel.vmflow.ui.navigation.MainScaffold
import de.kerlhandel.vmflow.ui.theme.BrandLime400
import de.kerlhandel.vmflow.ui.theme.BrandSlate800
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import io.github.jan.supabase.auth.status.SessionStatus

/**
 * Top-level composable — routes between Launch, Auth, NoOrganization, and Main.
 */
@Composable
fun RootScreen(widthSizeClass: WindowWidthSizeClass) {
    val viewModel: RootViewModel = hiltViewModel()
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) { viewModel.initialize() }

    CompositionLocalProvider(LocalSupabaseUrl provides uiState.supabaseUrl) {
        val session = uiState.session
        when {
            session is SessionStatus.Authenticated -> {
                if (uiState.organizationLoaded && uiState.organizationName == null) {
                    NoOrganizationScreen(
                        onRetry = { viewModel.retryOrganization() },
                        onSignOut = { viewModel.logout() },
                    )
                } else {
                    MainScaffold(widthSizeClass = widthSizeClass, badgeCount = uiState.badgeCount)
                }
            }
            session is SessionStatus.NotAuthenticated -> AuthNavHost()
            session is SessionStatus.RefreshFailure -> AuthNavHost()
            else -> LaunchScreen()
        }
    }
}

@Composable
private fun LaunchScreen() {
    // Full-screen brand splash — slate-900 background, centered mark + lime spinner.
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(BrandSlate900),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                modifier = Modifier
                    .size(92.dp)
                    .clip(RoundedCornerShape(22.dp))
                    .background(BrandSlate800),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    painter = painterResource(R.drawable.ic_vmflow_logo),
                    contentDescription = null,
                    tint = Color.Unspecified,
                    modifier = Modifier.size(72.dp),
                )
            }
            Spacer(Modifier.height(24.dp))
            Text(
                text = "VMflow",
                style = MaterialTheme.typography.displaySmall.copy(letterSpacing = (-0.5).sp),
                fontWeight = FontWeight.Bold,
                color = Color.White,
            )
            Spacer(Modifier.height(24.dp))
            CircularProgressIndicator(
                color = BrandLime400,
                strokeWidth = 3.dp,
                modifier = Modifier.size(32.dp),
            )
        }
    }
}

@Composable
private fun NoOrganizationScreen(onRetry: () -> Unit, onSignOut: () -> Unit) {
    Scaffold(containerColor = MaterialTheme.colorScheme.background) { inner ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(inner)
                .padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(88.dp)
                    .clip(RoundedCornerShape(22.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.Business,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(40.dp),
                )
            }
            Spacer(Modifier.height(20.dp))
            Text(
                text = stringResource(R.string.common_no_organization_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = stringResource(R.string.common_no_organization_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(32.dp))
            VMflowPrimaryButton(
                text = stringResource(R.string.common_retry),
                onClick = onRetry,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            VMflowSecondaryButton(
                text = stringResource(R.string.auth_sign_out),
                onClick = onSignOut,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
