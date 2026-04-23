package de.kerlhandel.vmflow.ui.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import de.kerlhandel.vmflow.ui.auth.AddServerScreen
import de.kerlhandel.vmflow.ui.auth.LoginScreen
import de.kerlhandel.vmflow.ui.auth.QrScannerScreen
import de.kerlhandel.vmflow.ui.auth.RegisterScreen
import de.kerlhandel.vmflow.ui.auth.ServerSelectionSheet

/** Auth-only nav host. Used while the user is unauthenticated. */
@Composable
fun AuthNavHost(navController: NavHostController = rememberNavController()) {
    NavHost(navController = navController, startDestination = LoginRoute) {
        composable<LoginRoute> {
            LoginScreen(
                onNavigateToRegister = { navController.navigate(RegisterRoute) },
                onNavigateToServer = { navController.navigate(ServerSelectionRoute) },
            )
        }
        composable<RegisterRoute> {
            RegisterScreen(onBack = { navController.popBackStack() })
        }
        composable<ServerSelectionRoute> {
            ServerSelectionSheet(
                onBack = { navController.popBackStack() },
                onAdd = { navController.navigate(AddServerRoute) },
                onEdit = { navController.navigate(EditServerRoute(it)) },
                onScanQr = { navController.navigate(QrScannerRoute) },
            )
        }
        composable<AddServerRoute> {
            AddServerScreen(
                onBack = { navController.popBackStack() },
                onScanQr = { navController.navigate(QrScannerRoute) },
            )
        }
        composable<EditServerRoute> { entry ->
            val args = entry.toRoute<EditServerRoute>()
            AddServerScreen(
                onBack = { navController.popBackStack() },
                onScanQr = { navController.navigate(QrScannerRoute) },
                editServerId = args.serverId,
            )
        }
        composable<QrScannerRoute> {
            QrScannerScreen(onBack = { navController.popBackStack() })
        }
    }
}
