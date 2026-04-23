# VMflow Android

Native Android companion app for vending machine operators — feature-paritätisch zur iOS-App [../ios](../ios/), gebaut nach den 2026er Android-Standards.

Spezifikation: [VMFLOW-ANDROID-SPEC.md](VMFLOW-ANDROID-SPEC.md).

## Stack

- **Kotlin 2.1** (K2-Compiler) · **Gradle 8.11** · **AGP 8.10**
- **Jetpack Compose** · **Material 3** (+ Adaptive Layouts, Windows Size Class) · Dynamic Color
- **Hilt** (DI) · **Coroutines + Flow**
- **Supabase Kotlin SDK 3.1** (Postgrest, Realtime, Storage, Auth, Functions)
- **Coil 3** (Bildladen) · **CameraX + ML Kit Barcode** (QR + Produkt-Barcodes)
- **DataStore Preferences** (kein Room, kein XML-Layout)
- **Firebase Cloud Messaging** (ersetzt APNs aus iOS)
- **Edge-to-Edge** (verpflichtend), TalkBack-ready, Full Dark-Mode

## Paket & Flavors

- **Namespace & applicationId**: `de.kerlhandel.vmflow` (angelehnt an iOS `de.kerl-handel.app`)
- **Dev-Flavor** (`dev`): `de.kerlhandel.vmflow.debug`, Supabase-URL auf lokale IP (`http://10.0.1.130:54321` per Default)
- **Prod-Flavor** (`prod`): `de.kerlhandel.vmflow`, Cloud-URL (`https://supabase.kerl-handel.de`)

## Struktur

```
app/src/main/java/de/kerlhandel/vmflow/
├── VMflowApp.kt               @HiltAndroidApp + Notification-Channels
├── MainActivity.kt            Splash + Edge-to-Edge + RootScreen
├── data/
│   ├── model/                 Alle Domain-Models (Organization, VendingMachine, Tray, Sale, Warehouse, Deal, Inbox, Refill, ServerEntry)
│   ├── local/                 DataStore + ServerStore + RefillTourStore + PushTokenStore
│   ├── remote/                SupabaseClientProvider (dynamisch, switch-bar)
│   ├── repository/            Auth, Dashboard, Machine, Tray, Product, Warehouse, Deal, Inbox, Notification, Refill
│   └── realtime/              RealtimeManager (Versions-Counter-Flow)
├── di/
│   ├── CoroutineModule.kt     Dispatchers + ApplicationScope
│   └── SupabaseModule.kt      DataStore
├── push/
│   └── VMflowMessagingService  FCM → Notification mit Deep-Link
├── ui/
│   ├── theme/                 Material 3 Expressive, Dynamic Color, Dark-Mode
│   ├── common/                KpiCard, StatusChip, StockBar, ProductImage, StockHealthIndicator, LocalSupabaseUrl
│   ├── navigation/            Destinations, AuthNavHost, MainScaffold (adaptive: NavigationBar vs. NavigationRail)
│   ├── root/                  RootScreen, RootViewModel, MoreScreen
│   ├── auth/                  Login, Register, ServerSelection, AddServer, QR, ViewModels
│   ├── dashboard/             Dashboard (KPIs, Chart, Recent Sales)
│   ├── machines/              MachineList + MachineDetail (Overview/Trays/Sales-Tabs)
│   ├── trays/                 (inline in MachineDetail — dedizierter Screen folgt)
│   ├── refill/                RefillWizardScreen (Scaffold — 4-Step-Wizard folgt)
│   ├── products/              ProductsScreen (Stub)
│   ├── warehouse/             WarehouseScreen (Stub)
│   ├── deals/                 DealsScreen (Stub)
│   ├── inbox/                 InboxScreen + ViewModel (voll funktional)
│   └── settings/              SettingsScreen (Push-Toggles, Logout)
└── util/
    └── DateFormatting.kt      formatCurrency, WeekBoundaries (Monday-basiert), timeAgo
```

## Build

