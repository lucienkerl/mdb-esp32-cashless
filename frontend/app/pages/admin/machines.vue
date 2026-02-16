<script setup lang="ts">
import { ref } from 'vue'

definePageMeta({
  middleware: ['auth', 'admin']
})

const modalOpen = ref(false)
const assignmentListRef = ref<{ refresh: () => void } | null>(null)

function openModal() {
  modalOpen.value = true
}

function handleAssignmentSuccess() {
  // Refresh the assignment list when a new assignment is created
  assignmentListRef.value?.refresh()
}
</script>

<template>
  <div class="container mx-auto py-8 space-y-6">
    <!-- Page Header -->
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-3xl font-bold tracking-tight">Machine Assignments</h1>
        <p class="text-muted-foreground mt-1">
          Assign machines to operators to control their access
        </p>
      </div>
      <UiButton @click="openModal">
        Assign Machine
      </UiButton>
    </div>

    <!-- Assignment List Card -->
    <UiCard>
      <UiCardHeader>
        <UiCardTitle>Current Assignments</UiCardTitle>
        <UiCardDescription>
          Manage operator access to vending machines
        </UiCardDescription>
      </UiCardHeader>
      <UiCardContent>
        <MachinesMachineAssignmentList
          ref="assignmentListRef"
          @refresh="() => {}"
        />
      </UiCardContent>
    </UiCard>

    <!-- Assignment Modal -->
    <MachinesAssignMachineModal
      v-model:open="modalOpen"
      @success="handleAssignmentSuccess"
    />
  </div>
</template>
