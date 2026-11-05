# Password managers in the mobile login

Goal: iCloud Keychain, Google Password Manager, 1Password & co. offer the login
saved for the **web dashboard** (`app.kerl-handel.de`) in the iOS and Android
login screen, and save a login made in the app under that same entry.

Both platforms need the app *and* the website to vouch for each other.

| | App side | Website side (served by the Nuxt frontend) |
|---|---|---|
| iOS | `webcredentials:app.kerl-handel.de` in `VMflow*.entitlements` | `/.well-known/apple-app-site-association` (`server/well-known/`) |
| Android | `asset_statements` meta-data → `res/values/asset_statements.xml` | `/.well-known/assetlinks.json` (`server/well-known/`) |
| Field hints | iOS `.textContentType(.username / .password / .newPassword)`; Android `Modifier.semantics { contentType = … }` + `LocalAutofillManager.commit()` after a successful login | — |

The domain is the **frontend**, not `supabase.kerl-handel.de`: that is where
browsers save the password, and Kong does not serve `/.well-known/*`.

## Configuration

- iOS: nothing. The app ids default to `4JT3V7XVXM.de.kerl-handel.app` (+ `.debug`);
  override with `NUXT_APP_ASSOCIATION_IOS_APP_IDS` if needed. Apple's CDN caches the
  file, a change can take up to a day to reach devices (reinstalling the app refetches).
- Android: set `ANDROID_APP_SHA256` in `Docker/.env` to the **app signing key**
  fingerprint from Play Console → Test and release → App integrity (add the
  upload key's too, comma-separated, for sideloaded release builds; debug builds
  use the local debug keystore). Until it is set, `assetlinks.json` returns 404.
  Check with Google's tester:
  `https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://app.kerl-handel.de&relation=delegate_permission/common.get_login_creds`

## Multiple servers

Associations are baked into the signed app, so they can only name domains we
know at build time. For any other server (a self-hosted instance, a custom
entry in the server picker) the password manager still fills the fields thanks
to the hints, but offers the matching entry only after it was saved once from
the app (it is then stored under the app, not the domain) or after the user
links it by hand. The test environment (`app-test.kerl-handel.de`, backend
`supabase-test.kerl-handel.de`) is associated as a second domain and serves the
same files from its own frontend (set `ANDROID_APP_SHA256` there too) — the
managers then offer both entries, they cannot know which server is selected.
