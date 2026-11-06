// Builds the two files password managers use to tie the mobile apps to this
// web origin, so a password saved in the browser on the dashboard is offered
// in the app's login form (and vice versa):
//
//   /.well-known/apple-app-site-association  — iOS `webcredentials:<host>`
//   /.well-known/assetlinks.json             — Android `get_login_creds`
//
// The app side lists this host in its entitlements / asset_statements; both
// sides have to agree, the OS checks the file served here. Pure functions so
// they are unit-tested without a Nitro runtime.

/** Splits a comma/whitespace separated env value into its non-empty parts. */
export function splitList(raw: string | undefined | null): string[] {
  return (raw ?? '')
    .split(/[\s,]+/)
    .map((s) => s.trim())
    .filter(Boolean)
}

/** iOS app ids look like `TEAMID.bundle.id` (team id is 10 upper-case chars). */
const IOS_APP_ID = /^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/

export function buildAppleAppSiteAssociation(iosAppIds: string[]) {
  const apps = iosAppIds.filter((id) => IOS_APP_ID.test(id))
  if (apps.length === 0) return null
  return { webcredentials: { apps } }
}

/** SHA-256 cert fingerprint as Play Console shows it: 32 colon-separated hex bytes. */
const SHA256_FINGERPRINT = /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/

export function normalizeFingerprint(raw: string): string | null {
  const hex = raw.replace(/[^0-9a-fA-F]/g, '').toUpperCase()
  if (hex.length !== 64) return null
  const fp = hex.match(/../g)!.join(':')
  return SHA256_FINGERPRINT.test(fp) ? fp : null
}

export function buildAssetLinks(androidPackage: string | undefined, fingerprints: string[]) {
  const pkg = (androidPackage ?? '').trim()
  const certs = fingerprints
    .map(normalizeFingerprint)
    .filter((fp): fp is string => fp !== null)
  if (!pkg || certs.length === 0) return null
  return [
    {
      relation: ['delegate_permission/common.get_login_creds'],
      target: {
        namespace: 'android_app',
        package_name: pkg,
        sha256_cert_fingerprints: [...new Set(certs)],
      },
    },
  ]
}
