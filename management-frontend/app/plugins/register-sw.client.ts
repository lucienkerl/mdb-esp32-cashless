/**
 * Service worker registration.
 *
 * Registers the plain /sw.js (push-only, no workbox).
 * If no SW is actively controlling the page, unregisters ALL existing
 * SWs first (including stale workbox-generated ones at the same URL)
 * to get a clean slate.
 */
export default defineNuxtPlugin(() => {
  if (!('serviceWorker' in navigator)) return

  window.addEventListener('load', async () => {
    try {
      // If we already have an active controller, SW is working fine
      if (navigator.serviceWorker.controller) {
        console.info('[register-sw] SW already active')
        return
      }

      // No active controller — clean slate: unregister everything
      // (the old workbox SW was also at /sw.js, so URL checks don't help)
      const registrations = await navigator.serviceWorker.getRegistrations()
      for (const reg of registrations) {
        const url = (reg.active ?? reg.waiting ?? reg.installing)?.scriptURL
        console.info('[register-sw] Unregistering stale SW:', url)
        await reg.unregister()
      }

      // Register fresh with cache bypass
      console.info('[register-sw] Registering /sw.js')
      await navigator.serviceWorker.register('/sw.js', {
        scope: '/',
        updateViaCache: 'none',
      })
    } catch (err) {
      console.warn('[register-sw] Registration failed:', err)
    }
  })
})
