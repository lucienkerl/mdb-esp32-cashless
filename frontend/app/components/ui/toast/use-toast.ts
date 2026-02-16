/**
 * Minimal toast composable for notifications
 * TODO: Replace with full shadcn-vue toast implementation when Node 18+ available
 */

export interface ToastOptions {
  title?: string
  description?: string
  variant?: 'default' | 'destructive'
}

export function useToast() {
  const toast = (options: ToastOptions) => {
    // For now, use console logging and browser alerts for critical errors
    // In production, this should be replaced with a proper toast UI component
    const message = `${options.title || ''}\n${options.description || ''}`
    
    if (options.variant === 'destructive') {
      console.error('[Toast Error]', message)
      // Only alert for errors to avoid spam
      if (typeof window !== 'undefined') {
        alert(`Error: ${options.description || options.title}`)
      }
    } else {
      console.log('[Toast]', message)
    }
  }

  return { toast }
}
