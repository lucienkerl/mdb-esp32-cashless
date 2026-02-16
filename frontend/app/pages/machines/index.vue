<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useSupabaseClient, useSupabaseUser } from '#imports'

definePageMeta({
  middleware: ['auth']
})

const supabase = useSupabaseClient()
const user = useSupabaseUser()

interface MachineAssignment {
  machine_id: string
  created_at: string
}

const assignments = ref<MachineAssignment[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

async function fetchAssignedMachines() {
  if (!user.value?.id) {
    loading.value = false
    return
  }

  loading.value = true
  error.value = null

  try {
    const { data, error: fetchError } = await supabase
      .from('machine_assignments')
      .select('machine_id, created_at')
      .eq('operator_id', user.value.id)
      .order('created_at', { ascending: false })

    if (fetchError) throw fetchError

    assignments.value = data || []
  } catch (err: any) {
    console.error('Error fetching assigned machines:', err)
    error.value = err.message || 'Failed to fetch assigned machines'
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  fetchAssignedMachines()
})
</script>

<template>
  <div class="container mx-auto py-8 space-y-6">
    <!-- Page Header -->
    <div>
      <h1 class="text-3xl font-bold tracking-tight">My Machines</h1>
      <p class="text-muted-foreground mt-1">
        View machines assigned to you
      </p>
    </div>

    <!-- Loading State -->
    <UiCard v-if="loading">
      <UiCardContent class="py-12">
        <div class="flex items-center justify-center">
          <p class="text-muted-foreground">Loading your machines...</p>
        </div>
      </UiCardContent>
    </UiCard>

    <!-- Error State -->
    <UiCard v-else-if="error">
      <UiCardContent class="py-12">
        <div class="flex flex-col items-center justify-center text-center space-y-2">
          <p class="text-destructive font-medium">Error loading machines</p>
          <p class="text-sm text-muted-foreground">{{ error }}</p>
          <UiButton variant="outline" size="sm" @click="fetchAssignedMachines">
            Try Again
          </UiButton>
        </div>
      </UiCardContent>
    </UiCard>

    <!-- Empty State -->
    <UiCard v-else-if="assignments.length === 0">
      <UiCardContent class="py-12">
        <div class="flex flex-col items-center justify-center text-center space-y-2">
          <p class="text-muted-foreground font-medium">No machines assigned to you</p>
          <p class="text-sm text-muted-foreground">
            Contact your administrator to get machines assigned
          </p>
        </div>
      </UiCardContent>
    </UiCard>

    <!-- Machine List -->
    <div v-else class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
      <UiCard v-for="assignment in assignments" :key="assignment.machine_id">
        <UiCardHeader>
          <UiCardTitle class="text-base">
            <code class="text-sm bg-muted px-2 py-1 rounded">
              {{ assignment.machine_id }}
            </code>
          </UiCardTitle>
          <UiCardDescription>
            Assigned {{ new Date(assignment.created_at).toLocaleDateString() }}
          </UiCardDescription>
        </UiCardHeader>
        <UiCardContent>
          <div class="text-sm text-muted-foreground">
            <p>Machine details and controls will be available in Phase 2</p>
          </div>
        </UiCardContent>
      </UiCard>
    </div>
  </div>
</template>
