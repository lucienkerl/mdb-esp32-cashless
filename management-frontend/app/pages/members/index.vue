<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { formatDate } from '@/lib/utils'
import { useClipboard } from '@vueuse/core'

const { t } = useI18n()
const supabase = useSupabaseClient()
const { role } = useOrganization()

const members = ref<any[]>([])
const invitations = ref<any[]>([])
const loading = ref(true)

const inviteUrl = ref('')
const { copy, copied } = useClipboard({ copiedDuring: 2000 })

const isAdmin = computed(() => role.value === 'admin')

import { fuzzyFilter } from '@/lib/fuzzySearch'

const memberSearch = ref('')
const { toggleSort: toggleMemberSort, sortIcon: memberSortIcon, sortKey: memberSortKey, sortDir: memberSortDir } = useTableSort<'name' | 'role' | 'joined'>('name')

const sortedMembers = computed(() => {
  const filtered = fuzzyFilter(members.value, memberSearch.value, [
    m => memberDisplayName(m),
    m => m.email,
    m => m.role,
  ])
  const dir = memberSortDir.value === 'asc' ? 1 : -1
  return [...filtered].sort((a, b) => {
    if (memberSortKey.value === 'name') return dir * memberDisplayName(a).localeCompare(memberDisplayName(b))
    if (memberSortKey.value === 'role') return dir * (a.role ?? '').localeCompare(b.role ?? '')
    return dir * (a.created_at ?? '').localeCompare(b.created_at ?? '')
  })
})

async function loadData() {
  loading.value = true
  const [membersRes, invitesRes, usersRes] = await Promise.all([
    supabase.from('organization_members').select('id, created_at, user_id, role, invited_by'),
    supabase.from('invitations').select('id, created_at, email, role, token, expires_at, accepted_at, invited_by'),
    supabase.from('users').select('id, first_name, last_name, email'),
  ])

  // Build user lookup map (id → { first_name, last_name, email })
  const userMap = new Map<string, { first_name: string | null; last_name: string | null; email: string | null }>()
  for (const u of (usersRes.data ?? []) as any[]) {
    userMap.set(u.id, { first_name: u.first_name, last_name: u.last_name, email: u.email })
  }

  members.value = ((membersRes.data ?? []) as any[]).map(m => ({
    ...m,
    first_name: userMap.get(m.user_id)?.first_name ?? null,
    last_name: userMap.get(m.user_id)?.last_name ?? null,
    email: userMap.get(m.user_id)?.email ?? null,
  }))
  invitations.value = (invitesRes.data ?? []).filter((i: any) => !i.accepted_at)
  loading.value = false
}

function memberDisplayName(member: any): string {
  const parts = [member.first_name, member.last_name].filter(Boolean)
  return parts.length > 0 ? parts.join(' ') : '—'
}

onMounted(async () => {
  await loadData()
})

const {
  open: showInviteModal,
  form: inviteForm,
  loading: inviteLoading,
  error: inviteError,
  openModal: openInviteModal,
  closeModal: closeInviteModal,
  submit,
} = useModalForm({ email: '', role: 'viewer' as 'admin' | 'viewer' })

async function sendInvite() {
  await submit(async () => {
    const { data, error } = await supabase.functions.invoke('invite-member', {
      body: { email: inviteForm.value.email, role: inviteForm.value.role },
    })
    if (error) throw error
    if (data?.error) throw new Error(data.error)
    inviteUrl.value = `${window.location.origin}/auth/register?token=${data.token}`
    await loadData()
  }, { closeOnSuccess: false })
}

function handleOpenInviteModal() {
  inviteUrl.value = ''
  openInviteModal()
}

async function changeRole(memberId: string, newRole: string) {
  await supabase.from('organization_members').update({ role: newRole }).eq('id', memberId)
  await loadData()
}

async function removeMember(memberId: string) {
  await supabase.from('organization_members').delete().eq('id', memberId)
  await loadData()
}

