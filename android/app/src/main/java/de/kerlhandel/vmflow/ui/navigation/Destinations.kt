package de.kerlhandel.vmflow.ui.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.ui.graphics.vector.ImageVector
import de.kerlhandel.vmflow.R
import kotlinx.serialization.Serializable

// --- Root graphs ---
@Serializable data object AuthGraph
@Serializable data object MainGraph

// --- Auth screens ---
@Serializable data object LoginRoute
@Serializable data object RegisterRoute
@Serializable data object ServerSelectionRoute
@Serializable data object AddServerRoute
@Serializable data class EditServerRoute(val serverId: String)
@Serializable data object QrScannerRoute

// --- Main tabs ---
@Serializable data object DashboardRoute
@Serializable data object MachinesRoute
@Serializable data class MachineDetailRoute(val machineId: String)
@Serializable data object RefillRoute
@Serializable data object InboxRoute
@Serializable data object MoreRoute

// --- Secondary destinations ---
@Serializable data object ProductsRoute
@Serializable data object WarehouseRoute
@Serializable data object DealsRoute
@Serializable data object SettingsRoute
@Serializable data object NoOrganizationRoute

/** Top-level destinations (shown in bottom bar / rail / drawer). */
enum class TopLevelDestination(
    val titleRes: Int,
    val icon: ImageVector,
    val compact: Boolean, // true = always in bottom bar / rail; false = under "More" on compact
) {
    Dashboard(R.string.nav_dashboard, Icons.Filled.BarChart, compact = true),
    Machines(R.string.nav_machines, Icons.Filled.Storefront, compact = true),
    Refill(R.string.nav_refill, Icons.Filled.Refresh, compact = true),
    Inbox(R.string.nav_inbox, Icons.Filled.Inbox, compact = true),
    More(R.string.nav_more, Icons.Filled.MoreHoriz, compact = true),
    Products(R.string.nav_products, Icons.Filled.Inventory2, compact = false),
    Warehouse(R.string.nav_warehouse, Icons.Filled.Business, compact = false),
    Deals(R.string.nav_deals, Icons.Filled.LocalOffer, compact = false),
    Settings(R.string.nav_settings, Icons.Filled.Settings, compact = false),
}
