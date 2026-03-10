/**
 * Handles PWA install prompt for Android/Desktop (beforeinstallprompt)
 * and provides iOS detection for "Add to Home Screen" guidance.
 * On native Capacitor apps, all values are inert (no install banner).
 */
import { Capacitor } from '@capacitor/core'

export function useInstallPrompt() {
  const deferredPrompt = ref<any>(null)
  const dismissed = ref(false)

  // Native apps are already installed — never show install prompts
  if (import.meta.client && Capacitor.isNativePlatform()) {
    return {
      isIOS: computed(() => false),
      isStandalone: computed(() => true),
      canInstall: computed(() => false),
      showBanner: computed(() => false),
      dismiss: () => {},
      promptInstall: async () => {},
    }
  }

  const isIOS = computed(() => {
    if (!import.meta.client) return false
    return /iPad|iPhone|iPod/.test(navigator.userAgent) && !(window as any).MSStream
  })

  const isStandalone = computed(() => {
    if (!import.meta.client) return false
    return (
      window.matchMedia('(display-mode: standalone)').matches ||
      (navigator as any).standalone === true
    )
  })

  /** True when the native Android/Desktop install prompt is available */
  const canInstall = computed(() => !!deferredPrompt.value)

  /** True when we should show the install banner (iOS or Android, not yet installed, not dismissed) */
  const showBanner = computed(() => {
    if (isStandalone.value || dismissed.value) return false
    return canInstall.value || isIOS.value
  })

  function dismiss() {
    dismissed.value = true
    if (import.meta.client) {
      localStorage.setItem('pwa-install-dismissed', '1')
    }
  }

  async function promptInstall() {
    if (!deferredPrompt.value) return
    deferredPrompt.value.prompt()
    const { outcome } = await deferredPrompt.value.userChoice
    if (outcome === 'accepted') {
      deferredPrompt.value = null
    }
  }

  if (import.meta.client) {
    // Check if previously dismissed
    dismissed.value = localStorage.getItem('pwa-install-dismissed') === '1'

    window.addEventListener('beforeinstallprompt', (e: Event) => {
      e.preventDefault()
      deferredPrompt.value = e
    })

    // Clear prompt after successful install
    window.addEventListener('appinstalled', () => {
      deferredPrompt.value = null
    })
  }

  return {
    isIOS,
    isStandalone,
    canInstall,
    showBanner,
    dismiss,
    promptInstall,
  }
}
