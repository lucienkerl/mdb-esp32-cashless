<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useSupabaseClient } from '#imports'
import { useToast } from '~/components/ui/toast/use-toast'

interface Assignment {
  id: number
  operator_id: string
  machine_id: string
  created_at: string
  operator: {
    email: string
  }
}

const emit = defineEmits<{
  refresh: []
  delete: [assignmentId: number]
}>()

const supabase = useSupabaseClient()
const { toast } = useToast()

const assignments = ref<Assignment[]>([])
const loading = ref(true)
const deleting = ref<number | null>(null)

async function fetchAssignments() {
  loading.value = true
  try {
    const { data, error } = await supabase
      .from('machine_assignments')
      .select(`
        *,
        operator:auth.users!operator_id(email)
      `)
      .order('created_at', { ascending: false })

    if (error) throw error
    
    // Handle the nested user data structure
    assignments.value = (data || []).map((item: any) => ({
      ...item,
      operator: {
        email: item.operator?.email || 'Unknown'
      }
    }))
  } catch (error: any) {
    console.error('Error fetching assignments:', error)
    toast({
      title: 'Error',
      description: error.message || 'Failed to fetch machine assignments',
      variant: 'destructive'
    })
  } finally {
    loading.value = false
  }
}

async function handleDelete(assignmentId: number) {
  if (!confirm('Are you sure you want to remove this machine assignment?')) {
    return
  }

  deleting.value = assignmentId
  try {
    const { error } = await supabase
      .from('machine_assignments')
      .delete()
      .eq('id', assignmentId)

    if (error) throw error

    toast({
      title: 'Success',
      description: 'Machine assignment removed'
    })

    // Refresh the list
    await fetchAssignments()
    emit('refresh')
  } catch (error: any) {
    console.error('Error deleting assignment:', error)
    toast({
      title: 'Error',
      description: error.message || 'Failed to delete assignment',
      variant: 'destructive'
    })
  } finally {
    deleting.value = null
  }
}

onMounted(() => {
  fetchAssignments()
})

// Expose method for parent to trigger refresh
defineExpose({
  refresh: fetchAssignments
})
</script>

<template>
  <div class="space-y-4">
    <!-- Loading State -->
    <div v-if="loading" class="flex items-center justify-center py-8">
      <p class="text-muted-foreground">Loading assignments...</p>
    </div>

    <!-- Empty State -->
    <div
      v-else-if="assignments.length === 0"
      class="flex flex-col items-center justify-center py-12 text-center"
    >
      <p class="text-muted-foreground mb-2">No machine assignments yet</p>
      <p class="text-sm text-muted-foreground">
        Click "Assign Machine" to assign machines to operators
      </p>
    </div>

    <!-- Assignments Table -->
    <div v-else class="border rounded-lg">
      <UiTable>
        <UiTableHeader>
          <UiTableRow>
            <UiTableHead>Operator Email</UiTableHead>
            <UiTableHead>Machine ID</UiTableHead>
            <UiTableHead>Assigned Date</UiTableHead>
            <UiTableHead class="text-right">Actions</UiTableHead>
          </UiTableRow>
        </UiTableHeader>
        <UiTableBody>
          <UiTableRow v-for="assignment in assignments" :key="assignment.id">
            <UiTableCell class="font-medium">
              {{ assignment.operator.email }}
            </UiTableCell>
            <UiTableCell>
              <code class="text-xs bg-muted px-2 py-1 rounded">
                {{ assignment.machine_id }}
              </code>
            </UiTableCell>
            <UiTableCell class="text-muted-foreground">
              {{ new Date(assignment.created_at).toLocaleDateString() }}
            </UiTableCell>
            <UiTableCell class="text-right">
              <UiButton
                variant="ghost"
                size="sm"
                :disabled="deleting === assignment.id"
                @click="handleDelete(assignment.id)"
              >
                {{ deleting === assignment.id ? 'Deleting...' : 'Remove' }}
              </UiButton>
            </UiTableCell>
          </UiTableRow>
        </UiTableBody>
      </UiTable>
    </div>
  </div>
</template>
