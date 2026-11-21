<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

const { t } = useI18n()
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <h1 class="text-2xl font-semibold">{{ t('account.title') }}</h1>
    <div class="grid w-full max-w-3xl gap-6">
      <AccountProfileCard />
      <AccountEmailCard />
      <AccountPasswordCard />
      <AccountAppearanceCard />
      <AccountNotificationSettingsCard />
      <AccountPushNotificationsCard />
    </div>
  </div>
</template>
