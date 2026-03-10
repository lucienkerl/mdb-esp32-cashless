// v2 — Plain service worker — no workbox, no precache.
// Exists solely for push notification handling.

self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting())
})
self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim())
})

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting()
  }
})

self.addEventListener('push', (event) => {
  if (!event.data) return

  let payload
  try {
    payload = event.data.json()
  } catch (e) {
    payload = { title: 'VMflow', body: event.data.text() }
  }

  const title = payload.title || 'VMflow'
  const options = {
    body: payload.body || '',
    icon: payload.image || payload.icon,
    image: payload.image,
    data: payload.data || {},
    tag: payload.data && payload.data.type ? String(payload.data.type) : undefined,
  }

  event.waitUntil(self.registration.showNotification(title, options))
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()

  const data = event.notification.data || {}

  let targetUrl = '/'
  if (data.type === 'sale' && data.embedded_id) {
    targetUrl = '/machines'
  } else if (data.type === 'low_stock' && data.machine_id) {
    targetUrl = '/machines/' + data.machine_id
  }

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clientList) {
      for (var i = 0; i < clientList.length; i++) {
        var client = clientList[i]
        if (new URL(client.url).origin === self.location.origin && 'focus' in client) {
          client.focus()
          client.navigate(targetUrl)
          return
        }
      }
      return self.clients.openWindow(targetUrl)
    })
  )
})
