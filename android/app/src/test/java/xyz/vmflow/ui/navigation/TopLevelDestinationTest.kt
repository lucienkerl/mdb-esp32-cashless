package xyz.vmflow.ui.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import xyz.vmflow.Routes

class TopLevelDestinationTest {

    @Test
    fun `every top level route resolves to its destination`() {
        assertEquals(TopLevelDestination.DASHBOARD, TopLevelDestination.fromRoute(Routes.DASHBOARD))
        assertEquals(TopLevelDestination.MACHINES, TopLevelDestination.fromRoute(Routes.MACHINES))
        assertEquals(TopLevelDestination.REFILL, TopLevelDestination.fromRoute(Routes.REFILL))
        assertEquals(TopLevelDestination.WAREHOUSE, TopLevelDestination.fromRoute(Routes.WAREHOUSE))
    }

    @Test
    fun `a detail route is not a top level destination`() {
        assertNull(TopLevelDestination.fromRoute(Routes.machineDetail("abc-123")))
        assertNull(TopLevelDestination.fromRoute(Routes.MACHINE_DETAIL))
    }

    @Test
    fun `auth routes are not top level destinations`() {
        assertNull(TopLevelDestination.fromRoute(Routes.LOGIN))
        assertNull(TopLevelDestination.fromRoute(Routes.REGISTER))
    }

    @Test
    fun `a null route resolves to nothing`() {
        assertNull(TopLevelDestination.fromRoute(null))
    }

    // MARK: - fromRouteRoot (task 22: nav-bar selection follows the route root)

    @Test
    fun `a detail route resolves to its parent tab by root`() {
        assertEquals(TopLevelDestination.MACHINES, TopLevelDestination.fromRouteRoot(Routes.machineDetail("abc")))
        assertEquals(TopLevelDestination.MACHINES, TopLevelDestination.fromRouteRoot("machines/{machineId}"))
    }

    @Test
    fun `the deals screen keeps the dashboard tab marked`() {
        assertEquals(TopLevelDestination.DASHBOARD, TopLevelDestination.fromRouteRoot(Routes.DEALS))
        assertNull(TopLevelDestination.fromRoute(Routes.DEALS))
    }

    @Test
    fun `a bare top level route still resolves by root`() {
        assertEquals(TopLevelDestination.MACHINES, TopLevelDestination.fromRouteRoot(Routes.MACHINES))
        assertEquals(TopLevelDestination.DASHBOARD, TopLevelDestination.fromRouteRoot(Routes.DASHBOARD))
    }

    @Test
    fun `auth routes have no root match`() {
        assertNull(TopLevelDestination.fromRouteRoot(Routes.LOGIN))
        assertNull(TopLevelDestination.fromRouteRoot(Routes.REGISTER))
    }

    @Test
    fun `a null route has no root match`() {
        assertNull(TopLevelDestination.fromRouteRoot(null))
    }

    @Test
    fun `destinations are declared in navigation bar order`() {
        assertEquals(
            listOf(
                TopLevelDestination.DASHBOARD,
                TopLevelDestination.MACHINES,
                TopLevelDestination.REFILL,
                TopLevelDestination.WAREHOUSE,
            ),
            TopLevelDestination.entries.toList(),
        )
    }
}
