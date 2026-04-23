package de.kerlhandel.vmflow.ui.navigation

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import androidx.hilt.navigation.compose.hiltViewModel
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.ui.dashboard.DashboardScreen
import de.kerlhandel.vmflow.ui.deals.DealsScreen
import de.kerlhandel.vmflow.ui.inbox.InboxScreen
import de.kerlhandel.vmflow.ui.machines.MachineDetailScreen
import de.kerlhandel.vmflow.ui.machines.MachineListScreen
import de.kerlhandel.vmflow.ui.products.ProductsScreen
import de.kerlhandel.vmflow.ui.refill.RefillWizardScreen
import de.kerlhandel.vmflow.ui.root.MoreScreen
import de.kerlhandel.vmflow.ui.settings.SettingsScreen
import de.kerlhandel.vmflow.ui.warehouse.WarehouseScreen

/**
 * Adaptive scaffold that picks:
 *  - Compact (< 600 dp): Bottom navigation (5 tabs)
 *  - Medium/Expanded (>= 600 dp): Navigation rail with all items
 */
@Composable
fun MainScaffold(
    widthSizeClass: WindowWidthSizeClass,
    badgeCount: Int,
    navController: NavHostController = rememberNavController(),
) {
    val isCompact = widthSizeClass == WindowWidthSizeClass.Compact
    val backStack by navController.currentBackStackEntryAsState()
    val currentDestination = backStack?.destination

    val topLevel: List<TopLevelDestination> = if (isCompact) {
        listOf(
            TopLevelDestination.Dashboard,
            TopLevelDestination.Machines,
            TopLevelDestination.Refill,
            TopLevelDestination.Inbox,
            TopLevelDestination.More,
        )
    } else {
        TopLevelDestination.entries
    }

    Scaffold(
        bottomBar = {
            if (isCompact) {
                NavigationBar {
                    topLevel.forEach { dest ->
                        val selected = currentDestination?.matchesTopLevel(dest) == true
                        NavigationBarItem(
                            selected = selected,
                            onClick = { navController.navigateTopLevel(dest) },
                            icon = {
                                if (dest == TopLevelDestination.Inbox && badgeCount > 0) {
                                    BadgedBox(badge = { Badge { Text(badgeCount.toString()) } }) {
                                        Icon(dest.icon, contentDescription = null)
                                    }
                                } else {
                                    Icon(dest.icon, contentDescription = null)
                                }
                            },
                            label = { Text(stringResource(dest.titleRes)) },
                        )
                    }
                }
            }
        },
    ) { inner ->
        if (!isCompact) {
            // Rail + content composition
            androidx.compose.foundation.layout.Row(Modifier.padding(inner)) {
                NavigationRail {
                    topLevel.forEach { dest ->
                        val selected = currentDestination?.matchesTopLevel(dest) == true
                        NavigationRailItem(
                            selected = selected,
                            onClick = { navController.navigateTopLevel(dest) },
                            icon = {
                                if (dest == TopLevelDestination.Inbox && badgeCount > 0) {
                                    BadgedBox(badge = { Badge { Text(badgeCount.toString()) } }) {
                                        Icon(dest.icon, contentDescription = null)
                                    }
                                } else {
                                    Icon(dest.icon, contentDescription = null)
                                }
                            },
                            label = { Text(stringResource(dest.titleRes)) },
                        )
                    }
                }
                MainNavHost(navController, PaddingValues(0.dp))
            }
        } else {
            MainNavHost(navController, inner)
        }
    }
}

@Composable
private fun MainNavHost(navController: NavHostController, contentPadding: PaddingValues) {
    NavHost(
        navController = navController,
        startDestination = DashboardRoute,
        modifier = Modifier.padding(contentPadding),
    ) {
        composable<DashboardRoute> {
            DashboardScreen(
                onOpenRefill = { navController.navigateTopLevel(TopLevelDestination.Refill) },
                onOpenMachines = { navController.navigateTopLevel(TopLevelDestination.Machines) },
            )
        }
        composable<MachinesRoute> {
            MachineListScreen(onOpenDetail = { id -> navController.navigate(MachineDetailRoute(id)) })
        }
        composable<MachineDetailRoute> { entry ->
            val args = entry.toRoute<MachineDetailRoute>()
            MachineDetailScreen(
                machineId = args.machineId,
                onBack = { navController.popBackStack() },
            )
        }
        composable<RefillRoute> { RefillWizardScreen() }
        composable<InboxRoute> { InboxScreen() }
        composable<MoreRoute> {
            MoreScreen(
                onProducts = { navController.navigate(ProductsRoute) },
                onWarehouse = { navController.navigate(WarehouseRoute) },
                onDeals = { navController.navigate(DealsRoute) },
                onSettings = { navController.navigate(SettingsRoute) },
            )
        }
        composable<ProductsRoute> { ProductsScreen(onBack = { navController.popBackStack() }) }
        composable<WarehouseRoute> { WarehouseScreen(onBack = { navController.popBackStack() }) }
        composable<DealsRoute> { DealsScreen(onBack = { navController.popBackStack() }) }
        composable<SettingsRoute> { SettingsScreen(onBack = { navController.popBackStack() }) }
    }
}

private fun NavHostController.navigateTopLevel(dest: TopLevelDestination) {
    val route = when (dest) {
        TopLevelDestination.Dashboard -> DashboardRoute
        TopLevelDestination.Machines -> MachinesRoute
        TopLevelDestination.Refill -> RefillRoute
        TopLevelDestination.Inbox -> InboxRoute
        TopLevelDestination.More -> MoreRoute
        TopLevelDestination.Products -> ProductsRoute
        TopLevelDestination.Warehouse -> WarehouseRoute
        TopLevelDestination.Deals -> DealsRoute
        TopLevelDestination.Settings -> SettingsRoute
    }
    navigate(route) {
        popUpTo(graph.startDestinationId) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}

private fun androidx.navigation.NavDestination.matchesTopLevel(dest: TopLevelDestination): Boolean {
    val route: Any = when (dest) {
        TopLevelDestination.Dashboard -> DashboardRoute
        TopLevelDestination.Machines -> MachinesRoute
        TopLevelDestination.Refill -> RefillRoute
        TopLevelDestination.Inbox -> InboxRoute
        TopLevelDestination.More -> MoreRoute
        TopLevelDestination.Products -> ProductsRoute
        TopLevelDestination.Warehouse -> WarehouseRoute
        TopLevelDestination.Deals -> DealsRoute
        TopLevelDestination.Settings -> SettingsRoute
    }
    return hierarchy.any { it.hasRoute(route::class) }
}
