import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'
import { resolve, dirname } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  plugins: [vue()],
  test: {
    environment: 'happy-dom',
    include: ['app/**/*.test.ts', 'app/**/*.spec.ts', 'server/**/*.test.ts'],
    env: { TZ: 'UTC' },
  },
  resolve: {
    alias: {
      // Intercept Nuxt auto-imports with a test-only stub
      '#imports': resolve(__dirname, 'app/test-helpers/nuxt-stubs.ts'),
      // Mirror Nuxt path aliases so files under app/ can use @/ and ~/ imports
      // (Nuxt 4 resolves these at runtime; here we have to wire them manually)
      '@': resolve(__dirname, 'app'),
      '~': resolve(__dirname, 'app'),
    },
  },
})
