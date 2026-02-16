<template>
  <div class="min-h-screen bg-background">
    <!-- Navigation -->
    <AppNavigation />

    <!-- Main content -->
    <main class="flex-1">
      <NuxtPage />
    </main>

    <!-- Footer -->
    <footer class="border-t py-6 md:py-0">
      <div class="container flex flex-col items-center justify-between gap-4 md:h-14 md:flex-row">
        <p class="text-center text-sm leading-loose text-muted-foreground md:text-left">
          Vending Machine Management System
        </p>
      </div>
    </footer>
  </div>
</template>
