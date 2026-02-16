<template>
  <div class="container mx-auto py-10">
    <div class="max-w-2xl mx-auto text-center">
      <h1 class="text-4xl font-bold mb-4">Vending Machine Management</h1>
      <p class="text-muted-foreground mb-8">
        Manage your vending machine fleet efficiently with real-time insights and remote control capabilities.
      </p>
      <div class="flex justify-center gap-4">
        <UiButton as-child>
          <NuxtLink to="/auth/login">Get Started</NuxtLink>
        </UiButton>
      </div>
    </div>
  </div>
</template>
