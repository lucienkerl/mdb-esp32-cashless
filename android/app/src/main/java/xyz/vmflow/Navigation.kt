package xyz.vmflow

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.runtime.Composable
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import xyz.vmflow.ui.auth.LoginScreen
import xyz.vmflow.ui.auth.RegisterScreen
import xyz.vmflow.ui.dashboard.DashboardScreen
import xyz.vmflow.ui.deals.DealsScreen
import xyz.vmflow.ui.machines.MachineDetailScreen
import xyz.vmflow.ui.machines.MachinesPane
import xyz.vmflow.ui.navigation.TopLevelDestination
import xyz.vmflow.ui.refill.RefillWizardScreen
import xyz.vmflow.ui.warehouse.WarehouseScreen

object Routes {
    const val LOGIN = "login"
    const val REGISTER = "register"
    const val DASHBOARD = "dashboard"
    const val MACHINES = "machines"
    const val MACHINE_DETAIL = "machines/{machineId}"
    const val REFILL = "refill"
    const val WAREHOUSE = "warehouse"
    const val DEALS = "deals"

    fun machineDetail(machineId: String) = "machines/$machineId"
}

@Composable
fun VMflowNavHost(
    navController: NavHostController,
    startDestination: String
) {
    val animDuration = 300

    NavHost(
        navController = navController,
        startDestination = startDestination,
        enterTransition = {
            if (isTopLevelSwitch()) {
                fadeIn(tween(animDuration))
            } else {
                slideIntoContainer(
                    towards = AnimatedContentTransitionScope.SlideDirection.Start,
                    animationSpec = tween(animDuration)
                ) + fadeIn(tween(animDuration))
            }
        },
        exitTransition = {
            if (isTopLevelSwitch()) {
                fadeOut(tween(animDuration))
            } else {
                slideOutOfContainer(
                    towards = AnimatedContentTransitionScope.SlideDirection.Start,
                    animationSpec = tween(animDuration)
                ) + fadeOut(tween(animDuration))
            }
        },
        popEnterTransition = {
            if (isTopLevelSwitch()) {
                fadeIn(tween(animDuration))
            } else {
                slideIntoContainer(
                    towards = AnimatedContentTransitionScope.SlideDirection.End,
                    animationSpec = tween(animDuration)
                ) + fadeIn(tween(animDuration))
            }
        },
        popExitTransition = {
            if (isTopLevelSwitch()) {
                fadeOut(tween(animDuration))
            } else {
                slideOutOfContainer(
                    towards = AnimatedContentTransitionScope.SlideDirection.End,
                    animationSpec = tween(animDuration)
                ) + fadeOut(tween(animDuration))
            }
        }
    ) {
        composable(Routes.LOGIN) {
            LoginScreen(
                onLoginSuccess = {
                    navController.navigate(Routes.DASHBOARD) {
                        popUpTo(Routes.LOGIN) { inclusive = true }
                    }
                },
                onNavigateToRegister = {
                    navController.navigate(Routes.REGISTER)
                }
            )
        }

        composable(Routes.REGISTER) {
            RegisterScreen(
                onNavigateBack = { navController.popBackStack() }
            )
        }

        composable(Routes.DASHBOARD) {
            DashboardScreen(
                onNavigateToMachine = { id ->
                    navController.navigate(Routes.machineDetail(id))
                },
                onNavigateToDeals = {
                    navController.navigate(Routes.DEALS) { launchSingleTop = true }
                },
                onLogout = {
                    navController.navigate(Routes.LOGIN) {
                        popUpTo(0) { inclusive = true }
                    }
                }
            )
        }

        composable(Routes.MACHINES) {
            MachinesPane()
        }

        composable(
            route = Routes.MACHINE_DETAIL,
            arguments = listOf(
                navArgument("machineId") { type = NavType.StringType }
            )
        ) { backStackEntry ->
            val machineId = backStackEntry.arguments?.getString("machineId") ?: return@composable
            MachineDetailScreen(
                machineId = machineId,
                onNavigateBack = { navController.popBackStack() }
            )
        }

        composable(Routes.REFILL) {
            RefillWizardScreen(
                onDone = {
                    navController.navigate(Routes.DASHBOARD) {
                        // inclusive = false keeps the dashboard entry that
                        // every tab switch saves its scroll/search state
                        // against; popping it (inclusive = true) silently
                        // reset the Machines tab's state on every finished
                        // refill.
                        popUpTo(Routes.DASHBOARD) { inclusive = false }
                        launchSingleTop = true
                    }
                }
            )
        }

        composable(Routes.WAREHOUSE) {
            WarehouseScreen()
        }

        composable(Routes.DEALS) {
            DealsScreen(onNavigateBack = { navController.popBackStack() })
        }
    }
}

/**
 * True when both sides of the transition are navigation-bar destinations.
 *
 * Sideways motion expresses hierarchy; switching between siblings should
 * cross-fade instead.
 */
private fun AnimatedContentTransitionScope<NavBackStackEntry>.isTopLevelSwitch(): Boolean =
    TopLevelDestination.fromRoute(initialState.destination.route) != null &&
        TopLevelDestination.fromRoute(targetState.destination.route) != null
