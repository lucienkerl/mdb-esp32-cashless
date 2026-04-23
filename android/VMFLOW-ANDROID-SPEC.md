# VMflow Android — Neubau-Spezifikation

> Dieses Dokument ist die vollständige Spezifikation für einen **Neubau** der nativen VMflow Android App nach dem heutigen Stand der Technik (2026). Referenz ist die native iOS App unter [ios/VMflow](../ios/VMflow). Die App muss **feature-paritätisch** zu iOS 1.0 (Build 955) sein.
>
> Backend (Supabase + MQTT) ist identisch zur iOS App — siehe [CLAUDE.md](../CLAUDE.md) für Details. Dieser Text beschreibt **nur** die Client-Seite.

---

## Inhaltsverzeichnis

1. [Überblick & Ziele](#1-überblick--ziele)
2. [Technologie-Stack](#2-technologie-stack)
3. [Projekt-Struktur](#3-projekt-struktur)
4. [Build- & Umgebungs-Konfiguration](#4-build---umgebungs-konfiguration)
5. [Datenschicht](#5-datenschicht)
6. [Auth & Organisation](#6-auth--organisation)
7. [Server-Auswahl (Multi-Environment)](#7-server-auswahl-multi-environment)
8. [Navigation (Adaptive)](#8-navigation-adaptive)
9. [Realtime](#9-realtime)
10. [Push-Benachrichtigungen (FCM)](#10-push-benachrichtigungen-fcm)
11. [Feature-Spezifikationen](#11-feature-spezifikationen)
12. [UI-Komponenten & Design-System](#12-ui-komponenten--design-system)
13. [Kamera & Barcode-Scanning](#13-kamera--barcode-scanning)
14. [Haptik, i18n, A11y](#14-haptik-i18n-a11y)
15. [Testing](#15-testing)
16. [Release-Checkliste](#16-release-checkliste)
17. [iOS → Android Mapping-Referenz](#17-ios--android-mapping-referenz)

---

## 1. Überblick & Ziele

VMflow ist die Bediener-App für Automatenbetreiber: KPIs, Automaten-Übersicht, Tray-Verwaltung, geführter Nachfüll-Workflow, Lager, Deals, Inbox für Kunden-Feedback. Das Backend ist Self-Hosted Supabase + Mosquitto MQTT; IoT-Geräte (ESP32) werden nicht direkt von der App gesteuert, sondern über die DB / Edge-Functions.

### Nicht-funktionale Anforderungen

- **Minimum API 26 (Android 8.0)** — angelehnt an iOS 17 Baseline, deckt ≥98 % aktiver Geräte
- **Target API 35** (Android 15)
- **Edge-to-edge Layout** verpflichtend (Android 15+ erzwingt das)
- **Material 3 Expressive** als Design-Grundlage (2025/26 Update des Material-Systems)
- **Vollständige Compose UI** — kein Fragment, kein XML-Layout außerhalb des Launch-Screens
- **Adaptives Layout** für Handy, Foldable und Tablet über `WindowSizeClass`
- **Dynamic Color** + vollständiger Dark-Mode
- **Offline-toleranz**: keine Offline-First-Datenbank, aber keine Crashes ohne Netz — Fehler-Zustände wie iOS
- **i18n**: Englisch + Deutsch, gleiche Strings wie iOS
- **Accessibility**: TalkBack, Large Text, Content-Descriptions für alle interaktiven Elemente
- **Feature-Parity** zur iOS App (Version 1.0, Build 955) — kein Feature fehlt, kein Extra hinzu
- **Keine fremden Analytics**; genau wie iOS

### Feature-Liste (Parität)

| Feature | iOS-Quelle | Android-Ziel |
|---|---|---|
| Login/Register | `Views/Auth/LoginView.swift`, `RegisterView.swift` | `LoginScreen`, `RegisterScreen` |
| Server-Auswahl (lokal ↔ Cloud) | `Views/Auth/ServerSelectionSheet.swift` | Bottom-Sheet `ServerSelectionSheet` |
| Dashboard mit KPIs + 30-Tage-Chart | `Views/Dashboard/DashboardView.swift` | `DashboardScreen` |
| Maschinenliste mit Stock-Dringlichkeit | `Views/Machines/MachineListView.swift` | `MachinesScreen` |
| Maschinen-Detail (Trays, Sales, Insights) | `Views/Machines/MachineDetailView.swift` | `MachineDetailScreen` |
| Tray-CRUD (Einzel + Batch) | `Views/Trays/TrayListView.swift`, `TrayEditSheet.swift` | `TrayListScreen`, `TrayEditSheet` |
| Refill-Wizard (4 Schritte) | `Views/Refill/RefillWizardView.swift`+Substeps | `RefillWizardScreen` mit `Step1..Step4` |
| Produkt-Verwaltung (CRUD + Barcode) | `Views/Products/ProductsView.swift` | `ProductsScreen`, `ProductEditSheet` |
| Lager (Bestand + Batch + FIFO) | `Views/Warehouse/WarehouseView.swift` | `WarehouseScreen`, `ProductBatchesScreen`, `BatchAdjustSheet` |
| Deal-Suche (externe Angebote) | `Views/Deals/DealsView.swift` | `DealsScreen` |
| Inbox (Kunden-Feedback) | `Views/Inbox/InboxView.swift` | `InboxScreen` |
| Einstellungen (Push, Deals, Logout) | `Views/Settings/SettingsView.swift` | `SettingsScreen` |
| Push-Benachrichtigungen | APNs + `NotificationService.swift` | FCM + `NotificationService` + Background-Worker |
| Deep-Link aus Push in Inbox | `DeepLink.inbox` | `NavController` mit Deep-Link-Intent |
| Realtime-Synchronisation | `Services/RealtimeService.swift` | `RealtimeManager` (Supabase Kotlin SDK) |

---

## 2. Technologie-Stack

### Sprache & Build

- **Kotlin 2.2+** (K2-Compiler, stabil seit 2.0)
- **Android Gradle Plugin 8.10+**
- **Gradle 8.11+** mit Version-Catalog (`libs.versions.toml`)
- **JDK 21** für den Build-Prozess, `compileSdk 35`, `targetSdk 35`, `minSdk 26`

### UI

- **Jetpack Compose Material3** (`androidx.compose.material3:material3` ≥ 1.4.x — Expressive-Updates)
- **Material3 Adaptive** (`androidx.compose.material3.adaptive:adaptive-navigation`) für List-Detail / Supporting-Pane Layouts
- **`WindowSizeClass`** aus `material3-window-size-class`
- **Accompanist** nur wo absolut nötig (z. B. `permissions` falls die offizielle APIs nicht reicht; alles andere ist seit 2024 in Compose BOM integriert)
- **Coil 3** (`io.coil-kt.coil3:coil-compose`) für Bilder aus Supabase Storage
- **Vico 2** oder **Compose Canvas** für das 30-Tage-Umsatz-Chart (analog Swift Charts)
- **Lottie Compose** nur, falls Animationen benötigt werden (aktuell keine)

### Architektur & DI

- **MVVM mit ViewModel + StateFlow** — Repository-Pattern dazwischen (wichtig, weil iOS ViewModels direkt DB-Queries schreiben; der Android-Neubau zieht die Queries in Repositories, um Testbarkeit zu bekommen)
- **Hilt** (`com.google.dagger:hilt-android`) für DI
- **Kotlinx Coroutines + Flow** als Concurrency-Modell (entspricht iOS `async/await` + `Combine`)

### Netzwerk & Backend

- **Supabase Kotlin SDK** (`io.github.jan-tennert.supabase:*`) — Module: `auth-kt`, `postgrest-kt`, `realtime-kt`, `storage-kt`, `functions-kt`
- **Ktor** (Client-Engine für Supabase SDK) — `ktor-client-okhttp` oder `ktor-client-cio`
- **kotlinx.serialization** für JSON-Decoding
- **kotlinx.datetime** für Datums-/Zeit-Logik (analog `Foundation.Date`)

### Persistenz (lokal)

- **DataStore Preferences** für kleine Werte (Server-Liste, ausgewählter Server, FCM-Token-Cache, letzter Push-Permission-Zustand, Refill-Tour-State-Key) — ersetzt iOS `UserDefaults`
- **KEIN Room** — genau wie iOS keine lokale DB; nur flüchtiger Cache im Repository
- **EncryptedSharedPreferences** nur für Session-Recovery-Token, falls nötig. Supabase Kotlin SDK bringt eigenen Session-Manager mit (`SettingsSessionManager` auf Basis `datastore-preferences`)

### Push & FCM

- **Firebase Cloud Messaging** (`com.google.firebase:firebase-messaging`) — ersetzt APNs
- **Firebase BoM** aktuellste Version
- **`FirebaseMessagingService`** für Token-Handling und Empfang
- **Kein Push-Image-Extension** nötig — FCM unterstützt `image` in der Notification-Payload direkt. Falls das Backend URLs in `data` schickt, laden wir die via Coil in einem `WorkManager`-Worker, bauen eine `NotificationCompat.Style.BigPictureStyle` und posten die Benachrichtigung
- **App-Badge-Count**: `me.leolin:ShortcutBadger` ist tot; stattdessen `NotificationManager.setActiveNotification` + Launcher-spezifische Badges via Notification-Channel. Für Oberfläche 14/15 reicht das `number` Feld auf der Notification.

### Barcode & Kamera

- **CameraX** (`androidx.camera:camera-*`) für Preview/Capture
- **ML Kit Barcode Scanning** (`com.google.mlkit:barcode-scanning`) für EAN/UPC/Code128/QR — bietet dieselben Formate wie iOS `AVCaptureMetadataOutput`

### Testing

- **JUnit 5** + **Kotest** Assertions für Unit-Tests
- **Compose UI Test** (`androidx.compose.ui:ui-test-junit4`)
- **MockK** für Coroutine-Mocks
- **Turbine** für Flow-Tests
- **Maestro** (optional) für E2E-Tests

### Nicht verwenden

- Keine `Fragment`, keine `XML Layouts` (außer Launch-Screen), keine `LiveData`, keine `RxJava`, kein `Retrofit` separat (Supabase SDK bringt alles), keine `Room`/`Realm`/`SQLDelight`, kein `Dagger` ohne Hilt, keine `Jetpack Navigation-Compose` vor 2.8 (2.8+ hat typsichere Routen).

---

## 3. Projekt-Struktur

```
Android/
├── build.gradle.kts                       // root
├── settings.gradle.kts
├── gradle/
│   └── libs.versions.toml                 // Version-Catalog
└── app/
    ├── build.gradle.kts                   // Android-App, BuildConfig-Felder, Flavors
    ├── google-services.json               // FCM Config (NICHT committen → .gitignore)
    └── src/
        ├── main/
        │   ├── AndroidManifest.xml
        │   └── kotlin/de/kerlhandel/vmflow/
        │       ├── VMflowApp.kt                    // @HiltAndroidApp Application
        │       ├── MainActivity.kt                 // ComponentActivity → setContent { VMflowApp() }
        │       │
        │       ├── data/
        │       │   ├── model/                      // Data Classes = iOS Models
        │       │   │   ├── Organization.kt
        │       │   │   ├── VendingMachine.kt       // VendingMachine, Embedded, MachineStats, TrayDeficit, WarehouseAvailability, StockHealth, StockSeverity
        │       │   │   ├── Tray.kt                 // Tray, TrayProduct, TrayUpsert
        │       │   │   ├── Product.kt              // Product, ProductCategory, ProductBarcode
        │       │   │   ├── Sale.kt                 // Sale, SaleProduct, SaleWithMachine, DailySales
        │       │   │   ├── Warehouse.kt            // Warehouse, WarehouseStockBatch, WarehouseProductSummary, IntakeEntry, InsertStockBatch, InsertWarehouseTransaction, WarehouseProductPosition, WarehousePositionGroup
        │       │   │   ├── Deal.kt
        │       │   │   ├── Inbox.kt                // InboxItem + decoder rows
        │       │   │   ├── Refill.kt               // RefillMachine, RefillTray, PackingItem, CombinedPackingItem, MachineNeed, TourLogEntry, ReplacementSuggestion, RefillStep
        │       │   │   └── ServerEntry.kt
        │       │   ├── remote/
        │       │   │   ├── SupabaseClientProvider.kt   // Singleton, Hilt @Module
        │       │   │   ├── AppConfig.kt                // liest BuildConfig.SUPABASE_URL etc.
        │       │   │   ├── AuthApi.kt
        │       │   │   ├── MachineApi.kt
        │       │   │   ├── TrayApi.kt
        │       │   │   ├── SalesApi.kt
        │       │   │   ├── ProductApi.kt
        │       │   │   ├── WarehouseApi.kt
        │       │   │   ├── RefillApi.kt
        │       │   │   ├── DealApi.kt
        │       │   │   ├── InboxApi.kt
        │       │   │   └── EdgeFunctionsApi.kt        // invoke wrapper
        │       │   ├── repository/
        │       │   │   ├── AuthRepository.kt
        │       │   │   ├── OrganizationRepository.kt
        │       │   │   ├── DashboardRepository.kt
        │       │   │   ├── MachineRepository.kt
        │       │   │   ├── TrayRepository.kt
        │       │   │   ├── ProductRepository.kt
        │       │   │   ├── WarehouseRepository.kt
        │       │   │   ├── RefillRepository.kt
        │       │   │   ├── DealRepository.kt
        │       │   │   ├── InboxRepository.kt
        │       │   │   ├── NotificationRepository.kt
        │       │   │   └── ServerRepository.kt        // verwaltet Liste + Selektion
        │       │   ├── local/
        │       │   │   ├── SettingsDataStore.kt        // DataStore Preferences
        │       │   │   ├── RefillTourStore.kt          // persistiert Tour-State (24h TTL)
        │       │   │   └── PushTokenStore.kt
        │       │   └── realtime/
        │       │       └── RealtimeManager.kt          // StateFlow<VersionCounters>
        │       │
        │       ├── di/
        │       │   ├── SupabaseModule.kt
        │       │   ├── RepositoryModule.kt
        │       │   └── DispatcherModule.kt
        │       │
        │       ├── push/
        │       │   ├── FcmService.kt                    // extends FirebaseMessagingService
        │       │   ├── NotificationChannels.kt
        │       │   └── PushImageLoader.kt               // WorkManager-Worker für BigPicture
        │       │
        │       ├── ui/
        │       │   ├── theme/
        │       │   │   ├── VMflowTheme.kt               // Material3 Expressive, Dynamic Color
        │       │   │   ├── Color.kt
        │       │   │   ├── Typography.kt
        │       │   │   └── Shape.kt
        │       │   ├── navigation/
        │       │   │   ├── VMflowNavHost.kt             // typsichere Routen
        │       │   │   ├── Destinations.kt              // @Serializable route objects
        │       │   │   ├── AdaptiveNavigation.kt        // BottomBar vs. NavigationRail vs. Drawer je nach WindowSizeClass
        │       │   │   └── DeepLinks.kt
        │       │   ├── common/                          // Wiederverwendbare UI
        │       │   │   ├── KpiCard.kt
        │       │   │   ├── StatusChip.kt                // = StatusBadge
        │       │   │   ├── StockBar.kt
        │       │   │   ├── StockHealthIndicator.kt
        │       │   │   ├── ProductImage.kt              // Coil + Supabase Public URL
        │       │   │   ├── RecentSaleRow.kt
        │       │   │   ├── DaySectionHeader.kt
        │       │   │   ├── ErrorBanner.kt
        │       │   │   ├── LoadingOverlay.kt
        │       │   │   ├── EmptyState.kt
        │       │   │   └── Haptics.kt                   // wrapper um HapticFeedback
        │       │   ├── auth/
        │       │   │   ├── LoginScreen.kt
        │       │   │   ├── RegisterScreen.kt
        │       │   │   ├── ServerSelectionSheet.kt
        │       │   │   ├── AddServerScreen.kt
        │       │   │   ├── QrScannerScreen.kt
        │       │   │   └── AuthViewModels.kt
        │       │   ├── dashboard/
        │       │   │   ├── DashboardScreen.kt
        │       │   │   ├── DashboardViewModel.kt
        │       │   │   └── chart/
        │       │   │       └── RevenueChart.kt
        │       │   ├── machines/
        │       │   │   ├── MachineListScreen.kt
        │       │   │   ├── MachineListViewModel.kt
        │       │   │   ├── MachineCard.kt
        │       │   │   ├── MachineDetailScreen.kt
        │       │   │   ├── MachineDetailViewModel.kt
        │       │   │   └── MachinesAdaptivePane.kt      // List-Detail für Tablet/Foldable
        │       │   ├── trays/
        │       │   │   ├── TrayListScreen.kt
        │       │   │   ├── TrayListViewModel.kt
        │       │   │   ├── TrayRow.kt
        │       │   │   ├── TrayEditSheet.kt
        │       │   │   └── BatchAddDialog.kt
        │       │   ├── products/
        │       │   │   ├── ProductsScreen.kt
        │       │   │   ├── ProductsViewModel.kt
        │       │   │   ├── ProductEditSheet.kt
        │       │   │   ├── ImageSearchSheet.kt
        │       │   │   └── CategoryManagerScreen.kt
        │       │   ├── warehouse/
        │       │   │   ├── WarehouseScreen.kt
        │       │   │   ├── WarehouseViewModel.kt
        │       │   │   ├── ProductBatchesScreen.kt
        │       │   │   ├── BatchAdjustSheet.kt
        │       │   │   └── IntakeForm.kt
        │       │   ├── refill/
        │       │   │   ├── RefillWizardScreen.kt
        │       │   │   ├── RefillWizardViewModel.kt
        │       │   │   ├── step/
        │       │   │   │   ├── ReviewStep.kt
        │       │   │   │   ├── PackingStep.kt
        │       │   │   │   ├── RefillStep.kt
        │       │   │   │   └── SummaryStep.kt
        │       │   │   └── components/
        │       │   │       ├── StepIndicator.kt
        │       │   │       ├── PackingRow.kt
        │       │   │       └── MachineProgressBar.kt
        │       │   ├── deals/
        │       │   │   ├── DealsScreen.kt
        │       │   │   ├── DealsViewModel.kt
        │       │   │   ├── DealCard.kt
        │       │   │   └── DealDetailSheet.kt
        │       │   ├── inbox/
        │       │   │   ├── InboxScreen.kt
        │       │   │   └── InboxViewModel.kt
        │       │   └── settings/
        │       │       ├── SettingsScreen.kt
        │       │       └── SettingsViewModel.kt
        │       │
        │       └── util/
        │           ├── DateFormatting.kt                // timeAgo, formatCurrency, formatDate
        │           ├── WeekBoundaries.kt                // Monday-basierte Wochenrechnung
        │           ├── UuidExt.kt
        │           └── FlowExt.kt
        └── test/ & androidTest/
```

### Gradle Flavors

Zwei Produkt-Flavors analog zu iOS Debug/Release, damit Dev + Prod parallel installiert werden können.

```kotlin
// app/build.gradle.kts
android {
  namespace = "de.kerlhandel.vmflow"
  compileSdk = 35
  defaultConfig {
    minSdk = 26
    targetSdk = 35
    applicationId = "de.kerlhandel.vmflow"
  }
  flavorDimensions += "env"
  productFlavors {
    create("dev") {
      dimension = "env"
      applicationIdSuffix = ".debug"
      versionNameSuffix = "-dev"
      buildConfigField("String", "SUPABASE_URL", "\"http://10.0.1.130:54321\"")
      buildConfigField("String", "SUPABASE_ANON_KEY", "\"sb_publishable_...\"")
    }
    create("prod") {
      dimension = "env"
      buildConfigField("String", "SUPABASE_URL", "\"https://supabase.kerl-handel.de\"")
      buildConfigField("String", "SUPABASE_ANON_KEY", "\"eyJhbGc...\"")
    }
  }
  buildFeatures { buildConfig = true; compose = true }
}
```

`applicationIdSuffix = ".debug"` ersetzt die iOS-Bundle-ID-Trennung `de.kerl-handel.app.debug` / `de.kerl-handel.app`.

Build-Nummer wie iOS aus `git rev-list --count HEAD`:

```kotlin
val gitCommitCount = providers.exec {
  commandLine("git", "rev-list", "--count", "HEAD")
}.standardOutput.asText.get().trim().toInt()
defaultConfig.versionCode = gitCommitCount
defaultConfig.versionName = "1.0"
```

---

## 4. Build- & Umgebungs-Konfiguration

### `gradle.properties`

```properties
# kann per Kommandozeile mit -PSUPABASE_URL=... überschrieben werden
SUPABASE_URL=http://10.0.1.130:54321
SUPABASE_ANON_KEY=sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH
# Compiler-Optionen
android.useAndroidX=true
kotlin.code.style=official
org.gradle.jvmargs=-Xmx4g -XX:+UseParallelGC
org.gradle.parallel=true
```

### `AndroidManifest.xml`

Muss folgende Berechtigungen enthalten:

| Permission | Warum | iOS-Pendant |
|---|---|---|
| `INTERNET` | Supabase + MQTT-Forwarder erreichen | automatisch |
| `ACCESS_NETWORK_STATE` | Network-State-Checks | automatisch |
| `POST_NOTIFICATIONS` (API 33+) | Push-Permission | `UNAuthorizationStatus` |
| `CAMERA` | Barcode-Scanner, QR-Code-Provisioning | `NSCameraUsageDescription` |
| `FOREGROUND_SERVICE_DATA_SYNC` (optional) | Nur falls Realtime in einen FGS ausgelagert wird | — |
| `com.google.android.c2dm.permission.RECEIVE` | FCM | — |

Uses-features (nicht required, damit Tablets ohne Kamera-Module installieren können):

```xml
<uses-feature android:name="android.hardware.camera" android:required="false" />
<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
```

Application-Block:

```xml
<application
    android:name=".VMflowApp"
    android:allowBackup="false"
    android:dataExtractionRules="@xml/data_extraction_rules"
    android:fullBackupContent="false"
    android:icon="@mipmap/ic_launcher"
    android:roundIcon="@mipmap/ic_launcher_round"
    android:label="VMflow"
    android:theme="@style/Theme.VMflow.Splash"
    android:enableOnBackInvokedCallback="true"
    android:networkSecurityConfig="@xml/network_security_config">
    <activity
        android:name=".MainActivity"
        android:exported="true"
        android:theme="@style/Theme.VMflow"
        android:windowSoftInputMode="adjustResize">
        <intent-filter>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent-filter>
    </activity>
    <service android:name=".push.FcmService" android:exported="false">
        <intent-filter>
            <action android:name="com.google.firebase.MESSAGING_EVENT" />
        </intent-filter>
    </service>
</application>
```

### `network_security_config.xml`

iOS erlaubt über `NSAllowsArbitraryLoads = true` + `NSAllowsLocalNetworking = true` auch HTTP zu lokalen Servern (Dev-Flavor). Android braucht dasselbe:

```xml
<network-security-config>
  <domain-config cleartextTrafficPermitted="true">
    <!-- Liste der lokalen LAN-IPs + Hostnamen wird im dev-Flavor überschrieben -->
    <domain includeSubdomains="true">10.0.0.0/8</domain>
    <domain includeSubdomains="true">192.168.0.0/16</domain>
  </domain-config>
  <base-config cleartextTrafficPermitted="false">
    <trust-anchors>
      <certificates src="system" />
    </trust-anchors>
  </base-config>
</network-security-config>
```

Der Prod-Flavor lässt diese Datei weg bzw. setzt `cleartextTrafficPermitted="false"`.

### Splash

Android 12+ Splash-Screen-API verwenden (`androidx.core:core-splashscreen`). Icon: derselbe `cup.and.saucer.fill`-Style wie iOS, in Vektor (siehe `BRANDING.md`).

---

## 5. Datenschicht

### Supabase-Client

```kotlin
// data/remote/SupabaseClientProvider.kt
@Singleton
class SupabaseClientProvider @Inject constructor(
    private val serverRepository: ServerRepository,
) {
    private val _client = MutableStateFlow(build(serverRepository.selectedServer.value))
    val client: StateFlow<SupabaseClient> = _client.asStateFlow()

    fun reconfigure(server: ServerEntry) {
        // Nur auf Login-Screen erlaubt (keine Sessions aktiv) — Guard im Repo
        _client.value = build(server)
    }

    private fun build(server: ServerEntry) = createSupabaseClient(
        supabaseUrl = server.sanitizedUrl,
        supabaseKey = server.anonKey,
    ) {
        install(Auth) {
            scheme = "vmflow"
            host = "auth"
            alwaysAutoRefresh = true
            sessionManager = DataStoreSessionManager(sessionStore)
        }
        install(Postgrest)
        install(Realtime)
        install(Storage)
        install(Functions) {
            serializer = KotlinXSerializer(Json {
                ignoreUnknownKeys = true
                isLenient = true
            })
        }
    }
}
```

### Models

Jedes iOS-`struct` aus [ios/VMflow/Models/](../ios/VMflow/Models/) bekommt eine `@Serializable data class` mit `@SerialName` statt `CodingKeys`. Beispiel:

```kotlin
// data/model/VendingMachine.kt
@Serializable
data class VendingMachine(
    val id: String,                     // UUID als String — match PostgREST Behavior
    val name: String? = null,
    @SerialName("location_lat") val locationLat: Double? = null,
    @SerialName("location_lon") val locationLon: Double? = null,
    val embedded: String? = null,
    @SerialName("country_code") val countryCode: String? = null,
    val embeddeds: Embedded? = null,
) {
    val displayName: String get() = name ?: "Unnamed Machine"
    val isOnline: Boolean get() = embeddeds?.isOnline == true
}

@Serializable
data class Embedded(
    val id: String,
    val status: String? = null,
    @SerialName("status_at") val statusAt: Instant? = null,
    val subdomain: Int,
    @SerialName("mac_address") val macAddress: String? = null,
    @SerialName("firmware_version") val firmwareVersion: String? = null,
) {
    val isOnline: Boolean get() = status?.lowercase() == "online"
}

data class MachineStats(  // kein @Serializable — aggregiert lokal
    val machine: VendingMachine,
    var todayRevenue: Double = 0.0,
    var todaySalesCount: Int = 0,
    var yesterdayRevenue: Double = 0.0,
    var yesterdaySalesCount: Int = 0,
    var thisWeekRevenue: Double = 0.0,
    var thisWeekSalesCount: Int = 0,
    var lastWeekRevenue: Double = 0.0,
    var lastWeekSalesCount: Int = 0,
    var paxcounterCount: Int? = null,
    var totalTrays: Int = 0,
    var lowTrays: Int = 0,
    var emptyTrays: Int = 0,
    var stockPercent: Double = 0.0,
    var swapNeededCount: Int = 0,
    var noStockCount: Int = 0,
    var trayDeficits: List<TrayDeficit> = emptyList(),
) {
    val stockHealth: StockHealth get() = when {
        emptyTrays > 0 -> StockHealth.Critical
        lowTrays > 0 -> StockHealth.Low
        else -> StockHealth.Ok
    }
    val sortPriority: Int get() = when (stockHealth) {
        StockHealth.Critical -> 0
        StockHealth.Low -> 1000 - lowTrays
        StockHealth.Ok -> 2000
    }
}

enum class StockHealth { Ok, Low, Critical }
enum class StockSeverity { Critical, Low, FillBelow }   // Comparable-Reihenfolge: Critical < Low < FillBelow
enum class WarehouseAvailability { InStock, NoStock, NeedsSwap, Unknown }
```

**Konventionen für alle Models:**

1. UUIDs als `String` halten — PostgREST liefert sie als String, und `kotlinx.datetime` hat keinen `UUID`-Typ; wer Typsicherheit will, kann `Uuid` aus `kotlin.uuid` ab Kotlin 2.0 verwenden (experimentell)
2. Datumswerte als `kotlinx.datetime.Instant`
3. Preis-Felder sind `Double` und in **EUR** (nicht Cent) — **absolute Regel**, siehe [CLAUDE.md](../CLAUDE.md)
4. Alle Felder mit möglichem `NULL` sind `val x: T? = null`
5. `@SerialName` für jedes snake_case-Feld aus der DB

### Repositories

Repositories kapseln die Supabase-Queries, nehmen **Dispatchers via DI** entgegen und liefern `Flow<T>` oder `Result<T>`. Beispiel:

```kotlin
// data/repository/MachineRepository.kt
class MachineRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @IoDispatcher private val io: CoroutineDispatcher,
) {
    private val pg get() = clientProvider.client.value.postgrest

    suspend fun fetchMachinesWithStats(): List<MachineStats> = withContext(io) {
        // parallele Fetches
        val machinesDeferred = async {
            pg["vendingMachine"].select(
                Columns.raw("id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")
            ).decodeList<VendingMachine>()
        }
        // ... sales, trays, paxcounter, stockBatches parallel
        val machines = machinesDeferred.await()
        // ... aggregiere wie in MachineListViewModel.swift:24-260
    }
}
```

**Wichtig**: alle Aggregationslogik (heute/gestern/diese Woche/letzte Woche, Stock-Urgency, Deficit pro Produkt, Warehouse-Availability, Pick-Order) muss **1:1** dem iOS-Code entsprechen. Insbesondere:

- Wochenstart ist **Montag** (nicht Sonntag) — `java.time.DayOfWeek.MONDAY`
- `StockSeverity.Critical < Low < FillBelow` als Comparable
- Sort: `needsSwap`-Produkte zuerst, dann nach Severity, dann nach Deficit absteigend
- `warehouseAvail()`-Funktion entspricht [MachineListViewModel.swift:194](../ios/VMflow/ViewModels/MachineListViewModel.swift) genau
- Pick-Order: depth-first durch `warehouse_position_groups` → `warehouse_product_positions` (siehe [RefillWizardViewModel.swift:1174](../ios/VMflow/ViewModels/RefillWizardViewModel.swift))

---

## 6. Auth & Organisation

### `AuthRepository`

```kotlin
class AuthRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    private val notificationRepository: NotificationRepository,
) {
    val sessionState: StateFlow<SessionStatus> = clientProvider.client
        .flatMapLatest { it.auth.sessionStatus }
        .stateIn(scope, SharingStarted.Eagerly, SessionStatus.LoadingFromStorage)

    val organization = MutableStateFlow<Organization?>(null)
    val role = MutableStateFlow<OrganizationRole?>(null)

    suspend fun login(email: String, password: String): Result<Unit> = runCatching {
        clientProvider.client.value.auth.signInWith(Email) {
            this.email = email
            this.password = password
        }
        fetchOrganization()
        notificationRepository.setupAfterLogin()
    }

    suspend fun register(email: String, password: String, firstName: String, lastName: String): Result<Unit> = runCatching {
        clientProvider.client.value.auth.signUpWith(Email) {
            this.email = email
            this.password = password
            this.data = buildJsonObject {
                put("first_name", firstName)
                put("last_name", lastName)
            }
        }
        fetchOrganization()
    }

    suspend fun logout() {
        notificationRepository.cleanupOnLogout()
        runCatching { clientProvider.client.value.auth.signOut() }
        organization.value = null
        role.value = null
    }

    suspend fun fetchOrganization() {
        val response = clientProvider.client.value.functions
            .invoke("get-my-organization", headers = Headers.build {}) {
                method = HttpMethod.Get
            }
            .decodeAs<OrganizationResponse>()
        organization.value = response.organization
        role.value = response.role?.let { runCatching { OrganizationRole.valueOf(it.replaceFirstChar(Char::uppercase)) }.getOrNull() }
    }
}
```

### Root-Routing

`RootScreen` (entspricht `RootView.swift`) prüft den `SessionStatus`:

| Status | UI |
|---|---|
| `LoadingFromStorage` / `NetworkError` beim ersten Fetch | `LaunchScreen` mit Logo + Progress |
| `NotAuthenticated` | `AuthNavHost` (Login/Register) |
| `Authenticated` aber Organisation `null` | `NoOrganizationScreen` mit Logout + Retry-Button |
| `Authenticated` + Organisation gesetzt | `AdaptiveNavigation` (siehe Abschnitt 8) |

---

## 7. Server-Auswahl (Multi-Environment)

iOS bietet dem User auf dem Login-Screen an, zwischen "VMflow Cloud" (Default aus `xcconfig`) und selbst hinzugefügten Servern zu wechseln (z. B. lokales Self-Hosting). [ServerStore.swift](../ios/VMflow/Services/ServerStore.swift), [ServerEntry.swift](../ios/VMflow/Models/ServerEntry.swift).

### `ServerRepository`

```kotlin
@Singleton
class ServerRepository @Inject constructor(
    private val dataStore: DataStore<Preferences>,
) {
    val defaultServer = ServerEntry(
        id = UUID.fromString("00000000-0000-0000-0000-000000000001"),
        name = "VMflow Cloud",
        url = BuildConfig.SUPABASE_URL,
        anonKey = BuildConfig.SUPABASE_ANON_KEY,
        isDefault = true,
    )

    val customServers: Flow<List<ServerEntry>> = dataStore.data
        .map { it[SERVERS_KEY]?.let { json -> Json.decodeFromString<List<ServerEntry>>(json) } ?: emptyList() }

    val selectedServer: Flow<ServerEntry> = combine(
        dataStore.data.map { it[SELECTED_KEY] },
        customServers,
    ) { selectedIdString, customs ->
        val list = listOf(defaultServer) + customs
        selectedIdString?.let { id -> list.find { it.id.toString() == id } } ?: defaultServer
    }

    suspend fun selectServer(id: UUID) { dataStore.edit { it[SELECTED_KEY] = id.toString() } }
    suspend fun addServer(server: ServerEntry) { /* DataStore update */ }
    suspend fun updateServer(server: ServerEntry) { /* ... */ }
    suspend fun deleteServer(server: ServerEntry) { require(!server.isDefault); /* ... */ }

    companion object {
        private val SERVERS_KEY = stringPreferencesKey("saved_servers")
        private val SELECTED_KEY = stringPreferencesKey("selected_server_id")
    }
}
```

### UI

`ServerSelectionSheet` (ModalBottomSheet, Material3) zeigt die Liste, erlaubt Edit + Delete (nicht für Default), Hinzufügen öffnet `AddServerScreen` mit Name/URL/AnonKey + optional QR-Scanner, der einen JSON-QR-Code einliest (siehe [QRScannerView.swift](../ios/VMflow/Views/Auth/QRScannerView.swift)).

Nach `selectServer` muss `SupabaseClientProvider.reconfigure(server)` aufgerufen werden und `AuthRepository.restartAuthListener()` — genau wie iOS.

---

## 8. Navigation (Adaptive)

### `WindowSizeClass` → Layout

| Breite | Layout | Entsprechung iOS |
|---|---|---|
| `Compact` (< 600 dp) | `NavigationBar` unten + 5 Top-Level-Routen | `CompactTabView` |
| `Medium` (600–840 dp) | `NavigationRail` seitlich + primärer Detail-Pane | `SidebarNavigationView` |
| `Expanded` (≥ 840 dp, Foldable/Tablet/Desktop-Chrome) | `PermanentNavigationDrawer` oder `NavigationRail` + `SupportingPaneScaffold` | `SidebarNavigationView` mit `NavigationSplitView` |

### Top-Level-Routen (Compact)

Dieselben 5 wie iOS: Dashboard, Machines, Refill, Inbox, More. Unter "More" dann Products, Warehouse, Deals, Settings (plus Logout).

### Navigation-Compose (typsicher)

```kotlin
// ui/navigation/Destinations.kt
@Serializable object DashboardRoute
@Serializable object MachinesRoute
@Serializable data class MachineDetailRoute(val machineId: String)
@Serializable object RefillRoute
@Serializable object InboxRoute
@Serializable object MoreRoute
@Serializable object ProductsRoute
@Serializable data class ProductEditRoute(val productId: String?)
@Serializable object WarehouseRoute
@Serializable data class ProductBatchesRoute(val warehouseId: String, val productId: String)
@Serializable object DealsRoute
@Serializable object SettingsRoute
@Serializable object LoginRoute
@Serializable object RegisterRoute
```

```kotlin
// ui/navigation/VMflowNavHost.kt
@Composable fun VMflowNavHost(navController: NavHostController) {
    NavHost(navController, startDestination = DashboardRoute) {
        composable<DashboardRoute> { DashboardScreen(onNavigate = navController::navigateTab) }
        composable<MachinesRoute> { MachineListScreen(onMachineClick = { id -> navController.navigate(MachineDetailRoute(id)) }) }
        composable<MachineDetailRoute> { entry ->
            val args = entry.toRoute<MachineDetailRoute>()
            MachineDetailScreen(machineId = args.machineId)
        }
        // ... weitere
    }
}
```

### Deep-Link aus Push

`FcmService` extrahiert aus `data["type"] == "inbox"` einen Intent, der `MainActivity` mit Extra `nav_deep_link=inbox` startet. In `MainActivity.onNewIntent` wird ein `SharedFlow<DeepLink>` gefüttert, der in `RootScreen` gesammelt und via `navController.navigate(InboxRoute)` aufgelöst wird.

Zusätzlich kann ein Android-App-Link (`https://vmflow.app/inbox`) eingerichtet werden für Universal-Link-Parität.

---

## 9. Realtime

iOS [RealtimeService.swift](../ios/VMflow/Services/RealtimeService.swift) verwendet `RealtimeChannelV2` und publiziert 5 Version-Counter: `salesVersion`, `traysVersion`, `machinesVersion`, `embeddedVersion`, `warehouseVersion`.

### Android

```kotlin
@Singleton
class RealtimeManager @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @ApplicationScope private val scope: CoroutineScope,
) {
    data class Versions(
        val sales: Int = 0,
        val trays: Int = 0,
        val machines: Int = 0,
        val embedded: Int = 0,
        val warehouse: Int = 0,
    )

    private val _versions = MutableStateFlow(Versions())
    val versions: StateFlow<Versions> = _versions.asStateFlow()

    private var job: Job? = null

    fun start() {
        if (job?.isActive == true) return
        job = scope.launch {
            val channel = clientProvider.client.value.realtime.channel("app-realtime")
            val salesFlow = channel.postgresChangeFlow<PostgresAction.Insert>(schema = "public") { table = "sales" }
            val traysFlow = channel.postgresChangeFlow<PostgresAction>(schema = "public") { table = "machine_trays" }
            val machinesFlow = channel.postgresChangeFlow<PostgresAction>(schema = "public") { table = "vendingMachine" }
            val embeddedFlow = channel.postgresChangeFlow<PostgresAction.Update>(schema = "public") { table = "embeddeds" }
            val warehouseFlow = channel.postgresChangeFlow<PostgresAction>(schema = "public") { table = "warehouse_stock_batches" }

            channel.subscribe()

            launch { salesFlow.collect { _versions.update { it.copy(sales = it.sales + 1) } } }
            launch { traysFlow.collect { _versions.update { it.copy(trays = it.trays + 1) } } }
            launch { machinesFlow.collect { _versions.update { it.copy(machines = it.machines + 1) } } }
            launch { embeddedFlow.collect { _versions.update { it.copy(embedded = it.embedded + 1) } } }
            launch { warehouseFlow.collect { _versions.update { it.copy(warehouse = it.warehouse + 1) } } }
        }
    }

    fun stop() { job?.cancel(); job = null }
}
```

**Wichtig (iOS-Bug, der auf Android nicht passieren darf)**: alle `postgresChangeFlow`-Aufrufe müssen **vor** `channel.subscribe()` erfolgen — siehe den Kommentar in [RealtimeService.swift:32](../ios/VMflow/Services/RealtimeService.swift). Die Kotlin-SDK hat dieselbe Semantik.

ViewModels sammeln `versions` und reloaden auf Änderungen:

```kotlin
val reload = realtimeManager.versions
    .map { it.sales + it.trays + it.machines + it.embedded }  // je nach Screen
    .distinctUntilChanged()

viewModelScope.launch {
    reload.collect { loadMachines() }
}
```

Start in der Root: `RealtimeManager.start()` nach erfolgreichem Auth-State, Stop in `logout()`.

---

## 10. Push-Benachrichtigungen (FCM)

### Backend-Integration

Das Backend akzeptiert bereits einen `platform` Parameter in `register-push`:

```swift
try await client.functions.invoke("register-push", options: .init(body: RegisterBody(
    fcm_token: token,
    platform: "ios",
    bundle_id: Bundle.main.bundleIdentifier
)))
```

Android schickt `platform = "android"` und `bundle_id = BuildConfig.APPLICATION_ID`. Das Backend muss bereits FCM zusätzlich zu APNs routen können. **Falls nicht**: erweitere die Edge-Function `register-push` + `test-push` + `check-low-stock` so, dass sie anhand `platform` entscheidet, welchen Push-Anbieter sie verwendet. Die FCM-Secrets (`FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_JSON`) müssen wie andere Env-Variablen in **allen sechs Stellen** gepflegt werden (siehe [CLAUDE.md "Adding New Environment Variables"](../CLAUDE.md)).

### Client-Seite

```kotlin
// push/FcmService.kt
@AndroidEntryPoint
class FcmService : FirebaseMessagingService() {
    @Inject lateinit var notificationRepository: NotificationRepository

    override fun onNewToken(token: String) {
        ApplicationScope.launch {
            notificationRepository.registerToken(token)
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val notification = message.notification
        val data = message.data
        val channel = when (data["type"]) {
            "sale" -> NotificationChannels.Sales
            "low_stock" -> NotificationChannels.LowStock
            "inbox" -> NotificationChannels.Inbox
            else -> NotificationChannels.General
        }
        // BigPicture-Stil wenn data["image"] URL ist
        val imageUrl = data["image"]
        if (!imageUrl.isNullOrBlank()) {
            enqueueImageWorker(imageUrl, notification, data, channel)
        } else {
            postNotification(notification, data, channel, image = null)
        }

        // Badge aktualisieren (Inbox-Count)
        ApplicationScope.launch { notificationRepository.refreshBadge() }
    }
}
```

### Notification-Channels

Eine Channel pro Typ (so kann der User sie einzeln in den Systemeinstellungen verwalten — Android-Äquivalent zu iOS-Kategorien):

| Channel-ID | Name (EN) | Importance | Typ |
|---|---|---|---|
| `sales` | Sale Notifications | Low | Jeder Verkauf |
| `low_stock` | Low Stock Alerts | Default | Unter Schwellwert |
| `inbox` | Customer Inbox | Default | Feedback, Problem, Wunsch |
| `general` | General | Default | Default |

### Preferences

iOS hat die Tabelle `notification_preferences(user_id, notification_type, enabled)` mit Upsert über `(user_id, notification_type)`. Android verwendet dieselbe Tabelle und ruft den gleichen Edge-Function-Flow — siehe [NotificationService.swift:220](../ios/VMflow/Services/NotificationService.swift). Keine Server-Änderung nötig.

### Badge

iOS nutzt `UNUserNotificationCenter.setBadgeCount` und liest Counts via HEAD-Queries auf `machine_feedback` + `product_wishes` mit `status='new'`. Android hat kein echtes App-Badge im API-Sinne — stattdessen:

1. Setze `number` auf der persistenten Inbox-Notification (nur auf wenigen Launchern sichtbar)
2. Zeige den Badge-Count auf dem `NavigationBar.Item(badge = ...)` der Inbox in-App (immer sichtbar)
3. Wenn Samsung Launcher / Google Pixel Launcher Badge-Provider aktivieren: Notification-Channel muss `setShowBadge(true)` haben

### Permission-Flow (API 33+)

Ab Android 13 ist `POST_NOTIFICATIONS` eine Runtime-Permission:

```kotlin
val permissionState = rememberPermissionState(Manifest.permission.POST_NOTIFICATIONS)
LaunchedEffect(Unit) {
    if (!permissionState.status.isGranted && Build.VERSION.SDK_INT >= 33) {
        permissionState.launchPermissionRequest()
    }
}
```

In `SettingsScreen` wird Toggle + "App-Einstellungen öffnen"-Button gezeigt wenn Permission denied, analog iOS.

---

## 11. Feature-Spezifikationen

### 11.1 Dashboard

Quelle: [DashboardView.swift](../ios/VMflow/Views/Dashboard/DashboardView.swift), [DashboardViewModel.swift](../ios/VMflow/ViewModels/DashboardViewModel.swift)

**Elemente** (von oben nach unten):

1. **App-Bar** mit Organisations-Name als Titel + Overflow-Menü mit "Sign Out"
2. **KPI-Grid** (2 Spalten compact, 4 Spalten medium/expanded):
   - `Today's Revenue` (EUR, subtitle "Yesterday: xx.xx €")
   - `Today's Sales` (count, subtitle "This week: n")
   - `Machines` ("online/total", subtitle "Online")
   - `Stock Alerts` (critical + low count, subtitle "x critical, y low", Farbe abhängig von Critical > 0 ? rot : low > 0 ? gelb : grün)
3. **Quick Actions** (Row, 2 Buttons):
   - Primär: `Start Refill` oder `Continue Refill` (wenn `RefillTourStore.hasSavedTourState` true) — navigiert zu Refill-Tab
   - Sekundär: `Machines` — navigiert zu Machines-Tab
4. **Chart "Revenue (30 days)"** — `Card` mit Titel links, Monats-Total rechts, darunter `RevenueChart` (Bars je Tag, blaue Gradient, compact Y-Axis-Labels `0, 50, 100, 500, 1k, 2k`)
5. **Card "Recent Sales"** — gruppiert nach Tag (`Today`, `Yesterday`, dann `EEEE, d MMMM`), jede Gruppe hat Header (Tag + Count), danach `RecentSaleRow` (Produkt-Image 36dp + Name + Machine-Name darunter + Preis rechts + Zeit darunter `HH:mm:ss`)

**Datenquelle** (`DashboardViewModel`):
- `loadSalesKPIs()` — alle Sales des aktuellen Monats einmalig laden, dann lokal klassifizieren (today/yesterday/week/month)
- `loadMachineStats()` — vendingMachine + machine_trays, zählt online/total, critical/low
- `loadDailyChart()` — Sales der letzten 30 Tage, gruppiert nach `LocalDate` mit 0-Fallback für Tage ohne Verkauf
- `loadRecentSales()` — limit 20, mit `products(name, image_path)` Join, Fallback auf `machine_trays`-Lookup bei Sales ohne `product_id` (ältere Daten)

Alle 4 Calls laufen parallel (`coroutineScope { ... }`). Pull-to-Refresh lädt alle vier neu. Bei `realtimeManager.versions.sales|machines|embedded` Änderung automatisches Reload.

### 11.2 Maschinenliste

Quelle: [MachineListView.swift](../ios/VMflow/Views/Machines/MachineListView.swift), [MachineListViewModel.swift](../ios/VMflow/ViewModels/MachineListViewModel.swift), [MachineCard.swift](../ios/VMflow/Views/Machines/MachineCard.swift)

**Layout** (compact): `LazyColumn` mit `MachineCard` pro Maschine, 12 dp Spacing, 16 dp horizontales Padding. `SearchBar` oben (Material3). Pull-to-Refresh.

**`MachineCard`** (eigene Komponente, breite Column mit Badge-Grid):

- Header-Row: Name der Maschine (Typography.titleMedium) + `StatusChip` (online/offline) rechts
- `StockBar` (overall stockPercent) mit grünem/gelbem/rotem Fill
- Summary-Badges (Row): `Empty: x`, `Low: y`, `Swap: z`, `No Stock: w` — jedes Chip mit eigener Farbe (rot/orange/orange/grau)
- 2x2-Grid für Sales-Stats: `Today`, `Yesterday`, `This Week`, `Last Week` — je Zelle Revenue (fett) + Count (sekundär)
- Paxcounter-Zeile (falls Wert vorhanden): `🚶 xxxx` als kleine Kapsel
- Liste der `TrayDeficit`-Rows (max 5 sichtbar, Rest via "+n more"):
  - Produkt-Image (32 dp), Name, Deficit-Zahl, `WarehouseAvailability`-Badge (`In Stock` grün, `Swap` orange, `No Stock` grau, discontinued `DC` kapsel)

**Klick auf Card** → `MachineDetailScreen(machineId)`.

**Sortierung**: `sortPriority` aufsteigend (Critical → Low → Ok, innerhalb `Low` absteigend nach `lowTrays`).

**Datenladen**: siehe [MachineListViewModel.swift](../ios/VMflow/ViewModels/MachineListViewModel.swift) — 6 parallele Queries: machines, sales (ab Montag letzter Woche), trays, paxcounter, stockBatches, dann lokale Aggregation.

### 11.3 Maschinen-Detail

Quelle: [MachineDetailView.swift](../ios/VMflow/Views/Machines/MachineDetailView.swift), [MachineDetailViewModel.swift](../ios/VMflow/ViewModels/MachineDetailViewModel.swift)

Tabs (TabRow mit 3 Tabs): `Overview`, `Trays`, `Sales`, optional `Insights`.

- **Overview** — wiederholt die Machine-Card-Inhalte + 30-Tage-Chart für diese Maschine + heutiger Umsatz + Stock-Summary-Text
- **Trays** — siehe Abschnitt 11.4
- **Sales** — Liste der letzten 50 Sales mit Produkt-Image, Menge via `current_stock` + Preis + Timestamp. Admins können einen Sale löschen (`delete_sale_and_restore_stock` RPC) — SwipeToDismiss-Action. Admins können manuelle Sales hinzufügen (`insert_manual_sale` RPC) — FAB unten rechts.
- **Insights** (nur wenn `companies.anthropic_api_key` gesetzt) — ruft `machine-insights` Edge-Function auf und zeigt AI-generierten Text + Empfehlungen. Caching 6 h.

Navigation: oben links Back-Arrow, oben rechts Overflow-Menü (Edit Machine, Trigger OTA, …).

### 11.4 Tray-Verwaltung

Quelle: [TrayListView.swift](../ios/VMflow/Views/Trays/TrayListView.swift), [TrayRow.swift](../ios/VMflow/Views/Trays/TrayRow.swift), [TrayEditSheet.swift](../ios/VMflow/Views/Trays/TrayEditSheet.swift), [TrayViewModel.swift](../ios/VMflow/ViewModels/TrayViewModel.swift)

**Liste** (LazyColumn):
- `TrayRow`: Slot-Nummer (Chip), Produkt-Image (40 dp), Produktname + Preis, `StockBar` mit Markers für `min_stock` (orange) und `fill_when_below` (blau), Quick-Actions rechts (`-1`, `+1`, `Fill`, Overflow für Edit/Delete)
- "DC"-Kapsel wenn Produkt discontinued

**Toolbar**:
- FAB unten rechts mit SpeedDial: `Add Single`, `Batch Add`, `Fill All`
- Overflow oben rechts: `Reorder`, `Export`

**BatchAddDialog**: Input `Start slot`, `Count`, `Capacity` → POST `n` Einträge mit `product_id = null, current_stock = 0`.

**TrayEditSheet** (ModalBottomSheet, scrollable):
- Slot-Number Input (editierbar — kein Duplicate, validate)
- Produkt-Picker mit Fuzzy-Search über aktive Produkte (siehe ProductCombobox im Web + iOS Picker-Sheet)
- Capacity, Current Stock, Min Stock, Fill-When-Below — alles Integer-Stepper mit Material3 `OutlinedTextField` oder `SliderWithInput`
- Save / Cancel / Delete (destruktiv rot)

**Stock-Delta**: `-1` / `+1` Buttons clampen auf `[0, capacity]` — exakt wie [TrayViewModel.swift:163](../ios/VMflow/ViewModels/TrayViewModel.swift). Haptisches Feedback `light` bei jedem Tap.

**Encoding-Detail**: `product_id` muss bei jedem Update **explizit** als `null` gesendet werden (nicht weggelassen), sonst überschreibt PostgREST nicht. In Kotlinx-Serialization erreichst du das mit `@EncodeDefault` und `null`-Werten nicht-nullable encodieren. Alternativ: `JsonObject` manuell bauen.

### 11.5 Refill-Wizard

Quelle: [RefillWizardView.swift](../ios/VMflow/Views/Refill/RefillWizardView.swift), [RefillWizardViewModel.swift](../ios/VMflow/ViewModels/RefillWizardViewModel.swift), plus `PackingStepView`, `RefillStepView`, `ReviewStepView`, `RefillSummaryView`

Der komplexeste Screen. **4 Schritte**, aber Step 1 (Review) wird übersprungen, wenn keine Replacements nötig sind.

#### Schritt 1 — Review

Der Wizard prüft beim Laden alle Trays gegen 4 Replacement-Gründe:

1. **Discontinued + empty** — Produkt ist `discontinued = true` UND `current_stock = 0`
2. **Expired** — alle `warehouse_stock_batches` dieses Produkts sind abgelaufen
3. **No warehouse stock** — Tray ist leer UND Produkt hat keinen Batch mit `quantity > 0`
4. **Unassigned** — Tray hat `product_id = null`

Für jede Suggestion zeigt die Liste: Slot-Nummer, Maschinen-Name, aktueller Produktname + Bild (oder Placeholder bei unassigned), Grund, Replacement-Picker (Dropdown mit aktiven Produkten, Fuzzy-Search), Skip-Button. `Apply and continue` ist disabled bis alle Suggestions behandelt sind.

`applyReplacementsAndContinue()` schreibt `machine_trays.product_id` und lädt dann Schritt 2.

#### Schritt 2 — Packing

**"Pack-by-Product"**, nicht by-Machine. Das ist ein wichtiger UX-Unterschied zu naiven Lösungen. Die Liste ist **eine flache Liste von Produkten**, die über alle Maschinen aggregiert sind:

- Jede Produkt-Zeile zeigt Produkt-Image, Name, Gesamt-Menge (`totalQuantity`), Preis, "n/m packed"-Indikator + Toggle-All-Checkbox rechts
- Tap auf die Zeile expandiert eine Sub-Liste aller betroffenen Maschinen: je Maschine eigene Checkbox + Stepper (Menge anpassen) + Capacity-Hinweis
- Reihenfolge der Produkt-Liste folgt der **warehouse pick-order** (depth-first durch `warehouse_position_groups`) — so läuft der User physisch durch das Lager nur einmal
- Out-of-stock Produkte (warehouse hat 0) werden ausgeblendet, außer sie sind schon teilweise gepackt
- Warehouse-Cap: der Stepper lässt sich nicht über `remainingWarehouseStock(productId)` hinaus erhöhen, wo andere Maschinen bereits committet haben
- Header: Warehouse-Picker (Dropdown), Progress-Text `x items for y machines`, `Pack Everything`-Button

**Realtime während Packing**: wenn ein Verkauf / Tray-Change live kommt, `refreshDuringPacking()` — Maschinenliste neu bauen, `packedItems`/`customQuantities` beibehalten. Siehe [RefillWizardViewModel.swift:813](../ios/VMflow/ViewModels/RefillWizardViewModel.swift).

`Start Tour` ruft `startTour()` — verteilt benutzerdefinierte Mengen proportional auf Trays, bucht Warehouse-Stock (FIFO-RPC `deduct_warehouse_stock_fifo`), speichert Tour-State in DataStore, geht zu Schritt 3.

#### Schritt 3 — Refill (per Maschine)

- Oben: Step-Indicator (1/n Maschinen) + aktuelle Maschine als Card
- Maschinen-Liste links (Tablet) oder als Dropdown oben (Phone) — User kann zwischen Maschinen springen
- Für aktuelle Maschine: alle Trays dieser Tour (`isInTour = true`) mit:
  - Slot-Nummer, Produkt-Image, Name
  - Aktueller Stock → Soll-Stock nach Refill (Fill-Stepper)
  - `Fill to capacity`-Button
  - "Sold during tour"-Badge wenn `staleStockTrayIds` diesen Tray enthält (Realtime-Detection)
- `Fill All Trays`-Button
- `Confirm Refill` (primär, grün) + `Skip Machine` (sekundär, grau)

`confirmRefill(machineId)` re-fetcht frischen Stock, updated `machine_trays`, schreibt Activity-Log mit `action = "stock_refill_tour"`, setzt `isRefilled = true`, springt zur nächsten Maschine. Wenn alle Maschinen fertig → Schritt 4.

**Persistenz**: jede Änderung ruft `saveTourState()`, das in DataStore Preferences schreibt (Key `refill-tour-state`, JSON-Encoded PersistedTourState mit `savedAt` + 24h TTL). Beim App-Start prüft `RefillTourStore.hasSavedTourState` — Dashboard-Button heißt dann "Continue Refill".

#### Schritt 4 — Summary

Tour-Statistik-Card: `Machines Visited`, `Trays Refilled`, `Items Added`, `Machines Skipped`. Dann Liste aller `TourLogEntry` je Maschine. Button `Finish` → `reset()` + zurück zum Dashboard.

### 11.6 Produkte

Quelle: [ProductsView.swift](../ios/VMflow/Views/Products/ProductsView.swift), [ProductEditSheet.swift](../ios/VMflow/Views/Products/ProductEditSheet.swift), [ProductsViewModel.swift](../ios/VMflow/ViewModels/ProductsViewModel.swift)

Zwei Tabs: `Products`, `Categories`.

**Products-Tab**:
- Suchleiste (Fuzzy über Name)
- Toggle `Show Discontinued`
- LazyColumn: Image + Name + Category + Preis + `DC`-Badge wenn discontinued
- Klick → `ProductEditSheet`

**ProductEditSheet**:
- Image-Upload-Zone (Tap → Launcher Photo-Picker; Long-Press → `ImageSearchSheet` öffnen)
- `ImageSearchSheet`: ruft `search-product-images` Edge-Function (DuckDuckGo Proxy), zeigt Thumbnails, Tap lädt Image herunter und upsert in `product-images` Bucket als `{productId}.{ext}` (upsert:true)
- Name (Required)
- Category-Dropdown (mit Inline-Create neue Kategorie)
- Sellprice (Decimal-Input, optional, EUR)
- `Discontinued`-Switch
- Barcodes-Sektion: Liste bekannter Barcodes + "Add Barcode" → startet Barcode-Scanner (siehe 13)
- Save / Cancel / Delete

**Categories-Tab**:
- Liste aller `product_category` mit Produkt-Count je Kategorie
- Edit, Delete, Add (Dialog)

**Import aus Nayax Excel** (nur Admin):
- FAB-Option `Import from Excel`
- System-File-Picker für `.xlsx` via `Intent.ACTION_OPEN_DOCUMENT`
- Parsing via Apache POI (via `org.apache.poi:poi-ooxml`) oder einfacher: `charleskorn.kaml` reicht nicht, nimm POI
- Preview-Liste mit Checkboxen, dann Bulk-Call `import-products` Edge-Function

### 11.7 Warehouse

Quelle: [WarehouseView.swift](../ios/VMflow/Views/Warehouse/WarehouseView.swift), [WarehouseViewModel.swift](../ios/VMflow/ViewModels/WarehouseViewModel.swift), [ProductBatchesView.swift](../ios/VMflow/Views/Warehouse/ProductBatchesView.swift), [BatchAdjustSheet.swift](../ios/VMflow/Views/Warehouse/BatchAdjustSheet.swift)

**Top**:
- Warehouse-Picker (Dropdown)
- Intake-Form (ModalBottomSheet via FAB): Produkt-Picker (mit Barcode-Scan-Icon), Quantity-Stepper, Batch-Number-Input, optional Expiration-Date (Date-Picker), `Book Intake`

**Liste**:
- LazyColumn: Produkt-Image + Name + Total-Quantity + Batch-Count + Earliest-Expiration + Status-Chip (`Out`, `Low`, `Stocked`)
- Sortierung: out-of-stock zuerst, dann low, dann alphabetisch
- Klick → `ProductBatchesScreen`

**ProductBatchesScreen**:
- Liste aller Batches eines Produkts, sortiert nach Expiration aufsteigend
- Je Batch: Batch-Number, Quantity, Expiration, Eingangsdatum
- Tap → `BatchAdjustSheet` mit Radio-Group für `AdjustReason` (Refill-Return, Correction, Damage, Expired) + signed Delta + Notes

**Intake-Form mit Barcode**: Input-Feld hat Barcode-Icon rechts; Tap öffnet `BarcodeScannerScreen`, bei Match wird Produkt vorausgewählt, bei Miss wird "Link barcode to..."-Dialog gezeigt, der zu `ProductEditSheet` → "Add Barcode" navigiert.

### 11.8 Deals

Quelle: [DealsView.swift](../ios/VMflow/Views/Deals/DealsView.swift), [DealCard.swift](../ios/VMflow/Views/Deals/DealCard.swift), [DealDetailSheet.swift](../ios/VMflow/Views/Deals/DealDetailSheet.swift), [DealsViewModel.swift](../ios/VMflow/ViewModels/DealsViewModel.swift)

Only if `companies.deals_enabled = true`.

**Top-Bar**:
- SegmentedControl `Group by: Retailer | Product`
- Search
- Refresh

**Header-KPIs** (3 Chips): Total Deals, Unique Retailers, Avg Discount

**Liste**:
- Gruppiert nach `retailer` oder `product`
- `DealCard`: Produkt-Image, Produktname, Deal-Title, Deal-Price (fett) + Regular-Price (durchgestrichen) + Discount-Badge, Validity-Status-Chip (Upcoming/Active/Expiring/Expired), Confidence-Badge (High/Medium/Low)
- Klick → `DealDetailSheet` mit großem Bild, Retailer-Link, Gültigkeitsdauer, "Open in Retailer App"-Button (wenn `externalUrl`)

**Settings (im Settings-Screen integriert)**: Toggle + ZIP-Code-Input (nötig für Standort-basierte Angebote). Schreibt `companies.deals_enabled` und `companies.deals_zip_code`.

### 11.9 Inbox

Quelle: [InboxView.swift](../ios/VMflow/Views/Inbox/InboxView.swift), [InboxViewModel.swift](../ios/VMflow/ViewModels/InboxViewModel.swift)

**Top-Bar**:
- Filter-Chips: `All`, `Problem`, `Feedback`, `Wish` (jedes mit Badge für offene Counts)
- Toggle `Show only open`

**Liste**:
- LazyColumn, gruppiert nach `createdAt` Tag
- `InboxRow`: Kind-Icon (problem 🔴 / feedback 💬 / wish ⭐), Message (max 3 Zeilen), Maschinen-Name + Email + Timestamp
- SwipeActions: links `Mark reviewed` (grün), rechts `Dismiss` (orange) / `Delete` (rot, Long-swipe)

Statusänderung → PATCH auf `machine_feedback` oder `product_wishes` (abhängig von `source`), dann lokale Optimistic-Update. Badge in `NavigationBar.Item` aktualisiert sich automatisch.

Deep-Link aus Push: `navController.navigate(InboxRoute)`.

### 11.10 Settings

Quelle: [SettingsView.swift](../ios/VMflow/Views/Settings/SettingsView.swift)

Sektionen:

1. **Push Notifications**
   - Master-Toggle (fordert Permission an wenn aktiviert, ruft `registerForRemoteNotifications`)
   - Bei Permission denied: "Open System Settings"-Button
   - Per-Type-Toggles für die 3 Typen (`sale`, `low_stock`, `inbox`)
   - `Send Test Notification`-Button

2. **Deals** — Toggle + ZIP-Input (siehe 11.8)

3. **Account** — Organisation-Name (readonly), Role (readonly)

4. **About** — App-Version + Build-Number

5. **Sign Out** — destructive, mit Bestätigungs-Dialog

### 11.11 Weitere Screens

Aus der iOS-App (vollständigkeitshalber):
- **LoginScreen** (siehe Abschnitt 6 + 11-Logik in `LoginView.swift`)
- **RegisterScreen** mit `email`, `password`, `first_name`, `last_name`
- **AddServerScreen** mit Name/URL/AnonKey + QR-Scan
- **QrScannerScreen** — liest QR-Codes mit erwartetem JSON-Format `{"url":"...", "anonKey":"..."}`
- **NoOrganizationScreen** — wenn eingeloggt aber kein Company-Member

---

## 12. UI-Komponenten & Design-System

### Theme

- **Material3 Expressive** — primäre Farbe Blau (#0A84FF-Äquivalent in Material-Palette), typografie `MaterialTheme.typography` unverändert
- **Dynamic Color** auf Android 12+ aktiviert: `dynamicLightColorScheme(context)` wenn verfügbar, sonst VMflow-eigenes Farbschema
- **Dark Mode** über `isSystemInDarkTheme()` mit `dynamicDarkColorScheme`
- **Shape**: `RoundedCornerShape(14.dp)` für Cards (entspricht iOS `.regularMaterial`-Card mit corner 14)

### Typography-Mapping

| iOS | Android Material3 |
|---|---|
| `.largeTitle.bold()` | `headlineLarge` mit `FontWeight.Bold` |
| `.title2.bold()` | `headlineSmall` mit Bold |
| `.title3` | `titleLarge` |
| `.headline` | `titleMedium` |
| `.subheadline` | `titleSmall` / `bodyLarge` |
| `.body` | `bodyMedium` |
| `.caption` | `labelMedium` |
| `.caption2` | `labelSmall` |
| `.footnote` | `bodySmall` |
| `.monospacedDigit()` | `style.copy(fontFeatureSettings = "tnum")` |

### Farben (Status)

| Zweck | iOS | Android |
|---|---|---|
| Success / Online / High Stock | `Color.green` | `Color(0xFF34C759)` (iOS Green) oder Material `tertiary` |
| Warning / Low | `Color.yellow` | `Color(0xFFFFCC00)` |
| Error / Offline / Critical | `Color.red` | `Color(0xFFFF3B30)` |
| Primary | `Color.blue` | `Color(0xFF0A84FF)` |
| Neutral Amber (min-stock-Marker) | `.orange` | `Color(0xFFFF9500)` |
| Warehouse needsSwap | `.orange` | `Color(0xFFFF9500)` |

Alle Statusfarben auch als `@Composable val` im Theme hinterlegen, damit Dark-Mode-Varianten möglich sind.

### Icons

**Wichtig**: iOS nutzt SF Symbols (`"chart.bar.fill"` etc.), die Android nicht kennt. Mapping auf **Material Symbols** (`androidx.compose.material.icons.Icons.Filled.*` oder via `material-icons-extended`):

| iOS SF Symbol | Material Icon |
|---|---|
| `chart.bar.fill` | `Icons.Filled.BarChart` |
| `storefront.fill` | `Icons.Filled.Storefront` |
| `arrow.clockwise.circle.fill` | `Icons.Filled.Refresh` |
| `tray.fill` | `Icons.Filled.Inbox` |
| `ellipsis.circle.fill` | `Icons.Filled.MoreHoriz` |
| `cube.box.fill` | `Icons.Filled.Inventory2` |
| `shippingbox.fill` | `Icons.Filled.Warehouse` |
| `tag.fill` | `Icons.Filled.LocalOffer` |
| `gearshape.fill` | `Icons.Filled.Settings` |
| `person.fill` | `Icons.Filled.Person` |
| `bell.badge.fill` | `Icons.Filled.NotificationsActive` |
| `paperplane.fill` | `Icons.Filled.Send` |
| `mappin.circle.fill` | `Icons.Filled.LocationOn` |
| `cart.fill` | `Icons.Filled.ShoppingCart` |
| `eurosign.circle.fill` | `Icons.Filled.Euro` oder `Icons.Filled.AttachMoney` (falls `Euro` fehlt) |
| `exclamationmark.triangle.fill` | `Icons.Filled.Warning` |
| `checkmark.circle.fill` | `Icons.Filled.CheckCircle` |
| `xmark.octagon.fill` | `Icons.Filled.Error` |
| `cup.and.saucer.fill` | Custom Vektor (Logo) — aus [BRANDING.md](../BRANDING.md) |
| `vending.machine` | Custom Vektor oder `Icons.Filled.Storefront` als Fallback |
| `building.2` | `Icons.Filled.Business` |
| `rectangle.portrait.and.arrow.right` | `Icons.AutoMirrored.Filled.Logout` |

Alle Icons durch **Material Symbols Expressive** ersetzen, sobald stabil (aktuell in Alpha).

### Zentrale Komponenten

#### `KpiCard`

```kotlin
@Composable
fun KpiCard(
    icon: ImageVector,
    title: String,
    value: String,
    subtitle: String? = null,
    accent: Color = MaterialTheme.colorScheme.primary,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Column(Modifier.padding(14.dp)) {
            Icon(icon, null, tint = accent)
            Spacer(Modifier.height(8.dp))
            Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            Text(
                value,
                style = MaterialTheme.typography.titleLarge.copy(fontFeatureSettings = "tnum"),
                fontWeight = FontWeight.Bold,
                maxLines = 1,
            )
            subtitle?.let {
                Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
        }
    }
}
```

#### `StatusChip` (entspricht `StatusBadge`)

Material3 `InputChip` mit Leading-Circle (grün/rot) + Label. Farbe der `containerColor` = Color mit 12 % Alpha, Labelfarbe voll.

#### `StockBar`

Custom `Canvas`-Composable: Hintergrund `Color.surfaceContainerHighest` als Capsule, Fill mit `animateFloatAsState`, zwei dünne vertikale Marker für `minStock` (orange) und `fillWhenBelow` (blau), optional Label `current/capacity` rechts in monospace.

#### `ProductImage`

```kotlin
@Composable
fun ProductImage(imagePath: String?, size: Dp = 44.dp) {
    if (imagePath.isNullOrBlank()) {
        ProductImagePlaceholder(size)
    } else {
        val url = remember(imagePath) {
            val baseUrl = LocalSupabaseUrl.current
            "$baseUrl/storage/v1/object/public/product-images/$imagePath"
        }
        AsyncImage(
            model = ImageRequest.Builder(LocalContext.current)
                .data(url)
                .crossfade(true)
                .build(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            error = { ProductImagePlaceholder(size) },
            modifier = Modifier.size(size).clip(RoundedCornerShape(8.dp)),
        )
    }
}
```

`LocalSupabaseUrl` ist ein `staticCompositionLocalOf<String>` damit der URL bei Server-Switch immer aktuell ist.

---

## 13. Kamera & Barcode-Scanning

iOS nutzt `AVFoundation` mit Types `ean13, ean8, upce, code128, code39, code93, qr, dataMatrix, interleaved2of5`.

Android: **CameraX + ML Kit Barcode**

```kotlin
@Composable
fun BarcodeScannerScreen(
    onScanned: (String) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val cameraPermission = rememberPermissionState(Manifest.permission.CAMERA)

    LaunchedEffect(Unit) { cameraPermission.launchPermissionRequest() }

    if (!cameraPermission.status.isGranted) {
        Text("Camera permission required")
        return
    }

    val scanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(
                    Barcode.FORMAT_EAN_13, Barcode.FORMAT_EAN_8, Barcode.FORMAT_UPC_E,
                    Barcode.FORMAT_CODE_128, Barcode.FORMAT_CODE_39, Barcode.FORMAT_CODE_93,
                    Barcode.FORMAT_QR_CODE, Barcode.FORMAT_DATA_MATRIX, Barcode.FORMAT_ITF,
                ).build()
        )
    }

    var hasScanned by remember { mutableStateOf(false) }

    AndroidView(
        factory = { ctx ->
            val previewView = PreviewView(ctx)
            val cameraProvider = ProcessCameraProvider.getInstance(ctx).get()

            val preview = Preview.Builder().build().apply {
                setSurfaceProvider(previewView.surfaceProvider)
            }
            val analysis = ImageAnalysis.Builder().build().apply {
                setAnalyzer(Executors.newSingleThreadExecutor()) { imageProxy ->
                    val mediaImage = imageProxy.image ?: run { imageProxy.close(); return@setAnalyzer }
                    scanner.process(InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees))
                        .addOnSuccessListener { barcodes ->
                            val raw = barcodes.firstOrNull()?.rawValue
                            if (raw != null && !hasScanned) {
                                hasScanned = true
                                Haptics.success()
                                onScanned(raw)
                            }
                        }
                        .addOnCompleteListener { imageProxy.close() }
                }
            }
            cameraProvider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            previewView
        },
        modifier = Modifier.fillMaxSize(),
    )
    // Overlay mit Scan-Region-Rahmen + Close-Button + "Scan barcode"-Label (analog iOS)
}
```

Lebensdauer der Scanner-Session: `DisposableEffect` → `scanner.close()`, `cameraProvider.unbindAll()`.

---

## 14. Haptik, i18n, A11y

### Haptik

iOS `HapticFeedback.swift` hat 6 Typen. Android-Mapping via `HapticFeedback`-API + View.performHapticFeedback:

```kotlin
object Haptics {
    private val haptic get() = LocalHapticFeedback.current
    fun light() = haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
    fun medium() = haptic.performHapticFeedback(HapticFeedbackType.LongPress)
    // success/warning/error: kein direktes Pendant, verwende View-basiertes
    // Vibrator mit kurzer Sequenz
}
```

Kompose Alternative für komplexere Patterns: `android.os.VibrationEffect` mit predefined effects (`EFFECT_CLICK`, `EFFECT_DOUBLE_CLICK`, `EFFECT_HEAVY_CLICK`).

### i18n

Komplette Strings aus iOS als `res/values/strings.xml` (EN, default) und `res/values-de/strings.xml`. Regel: **jeder User-sichtbare String** muss über `stringResource(R.string.key)` laufen, keine Hardcodes. Enums wie `NotificationType` speichern nur `key` in der DB, aber Label/Description aus Resources ziehen.

Plurals für Counts (`x machines selected`): `plurals.xml` mit `quantity="one"` und `quantity="other"`.

### Accessibility

- Alle `IconButton` + `Icon` bekommen `contentDescription` (nicht `null` außer bei rein dekorativen Icons neben Labels)
- `ProductImage` ohne Label → `contentDescription = stringResource(R.string.product_image_of, productName)`
- `StockBar` → semantische Properties: `Modifier.semantics { stateDescription = "$current of $capacity" }`
- Minimum Touch-Target 48 dp — Material3 erzwingt das
- `LazyColumn.items(key = { it.id })` immer, damit TalkBack-Reorder stabil bleibt
- High-Contrast-Mode unterstützen: keine reinen Farb-Codierungen, immer Text oder Icon zusätzlich (Beispiel: Status-Chip hat Text "Online"/"Offline", nicht nur grüner/roter Punkt)

---

## 15. Testing

### Unit-Tests

- **Date-Logik**: Wochen-Grenzen (Montag-basiert), Gruppierung nach Tag (today/yesterday/EEEE d MMMM)
- **Aggregation**: `MachineRepository.buildMachineStats()` — gegen Beispiel-Daten, die aus iOS Fixture-JSON exportiert werden
- **Warehouse-Cap**: `packingQuantity` + `displayQuantity` + `maxPackingQuantity` + `remainingWarehouseStock`
- **Refill-State-Persistence**: TTL-Check (24h), serialize/deserialize
- **Pick-Order-Traversal**: gemockte `warehouse_position_groups` + `warehouse_product_positions` → erwartete ID-Reihenfolge

### Compose UI-Tests

- **Login-Flow**: eingabe, validation, error state, success state
- **Dashboard**: KPIs, Chart-Data, Recent-Sales-Grouping, Empty-States
- **Refill**: Step-Navigation, Replace-Flow, Packing-Checkboxes, Start-Tour, Confirm-Refill, Persist → Resume
- **Inbox**: Filter, Swipe-Actions, Status-Update

### Integration

- **Supabase-Mock-Server** via Ktor MockEngine — tests gegen ein In-Memory-PostgREST-Stub
- **Hilt Test**: jede Repository-Instanz kann mit Test-Double ersetzt werden

### E2E (optional)

**Maestro** Flows für: Login → Dashboard → Machines → Machine-Detail → Trays → Refill Wizard (Happy-Path). Läuft in CI auf einem Emulator.

---

## 16. Release-Checkliste

Vor dem 1.0-Release (Feature-Parität zu iOS 1.0 / Build 955) müssen alle diese Punkte abgehakt sein:

- [ ] Alle Features aus Abschnitt 11 funktionieren wie iOS
- [ ] Dark-Mode korrekt gerendert auf allen Screens
- [ ] Dynamic Color auf Android 12+ aktiv, Fallback auf brand-Palette auf 8–11
- [ ] Foldable-Test: Galaxy Z Fold / Pixel Fold → `SupportingPaneScaffold` zeigt List+Detail
- [ ] Tablet-Test: `NavigationRail` + adaptive Panes
- [ ] i18n: alle Screens auf DE + EN geprüft, keine `TODO`-Strings
- [ ] Accessibility-Audit: TalkBack, Switch-Access, Large-Text (`fontScale = 1.5`), High-Contrast
- [ ] Push-Ende-zu-Ende: APNs-Äquivalent (FCM) vom Backend empfangen, Channel-korrekt, Deep-Link funktioniert, Badge aktualisiert
- [ ] Barcode-Scanner: EAN-13, QR-Code, Code-128 getestet
- [ ] Network Security Config: Dev-Flavor erreicht `10.0.*`, Prod-Flavor lehnt Cleartext ab
- [ ] `google-services.json` in `.gitignore`, Build-Script dokumentiert
- [ ] Realtime-Subscribe → Dashboard / Machines / Trays / Refill / Inbox reloaden live
- [ ] Refill-Tour-Resume funktioniert nach App-Kill (DataStore) und TTL greift nach > 24h
- [ ] Server-Switch funktioniert: Dev ↔ Prod-Toggle, keine Session-Reste
- [ ] Splash-Screen-API ohne Flicker
- [ ] ProGuard/R8-Keep-Regeln für kotlinx.serialization + Supabase-SDK hinzugefügt
- [ ] `versionCode` aus `git rev-list --count HEAD`, `versionName = "1.0"`
- [ ] Play-Store-Listing: Screenshots (Handy + 7"-Tablet + 10"-Tablet + Foldable), Feature-Grafik, Description EN + DE
- [ ] `app-bundle`-Build (`.aab`) signiert mit Release-Keystore, Deobfuscation-File hochgeladen
- [ ] Pre-Launch-Report in Play Console ohne Crashes

### ProGuard / R8

`proguard-rules.pro`:

```proguard
# Supabase Kotlin SDK + Ktor
-keep class io.github.jan.supabase.** { *; }
-keep class io.ktor.** { *; }

# kotlinx.serialization
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class ** { *** Companion; }
-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> { *** Companion; *** INSTANCE; kotlinx.serialization.KSerializer serializer(...); }

# Data-Classes (Models)
-keep class de.kerlhandel.vmflow.data.model.** { *; }

# Firebase / FCM
-keep class com.google.firebase.** { *; }
```

---

## 17. iOS → Android Mapping-Referenz

Schnellreferenz für das Team, das die Umsetzung macht:

| iOS / SwiftUI | Android / Compose |
|---|---|
| `@MainActor final class XxxViewModel: ObservableObject` | `class XxxViewModel @Inject constructor(...) : ViewModel()` + `@HiltViewModel` |
| `@Published var x` | `val _x = MutableStateFlow(...); val x = _x.asStateFlow()` |
| `@StateObject private var vm = ...()` | `val vm: XxxViewModel = hiltViewModel()` |
| `@EnvironmentObject var auth` | `val auth: AuthRepository = hiltViewModel<...>().authState.collectAsStateWithLifecycle()` oder CompositionLocal |
| `NavigationStack` / `NavigationLink` | `NavHost` + `navController.navigate(route)` |
| `NavigationSplitView` | `ListDetailPaneScaffold` / `NavigationRail` + `Scaffold` |
| `TabView` | `Scaffold(bottomBar = { NavigationBar { ... } })` |
| `.task { ... }` | `LaunchedEffect(Unit) { ... }` |
| `.refreshable { ... }` | `PullToRefreshBox` (Material3 Adaptive) |
| `.searchable(text:)` | `SearchBar` (Material3) |
| `.sheet(isPresented:)` | `ModalBottomSheet` |
| `.alert(title, isPresented:)` | `AlertDialog` |
| `.confirmationDialog(...)` | `AlertDialog` mit "Cancel" + "OK" |
| `AsyncImage` | `AsyncImage` (Coil3) |
| `Chart` (Swift Charts) | Vico 2 oder Compose Canvas |
| `Form` / `List` | `LazyColumn` mit `ListItem` |
| `Button(role: .destructive)` | `TextButton(colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error))` |
| `Stepper` | Zwei `IconButton` (−, +) um einen `Text` |
| `SegmentedPicker` | `SingleChoiceSegmentedButtonRow` |
| `.monospacedDigit()` | `Modifier`/Style mit `fontFeatureSettings = "tnum"` |
| `@FocusState` | `rememberFocusRequester()` + `FocusManager` |
| `LocalizedStringKey` | `stringResource(R.string.xxx)` |
| `UserDefaults` | `DataStore<Preferences>` |
| `UNUserNotificationCenter` | `NotificationManagerCompat` + FCM |
| `UNNotificationServiceExtension` | `FirebaseMessagingService.onMessageReceived` + WorkManager |
| `AVCaptureMetadataOutput` | CameraX + ML Kit Barcode |
| `URLSession` | Ktor Client (ist Teil der Supabase-SDK) |
| `Codable` + `CodingKeys` | `@Serializable` + `@SerialName` |
| `async let a = ...; await (a, b)` | `coroutineScope { val a = async { ... }; a.await() }` |
| `for await x in stream` | `flow.collect { x -> ... }` |
| `@unchecked Sendable` | N/A (Kotlin hat anderes Thread-Model) |

---

## Anhang A — Edge-Functions verwendet

Die Android-App ruft exakt dieselben Edge-Functions wie die iOS-App. Alle liegen in [Docker/supabase/functions/](../Docker/supabase/functions/):

| Function | Benutzt von | Auth | Zweck |
|---|---|---|---|
| `get-my-organization` | `AuthRepository.fetchOrganization()` | JWT | Liefert `{organization, role}` für den aktuellen User |
| `register-push` | `NotificationRepository.registerToken()` | JWT | Speichert FCM/APNs-Token — **muss Android erweitert unterstützen** |
| `register-push` (DELETE) | `NotificationRepository.unregister()` | JWT | Logout-Cleanup |
| `test-push` | Settings → Test-Button | JWT | Schickt Test-Push |
| `machine-insights` | `MachineDetail → Insights Tab` | JWT | AI-gestützte Analyse |
| `search-product-images` | `ProductEditSheet → Image Search` | JWT | DuckDuckGo-Proxy |
| `deal-search` | `DealsViewModel.fetchDeals()` | JWT | Retailer-Offer-Aggregator |
| `claim-device` | Von ESP32, NICHT vom Client | — | nur zur Info |

---

## Anhang B — PostgREST-Tabellen (Read-Write)

Zugriffe, die der Android-Client macht (alle via RLS geschützt):

**Read**: `vendingMachine`, `embeddeds`, `sales`, `paxcounter`, `machine_trays`, `products`, `product_category`, `product_barcodes`, `warehouses`, `warehouse_stock_batches`, `warehouse_transactions`, `warehouse_position_groups`, `warehouse_product_positions`, `machine_feedback`, `product_wishes`, `companies`, `organization_members`, `notification_preferences`, `activity_log`, `deals`.

**Write (Insert/Update/Delete)**:
- `machine_trays` (tray-CRUD + stock-adjust)
- `machine_feedback`, `product_wishes` (status update, delete)
- `products`, `product_category`, `product_barcodes` (CRUD)
- `warehouse_stock_batches` (Insert via intake + Update via adjust)
- `warehouse_transactions` (Insert: intake, adjustment)
- `notification_preferences` (Upsert)
- `companies` (Update: deals_enabled, deals_zip_code, anthropic_api_key, velocity_days)
- `activity_log` (Insert während Refill-Tour)

**RPCs**: `deduct_warehouse_stock_fifo`, `delete_sale_and_restore_stock`, `insert_manual_sale`, `get_machine_insights_kpis`, `get_product_sales_velocity`.

**Storage**: Bucket `product-images` (Upload + Delete bei Produkt-Management).

---

## Anhang C — Known iOS Quirks, die auf Android repliziert werden müssen

Diese Details sind in der iOS-Codebasis in Kommentaren dokumentiert; sie sind nicht offensichtlich und werden sonst übersehen.

1. **Realtime Subscribe-Order**: Postgres-Change-Listener müssen **vor** `channel.subscribe()` registriert werden, sonst ignoriert der Server sie. Siehe [RealtimeService.swift:32](../ios/VMflow/Services/RealtimeService.swift).
2. **`product_id` muss explizit null sein**: Bei `PATCH machine_trays` wird ein weggelassenes `product_id` von PostgREST als "nicht ändern" interpretiert. Der Client muss `product_id: null` schicken, wenn er das Produkt vom Tray entfernen will. Siehe [Tray.swift:118](../ios/VMflow/Models/Tray.swift) `TrayUpsert.encode(to:)`.
3. **Wochenstart = Montag**: Alle "This Week" / "Last Week"-Berechnungen beginnen Montag 00:00. Siehe [MachineListViewModel.swift:42](../ios/VMflow/ViewModels/MachineListViewModel.swift).
4. **`item_price` ist EUR, nicht Cent**: niemals durch 100 teilen. In [CLAUDE.md](../CLAUDE.md) als absolute Regel dokumentiert.
5. **Refill-Tour-TTL 24h**: Persistierter State wird älter als 24h automatisch verworfen. Siehe [RefillWizardViewModel.swift:278](../ios/VMflow/ViewModels/RefillWizardViewModel.swift).
6. **Fallback auf Tray-Lookup bei Sales ohne `product_id`**: Ältere Sales vor der Migration `20260412...` haben kein `product_id` snapshot — muss via `machine_id + item_number → machine_trays.products` aufgelöst werden. Siehe [DashboardViewModel.swift:209](../ios/VMflow/ViewModels/DashboardViewModel.swift).
7. **Pick-Order depth-first durch Gruppen**: Wenn `warehouse_position_groups` leer sind, fallback auf quantity-descending-Sortierung. Wenn Gruppen existieren, depth-first-traversal. Unpositionierte Produkte kommen am Ende. Siehe [RefillWizardViewModel.swift:1188](../ios/VMflow/ViewModels/RefillWizardViewModel.swift).
8. **Session-Cancel-Check in Catch**: SwiftUI canceled `.refreshable`-Tasks routinemäßig → iOS fängt `CancellationError` ab, um nicht als User-Error angezeigt zu werden. Android muss `CancellationException` via `catch (e: CancellationException) { throw e }` in Repositories re-throwen, damit Coroutine-Cancelation sauber propagiert.
9. **Notification Content Handler "at most once"**: iOS `NotificationService`-Extension ruft `contentHandler` höchstens einmal auf, selbst unter Timeout + Download-Completion race. Android hat den analogen Fall in `FcmService`: Worker muss idempotent sein — dieselbe Notification nicht zweimal posten.

---

**Ende des Dokuments.** Fragen und Umsetzungsdetails bitte gegen den iOS-Code cross-checken, nicht gegen die Web-App — die beiden divergieren inzwischen in mehreren Aggregations-Details.
