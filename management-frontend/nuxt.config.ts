import pkg from './package.json'
import { baseFromSemver, formatVersion } from './app/lib/appVersion'

const buildDateRaw = process.env.BUILD_DATE ?? ''
const buildDateObj = buildDateRaw && !isNaN(new Date(buildDateRaw).getTime())
  ? new Date(buildDateRaw)
  : new Date()
const { real: appVersionReal, display: appVersionDisplay } = formatVersion(
  baseFromSemver(pkg.version),
  buildDateObj,
)

// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  compatibilityDate: '2025-07-15',
  modules: ['@nuxtjs/supabase', '@nuxtjs/tailwindcss', 'shadcn-nuxt', '@vite-pwa/nuxt', '@nuxtjs/i18n'],
  devtools: { enabled: true },
  // Nuxt emits server sourcemaps by default. Nitro then has to carry the
  // sourcemap of every SSR chunk through its own Rollup pass, which pushed the
  // production build past a 3 GB heap (OOM in "Building Nuxt Nitro server").
  // Without them the whole build peaks around 3.5 GB RSS instead of 7.7 GB.
  // The client never shipped sourcemaps (Nuxt's default), so nothing visible
  // changes; only server stack traces point into the bundled .mjs files.
  sourcemap: { server: false, client: false },
  vue: {
    compilerOptions: {
      isCustomElement: (tag: string) => tag.startsWith('esp-'),
    },
  },
  app: {
    head: {
      meta: [
        { name: 'viewport', content: 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover' },
        { name: 'apple-mobile-web-app-capable', content: 'yes' },
        { name: 'apple-mobile-web-app-status-bar-style', content: 'default' },
        { name: 'apple-mobile-web-app-title', content: 'VMflow' },
        { name: 'theme-color', content: '#ffffff', media: '(prefers-color-scheme: light)' },
        { name: 'theme-color', content: '#09090b', media: '(prefers-color-scheme: dark)' },
      ],
      link: [
        { rel: 'manifest', href: '/manifest.webmanifest' },
        { rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg' },
        { rel: 'icon', type: 'image/png', sizes: '32x32', href: '/favicon-32.png' },
        { rel: 'icon', type: 'image/png', sizes: '16x16', href: '/favicon-16.png' },
        { rel: 'apple-touch-icon', sizes: '180x180', href: '/apple-touch-icon.png' },
      ],
    },
  },
  supabase: {
    // URL and key are read from SUPABASE_URL / SUPABASE_KEY in .env
    redirect: false,
    // Fixed cookie prefix so it does not depend on the Supabase URL.
    // This allows the Docker image to be built generically (with a placeholder URL)
    // and configured at runtime via NUXT_PUBLIC_SUPABASE_URL.
    cookiePrefix: 'sb-vmflow-auth-token',
    cookieOptions: {
      // Allow cookies over plain HTTP during local/LAN development
      secure: false,
    },
  },
  // Password-manager association for the mobile apps (see
  // server/utils/appAssociation.ts). Registered explicitly rather than as
  // server/routes/.well-known/* so the dot directory can't be skipped by a scan.
  serverHandlers: [
    { route: '/.well-known/apple-app-site-association', method: 'get', handler: '~~/server/well-known/apple-app-site-association.ts' },
    { route: '/.well-known/assetlinks.json', method: 'get', handler: '~~/server/well-known/assetlinks.ts' },
  ],
  runtimeConfig: {
    // Server-only; overridable at runtime via NUXT_APP_ASSOCIATION_* env vars
    // (Docker/docker-compose.yml). Defaults are the official VMflow apps, so
    // app.kerl-handel.de works out of the box. A self-hosted instance only
    // gains something here with its own app builds listing its domain.
    appAssociation: {
      // Comma-separated TEAMID.bundle.id list for apple-app-site-association.
      iosAppIds: '4JT3V7XVXM.de.kerl-handel.app,4JT3V7XVXM.de.kerl-handel.app.debug',
      androidPackage: 'de.kerlhandel.app',
      // Comma-separated SHA-256 signing cert fingerprints. Empty = assetlinks.json 404s.
      androidSha256: '',
    },
    public: {
      vapidPublicKey: process.env.VAPID_PUBLIC_KEY ?? '',
      githubFirmwareRepo: process.env.GITHUB_FIRMWARE_REPO ?? '',
      appVersion: appVersionReal,
      appVersionDisplay: appVersionDisplay,
      gitHash: process.env.GIT_HASH ?? 'dev',
      buildDate: process.env.BUILD_DATE ?? '',
      envName: process.env.ENV_NAME ?? '',
      envColor: process.env.ENV_COLOR ?? 'amber',
      // Publicly reachable frontend origin. Already maintained as SITE_URL in
      // Docker/.env (setup.sh sets it to https://${APP_HOST}, GoTrue uses it
      // for auth mails), so it is correct wherever password reset works.
      // Printed QR codes must not fall back to a LAN origin — see
      // isPublicOrigin() in app/lib/printSheet.ts.
      siteUrl: process.env.SITE_URL ?? '',
    },
  },
  i18n: {
    locales: [
      { code: 'en', name: 'English', file: 'en.json' },
      { code: 'de', name: 'Deutsch', file: 'de.json' },
      { code: 'fr', name: 'Français', file: 'fr.json' },
      { code: 'nl', name: 'Nederlands', file: 'nl.json' },
    ],
    defaultLocale: 'en',
    fallbackLocale: 'en',
    strategy: 'no_prefix',
    detectBrowserLanguage: {
      useCookie: true,
      cookieKey: 'i18n_locale',
      fallbackLocale: 'en',
    },
    lazy: true,
    langDir: '../i18n/locales',
    vueI18n: './i18n/i18n.config.ts',
  },
  pwa: {
    // SW is a plain file in public/sw.js — no workbox, no precache.
    // Workbox precaching caused all-or-nothing install failures on iOS,
    // preventing SW activation and breaking push notifications.
    disable: true,
    manifest: {
      name: 'VMflow',
      short_name: 'VMflow',
      description: 'Vending machine management dashboard',
      theme_color: '#0F172A',
      background_color: '#0F172A',
      display: 'standalone',
      start_url: '/',
      icons: [
        { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
        { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
        { src: '/icons/icon-maskable-192.png', sizes: '192x192', type: 'image/png', purpose: 'maskable' },
        { src: '/icons/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
      ],
      shortcuts: [
        { name: 'Machines', url: '/machines' },
        { name: 'Warehouse', url: '/warehouse' },
      ],
    },
  },
})
