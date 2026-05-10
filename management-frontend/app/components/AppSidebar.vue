<script setup lang="ts">
import {
  IconBuildingWarehouse,
  IconCash,
  IconChartLine,
  IconCpu,
  IconDashboard,
  IconDeviceMobile,
  IconFileSpreadsheet,
  IconHelp,
  IconHistory,
  IconInbox,
  IconInnerShadowTop,
  IconKey,
  IconPackage,
  IconTag,
  IconUsers,
  IconDevices,
  IconCloudUpload,
} from "@tabler/icons-vue"

import NavMain from '@/components/NavMain.vue'
import NavSecondary from '@/components/NavSecondary.vue'
import NavUser from '@/components/NavUser.vue'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from '@/components/ui/sidebar'

const { t } = useI18n()
const { organization, role } = useOrganization()
const config = useRuntimeConfig()

const versionLine = computed(() => {
  const v = `v${config.public.appVersion}`
  const raw = config.public.buildDate
  if (!raw) return v
  const d = new Date(raw)
  if (isNaN(d.getTime())) return v
  return `${v} · ${d.toLocaleDateString(undefined, { day: '2-digit', month: '2-digit', year: 'numeric' })}`
})

const navGroups = computed(() => {
  const groups = [
    {
      items: [
        {
          title: t('nav.dashboard'),
          url: "/",
          icon: IconDashboard,
        },
      ],
    },
    {
      label: t('nav.groupOperations'),
      items: [
        {
          title: t('nav.machines'),
          url: "/machines",
          icon: IconDevices,
        },
        {
          title: t('nav.products'),
          url: "/products",
          icon: IconPackage,
        },
        {
          title: t('nav.warehouse'),
          url: "/warehouse",
          icon: IconBuildingWarehouse,
        },
        {
          title: t('nav.deals'),
          url: "/deals",
          icon: IconTag,
        },
        {
          title: t('nav.reports'),
          url: "/reports",
          icon: IconFileSpreadsheet,
        },
        {
          title: t('nav.analytics'),
          url: "/analytics",
          icon: IconChartLine,
        },
        {
          title: t('nav.cashBook'),
          url: "/cash-book",
          icon: IconCash,
        },
        {
          title: t('nav.inbox'),
          url: "/inbox",
          icon: IconInbox,
        },
      ],
    },
    {
      label: t('nav.groupTeam'),
      items: [
        {
          title: t('nav.members'),
          url: "/members",
          icon: IconUsers,
        },
        {
          title: t('nav.history'),
          url: "/history",
          icon: IconHistory,
        },
      ],
    },
  ]

  if (role.value === 'admin') {
    groups.push({
      label: t('nav.groupTechnical'),
      items: [
        {
          title: t('nav.devices'),
          url: "/devices",
          icon: IconCpu,
        },
        {
          title: t('nav.firmware'),
          url: "/firmware",
          icon: IconCloudUpload,
        },
        {
          title: t('nav.apiKeys'),
          url: "/api-keys",
          icon: IconKey,
        },
      ],
    })
  }

  return groups
})

const navSecondary = computed(() => [
  {
    title: t('nav.mobileApp'),
    url: "/mobile-app",
    icon: IconDeviceMobile,
  },
  {
    title: t('nav.getHelp'),
    url: "#",
    icon: IconHelp,
  },
])
</script>

<template>
  <Sidebar collapsible="offcanvas">
    <SidebarHeader>
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton
            as-child
            class="data-[slot=sidebar-menu-button]:!p-1.5"
          >
            <NuxtLink to="/">
              <IconInnerShadowTop class="!size-5" />
              <span class="text-base font-semibold">{{ organization?.name ?? t('nav.defaultOrg') }}</span>
            </NuxtLink>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    </SidebarHeader>
    <SidebarContent>
      <NavMain :groups="navGroups" />
      <NavSecondary :items="navSecondary" class="mt-auto" />
    </SidebarContent>
    <SidebarFooter>
      <div class="px-2 pb-1 text-[11px] text-muted-foreground">{{ versionLine }}</div>
      <NavUser />
    </SidebarFooter>
  </Sidebar>
</template>