async function revokeInvitation(invitationId: string) {
  await supabase.from('invitations').delete().eq('id', invitationId)
  await loadData()
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-2xl font-semibold">{{ t('members.title') }}</h1>
          <button
            v-if="isAdmin"
            class="shrink-0 inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
            @click="handleOpenInviteModal"
          >
            {{ t('members.inviteMember') }}
          </button>
        </div>

        <div v-if="loading" class="text-muted-foreground">{{ t('members.loadingMembers') }}</div>

        <template v-else>
          <!-- Active members -->
          <div>
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-base font-medium">{{ t('members.activeMembers') }}</h2>
              <SearchInput v-model="memberSearch" :placeholder="t('common.search') + '...'" class="max-w-xs" />
            </div>
            <div v-if="sortedMembers.length === 0" class="text-sm text-muted-foreground mb-4">{{ t('common.noResults') }}</div>
            <div v-else class="overflow-x-auto rounded-md border">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b bg-muted/50 text-left">
                    <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleMemberSort('name')">
                      <SortHeader :icon="memberSortIcon('name')">{{ t('members.nameCol') }}</SortHeader>
                    </th>
                    <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleMemberSort('role')">
                      <SortHeader :icon="memberSortIcon('role')">{{ t('members.roleCol') }}</SortHeader>
                    </th>
                    <th class="hidden sm:table-cell px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleMemberSort('joined')">
                      <SortHeader :icon="memberSortIcon('joined')">{{ t('members.joinedCol') }}</SortHeader>
                    </th>
                    <th v-if="isAdmin" class="px-4 py-3 font-medium">{{ t('common.actions') }}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="member in sortedMembers"
                    :key="member.id"
                    class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                  >
                    <td class="px-4 py-3">
                      <div>
                        <span class="font-medium">{{ memberDisplayName(member) }}</span>
                        <p class="text-xs text-muted-foreground">{{ member.email ?? member.user_id }}</p>
                      </div>
                    </td>
                    <td class="px-4 py-3">
                      <span
                        class="rounded-full px-2 py-0.5 text-xs font-medium"
                        :class="member.role === 'admin' ? 'bg-primary/10 text-primary' : 'bg-muted text-muted-foreground'"
                      >
                        {{ t(`members.roles.${member.role}`) }}
                      </span>
                    </td>
                    <td class="hidden sm:table-cell px-4 py-3 text-muted-foreground">{{ formatDate(member.created_at) }}</td>
                    <td v-if="isAdmin" class="px-4 py-3">
                      <div class="flex items-center gap-2">
                        <select
                          :value="member.role"
                          class="rounded border border-input bg-background px-2 py-1 text-xs"
                          @change="changeRole(member.id, ($event.target as HTMLSelectElement).value)"
                        >
                          <option value="admin">{{ t('members.roles.admin') }}</option>
                          <option value="viewer">{{ t('members.roles.viewer') }}</option>
                        </select>
                        <button
                          class="text-xs text-destructive hover:underline"
                          @click="removeMember(member.id)"
                        >
                          {{ t('common.remove') }}
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- Pending invitations -->
          <div v-if="isAdmin">
            <h2 class="mb-3 text-base font-medium">{{ t('members.pendingInvitations') }}</h2>
            <div v-if="invitations.length === 0" class="text-sm text-muted-foreground">{{ t('members.noPendingInvitations') }}</div>
            <div v-else class="overflow-x-auto rounded-md border">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b bg-muted/50 text-left">
                    <th class="px-4 py-3 font-medium">{{ t('members.emailCol') }}</th>
                    <th class="px-4 py-3 font-medium">{{ t('members.roleCol') }}</th>
                    <th class="hidden sm:table-cell px-4 py-3 font-medium">{{ t('members.expiresCol') }}</th>
                    <th class="px-4 py-3 font-medium">{{ t('common.actions') }}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="invitation in invitations"
                    :key="invitation.id"
                    class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                  >
                    <td class="px-4 py-3">{{ invitation.email }}</td>
                    <td class="px-4 py-3">
                      <span class="rounded-full bg-muted px-2 py-0.5 text-xs font-medium text-muted-foreground">
                        {{ t(`members.roles.${invitation.role}`) }}
                      </span>
                    </td>
                    <td class="hidden sm:table-cell px-4 py-3 text-muted-foreground">{{ formatDate(invitation.expires_at) }}</td>
                    <td class="px-4 py-3">
                      <button
                        class="text-xs text-destructive hover:underline"
                        @click="revokeInvitation(invitation.id)"
                      >
                        {{ t('common.revoke') }}
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </template>
      </div>

      <!-- Invite modal -->
      <AppModal
        :open="showInviteModal"
        :title="inviteUrl ? t('members.invitationLink') : t('members.inviteAMember')"
        @update:open="(v) => { if (!v) { closeInviteModal(); inviteUrl = '' } }"
      >
        <!-- Step 1: Form -->
        <template v-if="!inviteUrl">
          <form class="space-y-4" @submit.prevent="sendInvite">
            <div class="space-y-1">
              <label class="text-sm font-medium" for="invite-email">{{ t('common.email') }}</label>
              <input
                id="invite-email"
                v-model="inviteForm.email"
                type="email"
                required
                placeholder="colleague@example.com"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <div class="space-y-1">
              <label class="text-sm font-medium" for="invite-role">{{ t('members.roleCol') }}</label>
              <select
                id="invite-role"
                v-model="inviteForm.role"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              >
                <option value="viewer">{{ t('members.roles.viewer') }}</option>
                <option value="admin">{{ t('members.roles.admin') }}</option>
              </select>
            </div>
            <FormError :message="inviteError" />
            <div class="flex gap-2">
              <button
                type="button"
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
                @click="closeInviteModal(); inviteUrl = ''"
              >
                {{ t('common.cancel') }}
              </button>
              <button
                type="submit"
                :disabled="inviteLoading"
                class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
              >
                <span v-if="inviteLoading">{{ t('members.sending') }}</span>
                <span v-else>{{ t('members.sendInvite') }}</span>
              </button>
            </div>
          </form>
        </template>

        <!-- Step 2: Invite link -->
        <template v-else>
          <p class="mb-4 text-sm text-muted-foreground">
            {{ t('members.inviteLinkDescription') }}
          </p>

          <div class="mb-4 flex items-stretch gap-2">
            <div class="flex-1 overflow-hidden rounded-md border border-input bg-muted/50 px-3 py-2">
              <p class="truncate font-mono text-xs text-muted-foreground">{{ inviteUrl }}</p>
            </div>
            <button
              class="inline-flex shrink-0 items-center justify-center rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
              @click="copy(inviteUrl)"
            >
              {{ copied ? t('common.copied') : t('common.copy') }}
            </button>
          </div>

          <button
            class="inline-flex h-9 w-full items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
            @click="closeInviteModal(); inviteUrl = ''"
          >
            {{ t('common.done') }}
          </button>
        </template>
      </AppModal>
</template>
