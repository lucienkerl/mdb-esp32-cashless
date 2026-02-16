<script setup lang="ts">
import { ref, watch, onMounted } from 'vue'
import { useSupabaseClient } from '#imports'
import { useToast } from '~/components/ui/toast/use-toast'
import { useForm } from 'vee-validate'
import * as z from 'zod'
import { toTypedSchema } from '@vee-validate/zod'

interface Props {
  open?: boolean
}

const props = defineProps<Props>()
const emit = defineEmits<{
  'update:open': [value: boolean]
  success: []
}>()

const supabase = useSupabaseClient()
const { toast } = useToast()

// Form schema
const schema = toTypedSchema(
  z.object({
    operator_id: z.string().uuid('Please select an operator'),
    machine_id: z.string().min(3, 'Machine ID must be at least 3 characters')
  })
)

const { handleSubmit, errors, defineField, resetForm } = useForm({
  validationSchema: schema
})

const [operator_id] = defineField('operator_id')
const [machine_id] = defineField('machine_id')

const operators = ref<Array<{ id: string; email: string }>>([])
const loadingOperators = ref(false)
const submitting = ref(false)

// Fetch operators (users with 'operator' role)
async function fetchOperators() {
  loadingOperators.value = true
  try {
    const { data, error } = await supabase
      .from('user_roles')
      .select(`
        user_id,
        auth:auth.users!user_id(email)
      `)
      .eq('role', 'operator')

    if (error) throw error

    // Map the data to a clean format
    operators.value = (data || []).map((item: any) => ({
      id: item.user_id,
      email: item.auth?.email || 'Unknown'
    }))
  } catch (error: any) {
    console.error('Error fetching operators:', error)
    toast({
      title: 'Error',
      description: error.message || 'Failed to fetch operators',
      variant: 'destructive'
    })
  } finally {
    loadingOperators.value = false
  }
}

const onSubmit = handleSubmit(async (values) => {
  submitting.value = true
  try {
    const { error } = await supabase
      .from('machine_assignments')
      .insert({
        operator_id: values.operator_id,
        machine_id: values.machine_id
      })

    if (error) {
      // Handle unique constraint violation
      if (error.code === '23505') {
        throw new Error('This machine is already assigned to this operator')
      }
      throw error
    }

    toast({
      title: 'Success',
      description: 'Machine assigned successfully'
    })

    // Reset form and close modal
    resetForm()
    emit('update:open', false)
    emit('success')
  } catch (error: any) {
    console.error('Error assigning machine:', error)
    toast({
      title: 'Error',
      description: error.message || 'Failed to assign machine',
      variant: 'destructive'
    })
  } finally {
    submitting.value = false
  }
})

function handleClose() {
  resetForm()
  emit('update:open', false)
}

// Watch for modal open to fetch operators
watch(() => props.open, (isOpen) => {
  if (isOpen) {
    fetchOperators()
  }
})

// Fetch operators on mount if modal is already open
onMounted(() => {
  if (props.open) {
    fetchOperators()
  }
})
</script>

<template>
  <UiDialog :open="open" @update:open="$emit('update:open', $event)">
    <template #default="{ close }">
      <UiDialogHeader>
        <UiDialogTitle>Assign Machine to Operator</UiDialogTitle>
        <UiDialogDescription>
          Select an operator and enter the machine ID to assign.
        </UiDialogDescription>
      </UiDialogHeader>

      <form @submit.prevent="onSubmit">
        <UiDialogContent>
          <div class="space-y-4">
            <!-- Operator Selection -->
            <div class="space-y-2">
              <UiLabel for="operator">Operator</UiLabel>
              <UiSelect
                id="operator"
                v-model="operator_id"
                placeholder="Select an operator"
                :disabled="loadingOperators"
              >
                <option
                  v-for="operator in operators"
                  :key="operator.id"
                  :value="operator.id"
                >
                  {{ operator.email }}
                </option>
              </UiSelect>
              <p v-if="loadingOperators" class="text-sm text-muted-foreground">
                Loading operators...
              </p>
              <p v-if="errors.operator_id" class="text-sm text-destructive">
                {{ errors.operator_id }}
              </p>
              <p v-if="!loadingOperators && operators.length === 0" class="text-sm text-muted-foreground">
                No operators found. Create an operator user first.
              </p>
            </div>

            <!-- Machine ID Input -->
            <div class="space-y-2">
              <UiLabel for="machine_id">Machine ID</UiLabel>
              <UiInput
                id="machine_id"
                v-model="machine_id"
                placeholder="e.g., ESP32-001"
                :disabled="submitting"
              />
              <p v-if="errors.machine_id" class="text-sm text-destructive">
                {{ errors.machine_id }}
              </p>
              <p class="text-sm text-muted-foreground">
                Enter the ESP32 device ID from the MDB hardware
              </p>
            </div>
          </div>
        </UiDialogContent>

        <UiDialogFooter>
          <UiButton
            type="button"
            variant="outline"
            @click="handleClose"
            :disabled="submitting"
          >
            Cancel
          </UiButton>
          <UiButton
            type="submit"
            :disabled="submitting || loadingOperators || operators.length === 0"
          >
            {{ submitting ? 'Assigning...' : 'Assign Machine' }}
          </UiButton>
        </UiDialogFooter>
      </form>
    </template>
  </UiDialog>
</template>
