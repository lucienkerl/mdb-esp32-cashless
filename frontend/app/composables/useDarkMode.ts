export function useDarkMode() {
  const isDark = useState('darkMode', () => false)

  function toggle() {
    isDark.value = !isDark.value
    updateClass()
    localStorage.setItem('darkMode', isDark.value ? 'dark' : 'light')
  }

  function updateClass() {
    if (import.meta.client) {
      if (isDark.value) {
        document.documentElement.classList.add('dark')
      } else {
        document.documentElement.classList.remove('dark')
      }
    }
  }

  function init() {
    if (import.meta.client) {
      const stored = localStorage.getItem('darkMode')
      isDark.value = stored === 'dark'
      
      // Check system preference
      if (!stored) {
        isDark.value = window.matchMedia('(prefers-color-scheme: dark)').matches
      }
      updateClass()
    }
  }

  return {
    isDark: computed(() => isDark.value),
    toggle,
    init
  }
}
