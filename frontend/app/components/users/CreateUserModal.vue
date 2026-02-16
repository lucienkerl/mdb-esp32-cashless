<script setup lang="ts">
interface Props {
  open: boolean
}

interface Emits {
  (e: 'update:open', value: boolean): void
  (e: 'user-created'): void
}

const props = defineProps<Props>()
const emit = defineEmits<Emits>()

const supabase = useSupabaseClient()

// Form state
const email = ref('')
const password = ref('')
const role = ref<'admin' | 'operator'>('operator')
const isSubmitting = ref(false)
const error = ref<string | null>(null)

// Form validation
const emailError = ref<string | null>(null)
const passwordError = ref<string | null>(null)

function validateEmail() {
  if (!email.value) {
    emailError.value = 'Email is required'
    return false
  }
  
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
  if (!emailRegex.test(email.value)) {
    emailError.value = 'Invalid email address'
    return false
  }
  
  emailError.value = null
  return true
}

function validatePassword() {
  if (!password.value) {
    passwordError.value = 'Password is required'
    return false
  }
  
  if (password.value.length < 8) {
    passwordError.value = 'Password must be at least 8 characters'
    return false
  }
  
  passwordError.value = null
  return true
}

function validateForm() {
  const emailValid = validateEmail()
  const passwordValid = validatePassword()
  return emailValid && passwordValid
}

async function handleSubmit() {
  error.value = null
  
  if (!validateForm()) {
    return
  }
  
  isSubmitting.value = true
  
  try {
    // Create user with Supabase auth
    // Note: Using signUp for now, which requires email confirmation
    // In production, this should use admin API to create users without confirmation
    const { data: authData, error: authError } = await supabase.auth.signUp({
      email: email.value,
      password: password.value,
      options: {
        data: {
          role: role.value,
        },
      },
    })
    
    if (authError) {
      throw authError
    }
    
    if (!authData.user) {
      throw new Error('User creation failed')
    }
    
    // Insert role into user_roles table
    const { error: roleError } = await supabase
      .from('user_roles')
      .insert({
        user_id: authData.user.id,
        role: role.value,
      })
    
    if (roleError) {
      // If role insertion fails, we should ideally delete the auth user
      // For now, just log the error
      console.error('Failed to insert user role:', roleError)
      throw new Error('Failed to assign user role')
    }
    
    // Success - reset form and close modal
    resetForm()
    emit('update:open', false)
    emit('user-created')
  } catch (err: any) {
    error.value = err.message || 'Failed to create user'
    console.error('User creation error:', err)
  } finally {
    isSubmitting.value = false
  }
}

function resetForm() {
  email.value = ''
  password.value = ''
  role.value = 'operator'
  emailError.value = null
  passwordError.value = null
  error.value = null
}

function handleOpenChange(open: boolean) {
  if (!open) {
    resetForm()
  }
  emit('update:open', open)
}
</script>

<template>
  <div 
    v-if="open" 
    class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
    @click.self="handleOpenChange(false)"
  >
    <div class="w-full max-w-md rounded-lg border bg-background p-6 shadow-lg">
      <!-- Header -->
      <div class="mb-4">
        <h2 class="text-lg font-semibold">Create New User</h2>
        <p class="text-sm text-muted-foreground">
          Add a new user with email, password, and role assignment.
        </p>
      </div>
      
      <!-- Form -->
      <form @submit.prevent="handleSubmit" class="space-y-4">
        <!-- Email field -->
        <div class="space-y-2">
          <label for="email" class="text-sm font-medium leading-none">
            Email
          </label>
          <input
            id="email"
            v-model="email"
            type="email"
            placeholder="user@example.com"
            class="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background file:border-0 file:bg-transparent file:text-sm file:font-medium placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
            :class="{ 'border-destructive': emailError }"
            @blur="validateEmail"
            required
          />
          <p v-if="emailError" class="text-sm text-destructive">
            {{ emailError }}
          </p>
        </div>
        
        <!-- Password field -->
        <div class="space-y-2">
          <label for="password" class="text-sm font-medium leading-none">
            Password
          </label>
          <input
            id="password"
            v-model="password"
            type="password"
            placeholder="Minimum 8 characters"
            class="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background file:border-0 file:bg-transparent file:text-sm file:font-medium placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
            :class="{ 'border-destructive': passwordError }"
            @blur="validatePassword"
            required
          />
          <p v-if="passwordError" class="text-sm text-destructive">
            {{ passwordError }}
          </p>
        </div>
        
        <!-- Role selection -->
        <div class="space-y-2">
          <label class="text-sm font-medium leading-none">
            Role
          </label>
          <div class="space-y-2">
            <label class="flex items-center space-x-2 cursor-pointer">
              <input
                v-model="role"
                type="radio"
                name="role"
                value="operator"
                class="h-4 w-4 border-gray-300 text-primary focus:ring-2 focus:ring-ring"
              />
              <span class="text-sm">Operator (Read-only access to assigned machines)</span>
            </label>
            <label class="flex items-center space-x-2 cursor-pointer">
              <input
                v-model="role"
                type="radio"
                name="role"
                value="admin"
                class="h-4 w-4 border-gray-300 text-primary focus:ring-2 focus:ring-ring"
              />
              <span class="text-sm">Admin (Full access to all features)</span>
            </label>
          </div>
        </div>
        
        <!-- Error message -->
        <div v-if="error" class="rounded-lg border border-destructive bg-destructive/10 p-3">
          <p class="text-sm text-destructive">{{ error }}</p>
        </div>
        
        <!-- Actions -->
        <div class="flex justify-end gap-2 pt-2">
          <button
            type="button"
            class="inline-flex h-10 items-center justify-center rounded-md border border-input bg-background px-4 py-2 text-sm font-medium ring-offset-background transition-colors hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50"
            @click="handleOpenChange(false)"
            :disabled="isSubmitting"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="inline-flex h-10 items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground ring-offset-background transition-colors hover:bg-primary/90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50"
            :disabled="isSubmitting"
          >
            <span v-if="isSubmitting">Creating...</span>
            <span v-else>Create User</span>
          </button>
        </div>
      </form>
    </div>
  </div>
</template>
