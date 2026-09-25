package xyz.vmflow.ui.navigation

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Dashboard
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.material.icons.filled.Warehouse
import androidx.compose.material.icons.outlined.Dashboard
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Storefront
import androidx.compose.material.icons.outlined.Warehouse
import androidx.compose.ui.graphics.vector.ImageVector
import xyz.vmflow.R
import xyz.vmflow.Routes

/**
 * The destinations reachable from the navigation bar / rail.
 *
 * Declaration order is display order. Material allows at most five
 * entries; Dashboard, Machines, Refill, Warehouse currently use 4 of them.
 */
enum class TopLevelDestination(
    val route: String,
    @StringRes val labelRes: Int,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector,
) {
    DASHBOARD(
        route = Routes.DASHBOARD,
        labelRes = R.string.nav_dashboard,
        selectedIcon = Icons.Filled.Dashboard,
        unselectedIcon = Icons.Outlined.Dashboard,
    ),
    MACHINES(
        route = Routes.MACHINES,
        labelRes = R.string.nav_machines,
        selectedIcon = Icons.Filled.Storefront,
        unselectedIcon = Icons.Outlined.Storefront,
    ),
    REFILL(
        route = Routes.REFILL,
        labelRes = R.string.nav_refill,
        selectedIcon = Icons.Filled.Inventory2,
        unselectedIcon = Icons.Outlined.Inventory2,
    ),
    WAREHOUSE(
        route = Routes.WAREHOUSE,
        labelRes = R.string.nav_warehouse,
        selectedIcon = Icons.Filled.Warehouse,
        unselectedIcon = Icons.Outlined.Warehouse,
    );

    companion object {
        /** Exact match only — `machines/{id}` is a detail screen, not a tab. */
        fun fromRoute(route: String?): TopLevelDestination? =
            entries.firstOrNull { it.route == route }

        /**
         * Root-of-route match: `machines/{id}` and `machines/abc` both
         * resolve to MACHINES via their first path segment, same as the
         * bare `machines` list route. Drives which entry the nav bar
         * highlights (task 22) — the bar itself now stays visible on every
         * destination except login/register (see `MainActivity`), so a
         * machine detail screen needs its parent tab to stay marked rather
         * than resolving to nothing the way [fromRoute] would.
         */
        fun fromRouteRoot(route: String?): TopLevelDestination? {
            val root = route?.substringBefore('/') ?: return null
            // Deals is opened from the dashboard (banner / top-bar icon), so
            // it keeps the Dashboard tab marked instead of highlighting nothing.
            if (root == Routes.DEALS) return DASHBOARD
            return entries.firstOrNull { it.route == root }
        }
    }
}
