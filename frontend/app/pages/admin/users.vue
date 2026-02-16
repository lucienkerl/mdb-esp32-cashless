<script setup lang="ts">
definePageMeta({
  middleware: ['auth', 'admin'],
})

const isCreateModalOpen = ref(false)
const userListRef = ref<{ refresh: () => void } | null>(null)

function openCreateModal() {
  isCreateModalOpen.value = true
}

function handleUserCreated() {
  // Refresh the user list after successful creation
  if (userListRef.value) {
    userListRef.value.refresh()
  }
}
</script>

<template>
  <div class="container mx-auto py-6 px-4">
    <!-- Page Header -->
    <div class="mb-6">
      <h1 class="text-3xl font-bold tracking-tight">User Management</h1>
      <p class="text-muted-foreground mt-2">
        Manage user accounts and assign roles (Admin or Operator).
      </p>
    </div>
    
    <!-- Actions -->
    <div class="mb-6">
      <button
        class="inline-flex h-10 items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground ring-offset-background transition-colors hover:bg-primary/90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
        @click="openCreateModal"
      >
        <svg 
          xmlns="http://www.w3.org/2000/svg" 
          class="mr-2 h-4 w-4" 
          viewBox="0 0 24 24" 
          fill="none" 
          stroke="currentColor" 
          stroke-width="2" 
          stroke-linecap="round" 
          stroke-linejoin="round"
        >
          <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
          <circle cx="9" cy="7" r="4" />
          <line x1="19" x2="19" y1="8" y2="14" />
          <line x1="22" x2="16" y1="11" y2="11" />
        </svg>
        Create User
      </button>
    </div>
    
    <!-- User List Card -->
    <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
      <div class="p-6">
        <h2 class="text-xl font-semibold mb-4">All Users</h2>
        <UserList ref="userListRef" />
      </div>
    </div>
    
    <!-- Create User Modal -->
    <CreateUserModal 
      v-model:open="isCreateModalOpen"
      @user-created="handleUserCreated"
    />
  </div>
</template>
