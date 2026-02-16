export default defineNuxtRouteMiddleware((to, _from) => {
  const session = useSupabaseSession()
  const { isAdmin } = useRole()

  // Check if user is authenticated
  if (!session.value) {
    return navigateTo('/auth/login')
  }

  // Check if user is an admin
  if (!isAdmin.value) {
    // Redirect non-admin users to dashboard
    return navigateTo('/')
  }
})
