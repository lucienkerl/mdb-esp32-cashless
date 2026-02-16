<script setup lang="ts">
const { isAdmin, isOperator } = useRole()
const user = useSupabaseUser()
const supabase = useSupabaseClient()

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
