<script setup lang="ts">
definePageMeta({
  layout: 'auth'
})

const email = ref('')
const password = ref('')
const loading = ref(false)
const error = ref('')

async function handleLogin() {
  loading.value = true
  error.value = ''
  
  try {
    // Auth implementation will be added in Plan 03
    console.log('Login attempt:', email.value)
  } catch (e) {
    error.value = 'Login failed. Please try again.'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <UiCard class="w-full">
    <UiCardHeader class="space-y-1">
      <UiCardTitle class="text-2xl text-center">Welcome back</UiCardTitle>
      <UiCardDescription class="text-center">
        Enter your credentials to access your account
      </UiCardDescription>
    </UiCardHeader>
    <UiCardContent>
      <form @submit.prevent="handleLogin" class="space-y-4">
        <div class="space-y-2">
          <UiLabel for="email">Email</UiLabel>
          <UiInput
            id="email"
            v-model="email"
            type="email"
            placeholder="name@company.com"
            required
          />
        </div>
        <div class="space-y-2">
          <UiLabel for="password">Password</UiLabel>
          <UiInput
            id="password"
            v-model="password"
            type="password"
            placeholder="Enter your password"
            required
          />
        </div>
        <p v-if="error" class="text-sm text-destructive">{{ error }}</p>
        <UiButton type="submit" class="w-full" :disabled="loading">
          {{ loading ? 'Signing in...' : 'Sign in' }}
        </UiButton>
      </form>
    </UiCardContent>
  </UiCard>
</template>
