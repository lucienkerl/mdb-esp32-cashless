import { useRuntimeConfig } from '#imports'
import { defineEventHandler, setResponseHeader, createError } from 'h3'
import { buildAppleAppSiteAssociation, splitList } from '../utils/appAssociation'

// Served without a file extension and as JSON, without redirects — that is
// what Apple's CDN (and swcd) require. Lets the iOS app's
// `webcredentials:<this host>` entitlement validate, so iCloud Keychain /
// 1Password offer the dashboard's saved login in the app.
export default defineEventHandler((event) => {
  const config = useRuntimeConfig(event) as { appAssociation?: { iosAppIds?: string } }
  const body = buildAppleAppSiteAssociation(splitList(config.appAssociation?.iosAppIds))
  if (!body) throw createError({ statusCode: 404, statusMessage: 'Not Found' })
  setResponseHeader(event, 'Content-Type', 'application/json')
  setResponseHeader(event, 'Cache-Control', 'public, max-age=3600')
  return body
})
