<script setup lang="ts">
import { z } from 'zod'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'

definePageMeta({
  layout: 'auth',
  middleware: ['guest']
})

const { login, isLoading } = useAuth()
const loginError = ref('')

const formSchema = toTypedSchema(z.object({
  email: z.string().email('Please enter a valid email address'),
  password: z.string().min(8, 'Password must be at least 8 characters'),
}))

const form = useForm({
  validationSchema: formSchema,
})

const [emailField, emailAttrs] = form.defineField('email')
const [passwordField, passwordAttrs] = form.defineField('password')

const onSubmit = form.handleSubmit(async (values) => {
  loginError.value = ''
  const { error } = await login(values.email, values.password)

  if (error) {
    loginError.value = error.message || 'Invalid email or password'
  }
})
</script>

<template>
  <UiCard class="w-full">
    <UiCardHeader class="space-y-1">
      <UiCardTitle class="text-2xl text-center">Sign In</UiCardTitle>
      <UiCardDescription class="text-center">
        Enter your credentials to access the dashboard
      </UiCardDescription>
    </UiCardHeader>
    <UiCardContent>
      <form @submit="onSubmit" class="space-y-4">
        <div class="space-y-2">
          <UiLabel for="email">Email</UiLabel>
          <UiInput
            id="email"
            v-model="emailField"
            v-bind="emailAttrs"
            type="email"
            placeholder="admin@example.com"
            :disabled="isLoading"
          />
          <p v-if="form.errors.value.email" class="text-sm text-destructive">
            {{ form.errors.value.email }}
          </p>
        </div>
        
        <div class="space-y-2">
          <UiLabel for="password">Password</UiLabel>
          <UiInput
            id="password"
            v-model="passwordField"
            v-bind="passwordAttrs"
            type="password"
            placeholder="Enter your password"
            :disabled="isLoading"
          />
          <p v-if="form.errors.value.password" class="text-sm text-destructive">
            {{ form.errors.value.password }}
          </p>
        </div>

        <div v-if="loginError" class="rounded-md bg-destructive/15 p-3 text-sm text-destructive">
          {{ loginError }}
        </div>

        <UiButton type="submit" class="w-full" :disabled="isLoading">
          <span v-if="isLoading" class="mr-2">Loading...</span>
          {{ isLoading ? 'Signing in...' : 'Sign In' }}
        </UiButton>
      </form>
    </UiCardContent>
    <UiCardContent class="pt-0 text-center">
      <p class="text-sm text-muted-foreground">
        Contact your administrator for account access
      </p>
    </UiCardContent>
  </UiCard>
</template>
