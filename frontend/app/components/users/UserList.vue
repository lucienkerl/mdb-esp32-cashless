<script setup lang="ts">
interface User {
  id: number
  user_id: string
  role: 'admin' | 'operator'
  created_at: string
  email?: string
}

const supabase = useSupabaseClient()
const users = ref<User[]>([])
const isLoading = ref(true)
const error = ref<string | null>(null)

// Fetch users with their email addresses
async function fetchUsers() {
  isLoading.value = true
  error.value = null
  
  try {
    // First, get user roles
    const { data: userRoles, error: rolesError } = await supabase
      .from('user_roles')
      .select('*')
      .order('created_at', { ascending: false })
    
    if (rolesError) {
      throw rolesError
    }

    // For each user role, fetch the corresponding email from auth.users
    // Note: This requires using admin API or RPC function
    // For now, we'll show the user_id and handle email fetching via admin API
    users.value = userRoles || []
  } catch (err: any) {
    error.value = err.message || 'Failed to fetch users'
    console.error('Error fetching users:', err)
  } finally {
    isLoading.value = false
  }
}

// Format date for display
function formatDate(dateString: string) {
  const date = new Date(dateString)
  return date.toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  })
}

// Get role badge color
function getRoleBadgeClass(role: 'admin' | 'operator') {
  return role === 'admin' 
    ? 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-300'
    : 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-300'
}

// Refresh the list (called from parent after user creation)
function refresh() {
  fetchUsers()
}

// Expose refresh method to parent
defineExpose({
  refresh,
})

// Load users on mount
onMounted(() => {
  fetchUsers()
})
</script>

<template>
  <div class="space-y-4">
    <!-- Loading state -->
    <div v-if="isLoading" class="flex items-center justify-center py-8">
      <div class="text-muted-foreground">Loading users...</div>
    </div>

    <!-- Error state -->
    <div v-else-if="error" class="rounded-lg border border-destructive bg-destructive/10 p-4">
      <p class="text-sm text-destructive">{{ error }}</p>
    </div>

    <!-- Empty state -->
    <div v-else-if="users.length === 0" class="rounded-lg border border-dashed p-8 text-center">
      <p class="text-muted-foreground">No users found. Create your first user to get started.</p>
    </div>

    <!-- User table -->
    <div v-else class="rounded-md border">
      <table class="w-full">
        <thead>
          <tr class="border-b bg-muted/50">
            <th class="h-12 px-4 text-left align-middle font-medium text-muted-foreground">
              User ID
            </th>
            <th class="h-12 px-4 text-left align-middle font-medium text-muted-foreground">
              Role
            </th>
            <th class="h-12 px-4 text-left align-middle font-medium text-muted-foreground">
              Created At
            </th>
          </tr>
        </thead>
        <tbody>
          <tr 
            v-for="user in users" 
            :key="user.id"
            class="border-b transition-colors hover:bg-muted/50"
          >
            <td class="p-4 align-middle">
              <div class="font-mono text-sm">{{ user.user_id.slice(0, 8) }}...</div>
            </td>
            <td class="p-4 align-middle">
              <span 
                class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-semibold"
                :class="getRoleBadgeClass(user.role)"
              >
                {{ user.role.charAt(0).toUpperCase() + user.role.slice(1) }}
              </span>
            </td>
            <td class="p-4 align-middle text-sm text-muted-foreground">
              {{ formatDate(user.created_at) }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