```bash
# Debug-Build mit lokalem Supabase
./gradlew :app:assembleDevDebug \
  -PSUPABASE_URL_DEV=http://10.0.1.130:54321 \
  -PSUPABASE_ANON_KEY_DEV=sb_publishable_...

# Release-Build gegen die Produktions-Supabase
./gradlew :app:assembleProdRelease \
  -PSUPABASE_URL=https://supabase.kerl-handel.de \
  -PSUPABASE_ANON_KEY=eyJ...
```

Oder via Android Studio Ladybug+:
- Konfiguration in `gradle.properties` oder per CLI-Property überschreiben
- Build Variants: `devDebug` für Entwicklung, `prodRelease` für Play-Store

## FCM-Setup (für Push-Benachrichtigungen)

1. Firebase-Projekt in der Firebase Console anlegen
2. Android-App registrieren: applicationId `de.kerlhandel.vmflow` + `de.kerlhandel.vmflow.debug`
3. `google-services.json` nach `app/` legen (nicht committen — steht in `.gitignore`)
4. Im Backend Edge-Function `register-push` so erweitern, dass sie `platform == "android"` akzeptiert und über FCM sendet (aktuell nur APNs). Erforderliche Secrets:
   - `FCM_PROJECT_ID`
   - `FCM_SERVICE_ACCOUNT_JSON`
   - Einmal in allen sechs Umgebungs-Stellen pflegen (siehe [CLAUDE.md](../CLAUDE.md) §"Adding New Environment Variables").

## Feature-Stand

| Feature | Status |
|---|---|
| Auth (Login, Register) | ✅ |
| Multi-Server (Auswahl, Hinzufügen, Bearbeiten, Löschen) | ✅ |
| QR-Scanner für Server-Provisioning | ⏳ Platzhalter |
| Dashboard (KPIs, 30-Tage-Chart, Recent Sales, Pull-to-Refresh) | ✅ |
| Maschinen-Liste (Such, Stock-Urgency-Sort, Badges) | ✅ |
| Maschinen-Detail (Overview/Trays/Sales-Tabs + Stock-Adjust) | ✅ |
| Tray-Batch-Add / Edit-Sheet | ⏳ Basis da, Sheet folgt |
| Refill-Wizard (4 Schritte) | ⏳ Datenschicht fertig, UI folgt |
| Warehouse | ⏳ Datenschicht fertig, UI folgt |
| Produkte | ⏳ Datenschicht fertig, UI folgt |
| Deals | ⏳ Datenschicht fertig, UI folgt |
| Inbox (Filter, Status-Actions, Delete) | ✅ |
| Settings (Push-Toggles, Test-Push, Sign-Out) | ✅ |
| FCM-Empfang + Deep-Link | ✅ |
| Realtime-Sync (sales, trays, machines, embeddeds, warehouse) | ✅ |
| Adaptive Layout (Phone ↔ Tablet/Foldable) | ✅ |
| i18n (DE/EN) | ✅ |

## Nächste Iterationen

In der aktuellen Session sind Gerüst, Datenschicht, Auth, Dashboard, Maschinen, Navigation, Inbox und Settings voll einsatzfähig. Noch offen (alles mit vollständiger Datenschicht hinterlegt):

1. **Refill-Wizard** — Review → Pack → Refill → Summary mit Tour-Persistence (`RefillTourStore`) und Warehouse-FIFO (`deduct_warehouse_stock_fifo`)
2. **Warehouse** — Bestandsliste, FIFO-Batch-Ansicht, Wareneingang mit Barcode
3. **Produkte** — CRUD + Bild-Upload + DuckDuckGo-Search + Barcode-CRUD
4. **Deals** — Gruppierte Liste, Detail-Sheet
5. **QR-Scanner** — CameraX + ML Kit (Klassen sind im Modul eingebunden)
6. **Tray-Edit-Sheet** als ModalBottomSheet

Alle diese Features haben ihre Repository-Schicht bereits implementiert und warten nur noch auf die UI-Komposition.
