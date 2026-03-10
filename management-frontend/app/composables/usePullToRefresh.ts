/**
 * Register a pull-to-refresh handler for the current page.
 *
 * The handler is stored in shared state (`useState`) so the layout-level
 * `<PullToRefresh>` component can invoke it when the user pulls down.
 *
 * Usage (in any page):
 *   usePullToRefresh(() => fetchMyData())
 */
export function usePullToRefresh(handler: () => Promise<void> | void) {
  // Only register on client — useState serializes values for SSR hydration,
  // and functions cannot be serialized to JSON (causes 500 during SSR).
  if (import.meta.server) return

  const refreshHandler = useState<(() => Promise<void> | void) | null>('pull-refresh-handler', () => null)
  refreshHandler.value = handler

  onUnmounted(() => {
    // Only clear if this page's handler is still the active one
    if (refreshHandler.value === handler) {
      refreshHandler.value = null
    }
  })
}
