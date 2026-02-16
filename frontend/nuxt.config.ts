// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  devtools: { enabled: true },
  
  // Nuxt 3 app directory structure
  srcDir: 'app/',
  
  // CSS configuration
  css: ['~/assets/css/tailwind.css'],
  
  // Modules
  modules: [
    '@nuxtjs/supabase',
    'shadcn-nuxt',
    '@vueuse/nuxt',
  ],
  
  // Supabase configuration
  supabase: {
    url: process.env.NUXT_PUBLIC_SUPABASE_URL,
    key: process.env.NUXT_PUBLIC_SUPABASE_KEY,
    redirectOptions: {
      login: '/auth/login',
      callback: '/auth/confirm',
      exclude: ['/auth/*'],
    },
    // Enable SSR cookies for authentication persistence
    useSsrCookies: true,
    clientOptions: {
      auth: {
        flowType: 'pkce',
        detectSessionInUrl: true,
        persistSession: true,
        autoRefreshToken: true,
      },
    },
  },
  
  // shadcn-vue configuration
  shadcn: {
    componentDir: '~/components/ui',
  },
  
  // Tailwind CSS v4 via Vite plugin
  vite: {
    css: {
      postcss: {
        plugins: {
          tailwindcss: {},
          autoprefixer: {},
        },
      },
    },
  },
  
  // TypeScript configuration
  typescript: {
    typeCheck: true,
  },
  
  // Nitro configuration
  nitro: {
    preset: 'node-server',
  },
})
