# VMflow Android App

Native Android companion app for vending machine operators. Built with Kotlin + Jetpack Compose + Material 3.

## Features

- **Dashboard** — KPI cards (revenue, sales, machine status, stock alerts), quick actions, recent sales feed
- **Machine Management** — Browse machines sorted by stock urgency, view per-machine details (overview, trays, sales history)
- **Tray Configuration** — Full CRUD for machine tray slots: add single/batch, edit, delete, quick stock adjustments
- **Refill Wizard** — Multi-step guided refill tour (pack, refill per machine, summary) optimized for one-handed field use
- **Deals** — Retailer offers matching your products (from the dashboard banner or the top-bar tag icon): grouped by validity so offers that only start later are clearly marked ("valid from Mon, 28.09."), plus pin/archive, NEW markers and a purchase-price (EK) comparison

## Setup

### Prerequisites

- Android Studio Ladybug (2024.2) or later
- Android SDK 26+ (Android 8.0)
- A running VMflow backend (Supabase + MQTT via Docker)

### Steps

1. Open the `android/` folder in Android Studio
2. Configure your Supabase credentials in `gradle.properties`:
   ```properties
   SUPABASE_URL=http://10.0.1.181:8000
   SUPABASE_ANON_KEY=your-anon-key-here
   ```
3. Sync Gradle and run on a device or emulator

### Build Configuration

Supabase URL and anon key are injected via `BuildConfig` fields defined in `app/build.gradle`. You can override them in `gradle.properties` or pass them as Gradle properties:

```bash
./gradlew assembleRelease -PSUPABASE_URL=https://your-instance.supabase.co -PSUPABASE_ANON_KEY=your-key
```

## Releasing to Google Play

Releases go out through GitHub Actions → **Android Release**, which runs the
fastlane lanes in `fastlane/Fastfile`: `internal` (internal testing track),
`release` (production, with auto-generated release notes), `promote` (move the
tested build to production without rebuilding), `metadata` (store listing only)
and `release_notes` (dry run).

The one-time account, keystore and service-account setup — and the fact that
Play requires the very first upload to go through the console by hand — is in
[docs/android/play-console-setup.md](../docs/android/play-console-setup.md).

Do not upload from your machine: `versionCode` is derived from the build date
plus the day's commit count, and a local upload burns a number CI cannot reuse.
Local release builds come out unsigned on purpose when the keystore env vars
are absent.

## Architecture

- **MVVM** pattern with Jetpack Compose + ViewModels
- **Kotlin Coroutines + Flow** for reactive state management
- **Supabase Kotlin SDK** (`io.github.jan-tennert.supabase`) for auth, database, and storage
- **Ktor** HTTP engine for Supabase SDK
- **Coil** for async image loading from Supabase Storage
- **Material 3** with dynamic color support and dark theme

### Structure

```
app/src/main/java/xyz/vmflow/
  VMflowApp.kt              — Application class
  MainActivity.kt            — Single-activity Compose host
  Navigation.kt              — NavHost with type-safe routes
  models/
    Models.kt                — Data classes matching Supabase schema
  data/
    SupabaseService.kt       — Singleton Supabase client
    AuthRepository.kt        — Auth state as StateFlow
    MachineRepository.kt     — Machine queries + stats aggregation
    TrayRepository.kt        — Tray CRUD operations
    RefillRepository.kt      — Refill wizard data operations
    WarehouseRepository.kt   — Warehouse stock queries
  ui/
    auth/                    — Login, Register screens
    dashboard/               — Dashboard, KPI cards
    machines/                — Machine list, detail, cards
    trays/                   — Tray list, edit dialog, rows
    refill/                  — Wizard: packing, refill, summary
    components/              — Reusable: StatusChip, StockBar, ProductImage
    theme/                   — Material 3 colors, typography, theme
```

## Data Flow

1. `AuthRepository` manages session state via `StateFlow`
2. On login, the app fetches the organization via `get-my-organization` edge function
3. Repositories query Supabase tables using the Kotlin SDK
4. Product images load from Supabase Storage (`product-images` bucket) via Coil
5. All prices are in EUR (not cents), matching the backend schema

## Dependencies

| Library | Purpose |
|---------|---------|
| Jetpack Compose + Material 3 | UI framework |
| Supabase Kotlin SDK | Backend communication |
| Ktor | HTTP engine |
| Coil | Image loading |
| kotlinx-serialization | JSON parsing |
| kotlinx-datetime | Date/time handling |
