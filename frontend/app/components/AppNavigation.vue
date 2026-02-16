<script setup lang="ts">
const { isDark, toggle, init } = useDarkMode()
const { isAdmin, isOperator } = useRole()
const user = useSupabaseUser()
const supabase = useSupabaseClient()

onMounted(() => {
  init()
})

async function logout() {
  await supabase.auth.signOut()
  await navigateTo('/auth/login')
}
</script>

<template>
  <nav class="border-b bg-background">
    <div class="flex h-16 items-center px-4 container mx-auto">
      <div class="flex items-center gap-6 flex-1">
        <!-- Brand -->
        <NuxtLink to="/" class="font-bold text-xl">
          Vending Manager
        </NuxtLink>

        <!-- Navigation Links -->
        <div class="flex items-center gap-4">
          <!-- Admin-only links -->
          <template v-if="isAdmin">
            <NuxtLink
              to="/admin/users"
              class="text-sm font-medium hover:text-primary transition-colors"
              active-class="text-primary"
            >
              Users
            </NuxtLink>
            <NuxtLink
              to="/admin/machines"
              class="text-sm font-medium hover:text-primary transition-colors"
              active-class="text-primary"
            >
              All Machines
            </NuxtLink>
          </template>

          <!-- Operator links (visible to both roles) -->
          <NuxtLink
            to="/machines"
            class="text-sm font-medium hover:text-primary transition-colors"
            active-class="text-primary"
          >
            My Machines
          </NuxtLink>
        </div>
      </div>

      <!-- User Actions -->
      <div class="ml-auto flex items-center gap-4">
        <!-- Dark Mode Toggle -->
        <UiButton variant="ghost" size="sm" @click="toggle" class="relative">
          <!-- Sun icon (show when dark) -->
          <svg
            v-if="isDark"
            xmlns="http://www.w3.org/2000/svg"
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <circle cx="12" cy="12" r="4" />
            <path d="M12 2v2" />
            <path d="M12 20v2" />
            <path d="m4.93 4.93 1.41 1.41" />
            <path d="m17.66 17.66 1.41 1.41" />
            <path d="M2 12h2" />
            <path d="M20 12h2" />
            <path d="m6.34 17.66-1.41 1.41" />
            <path d="m19.07 4.93-1.41 1.41" />
          </svg>
          <!-- Moon icon (show when light) -->
          <svg
            v-else
            xmlns="http://www.w3.org/2000/svg"
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z" />
          </svg>
        </UiButton>

        <!-- User Info & Role Badge -->
        <div v-if="user" class="flex items-center gap-2">
          <span class="text-sm text-muted-foreground hidden sm:inline">
            {{ user.email }}
          </span>
          <span
            class="text-xs px-2 py-0.5 rounded-full font-medium"
            :class="{
              'bg-primary/10 text-primary': isAdmin,
              'bg-muted text-muted-foreground': isOperator
            }"
          >
            {{ isAdmin ? 'Admin' : 'Operator' }}
          </span>
        </div>

        <!-- Logout Button -->
        <UiButton variant="ghost" size="sm" @click="logout">
          Logout
        </UiButton>
      </div>
    </div>
  </nav>
</template>
