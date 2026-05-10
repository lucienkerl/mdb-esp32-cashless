/**
 * Stubs for Nuxt auto-imports used in composables.
 * Vitest resolves `#imports` to this file via the alias in vitest.config.ts.
 */
import { ref, computed, onMounted, onUnmounted, watch, reactive } from 'vue'

// Re-export Vue reactivity primitives that Nuxt normally auto-imports
export { ref, computed, onMounted, onUnmounted, watch, reactive }

// Stub useSupabaseClient — tests provide their own mock
export function useSupabaseClient() {
  throw new Error('useSupabaseClient must be mocked in tests')
}

// Stub useSupabaseUser
export function useSupabaseUser() {
  return ref(null)
}

// Stub useState (simplified — returns a plain ref)
export function useState<T>(key: string, init?: () => T) {
  return ref(init ? init() : undefined) as ReturnType<typeof ref<T>>
}

// Stub useI18n — components mounted in tests just need a passthrough `t`.
// Returning the key (with the params object interpolated when present) keeps
// snapshot output stable and lets tests assert on key paths rather than
// translated strings.
export function useI18n() {
  return {
    t: (key: string, params?: Record<string, unknown>) => {
      if (params && Object.keys(params).length > 0) {
        return key + ' ' + JSON.stringify(params)
      }
      return key
    },
    locale: ref('en'),
  }
}
