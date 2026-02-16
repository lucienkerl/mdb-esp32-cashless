<template>
  <div class="min-h-screen bg-background">
    <!-- Header placeholder - navigation will be built in Plan 04 -->
    <header class="sticky top-0 z-50 w-full border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60">
      <div class="container flex h-14 items-center">
        <div class="mr-4 flex">
          <a href="/" class="mr-6 flex items-center space-x-2">
            <span class="font-bold">Vending Manager</span>
          </a>
        </div>
        <!-- Navigation placeholder -->
        <nav class="flex items-center space-x-6 text-sm font-medium">
          <!-- Nav items will be added in Plan 04 -->
        </nav>
      </div>
    </header>

    <!-- Main content -->
    <main class="flex-1">
      <slot />
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
