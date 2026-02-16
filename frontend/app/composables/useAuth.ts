export function useAuth() {
  const supabase = useSupabaseClient()
  const isLoading = ref(false)

  async function login(email: string, password: string) {
    isLoading.value = true
    try {
      const { data, error } = await supabase.auth.signInWithPassword({
        email,
        password,
      })

      if (error) {
        throw error
      }

      await navigateTo('/')
      return { data, error: null }
    } catch (error: any) {
      return { data: null, error }
    } finally {
      isLoading.value = false
    }
  }

  async function logout() {
    isLoading.value = true
    try {
      const { error } = await supabase.auth.signOut()

      if (error) {
        throw error
      }

      await navigateTo('/auth/login')
      return { error: null }
    } catch (error: any) {
      return { error }
    } finally {
      isLoading.value = false
    }
  }

  async function register(email: string, password: string) {
    isLoading.value = true
    try {
      const { data, error } = await supabase.auth.signUp({
        email,
        password,
      })

      if (error) {
        throw error
      }

      return { data, error: null }
    } catch (error: any) {
      return { data: null, error }
    } finally {
      isLoading.value = false
    }
  }

  return {
    login,
    logout,
    register,
    isLoading: readonly(isLoading),
  }
}
