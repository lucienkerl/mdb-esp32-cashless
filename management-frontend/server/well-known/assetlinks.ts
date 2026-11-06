import { useRuntimeConfig } from '#imports'
import { defineEventHandler, setResponseHeader, createError } from 'h3'
import { buildAssetLinks, splitList } from '../utils/appAssociation'

// Digital Asset Links for the Android app: lets Google Password Manager,
// 1Password & co. share the dashboard's saved login with the app. 404 until
// a signing certificate fingerprint is configured (Play Console → Test and
// release → App integrity → App signing key certificate).
export default defineEventHandler((event) => {
  const config = useRuntimeConfig(event) as {
    appAssociation?: { androidPackage?: string; androidSha256?: string }
  }
  const body = buildAssetLinks(
    config.appAssociation?.androidPackage,
    splitList(config.appAssociation?.androidSha256),
  )
  if (!body) throw createError({ statusCode: 404, statusMessage: 'Not Found' })
  setResponseHeader(event, 'Content-Type', 'application/json')
  setResponseHeader(event, 'Cache-Control', 'public, max-age=3600')
  return body
})
