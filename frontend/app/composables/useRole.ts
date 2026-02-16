import { jwtDecode } from 'jwt-decode'

interface CustomJwtPayload {
  user_role?: 'admin' | 'operator'
}

export function useRole() {
  const session = useSupabaseSession()

  const userRole = computed((): 'admin' | 'operator' | null => {
    if (!session.value?.access_token) return null
    try {
      const decoded = jwtDecode<CustomJwtPayload>(session.value.access_token)
      return decoded.user_role || 'operator'
    } catch {
      return null
    }
  })

  const isAdmin = computed((): boolean => userRole.value === 'admin')
  const isOperator = computed((): boolean => userRole.value === 'operator')

  return {
    userRole,
    isAdmin,
    isOperator,
  }
}
