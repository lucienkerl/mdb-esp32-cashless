# Analytics Dashboard (Web + iOS Big Bang)

**Date:** 2026-05-09
**Status:** Draft

## Problem

The product has three surfaces that touch sales data today and none of them answer the question *"how is my fleet actually performing, and where am I losing revenue?"*:

- **`/` Dashboard** is a daily-pulse view: today/week/month KPIs, a 7-day chart, recent sales, top-5 products. Good for the morning glance, but it can't slice by category, channel, weekday or hour, and it cannot answer "which machine has been losing me money for two weeks?".
- **`/reports`** is a tax/accounting export tool — DATEV CSV, VAT breakdown. It does not visualize trends, does not compare periods, and does not surface anomalies. It is a deliverable for the tax advisor, not a decision tool.
- **`/machines/[id]`** has a 30-day chart per machine and AI insights, but only one machine at a time and no cross-machine comparison.

The operator needs a comprehensive analytics surface that lets them slice the entire dataset by any dimension, compare periods, find slow-movers and stockouts, and quantify lost revenue. They want a BI-tool feel — sortable tables, filtered charts, drill-throughs — without leaving the product.

## Goals

- **Comprehensive `/analytics` page on web**, six themed tabs (Overview, Sales, Products, Machines, Conversion, Operations) with a global filter bar that applies across all tabs.
- **Native iOS Analytics section** with the same six sections, adaptive layout: tile-menu on iPhone (under "More" tab), `NavigationSplitView` on iPad/Mac.
- **Single source of truth for backend aggregations**: the same six SQL RPCs serve web and iOS — no duplicate aggregation logic.
- **Drill-throughs that respect the filter model**: clicking a numeric cell sets a global filter; clicking a name pushes to the existing detail page.
- **Filter persistence**: shareable URL on web, `@AppStorage` on iOS, named presets on both, identical serialization format on both platforms.
- **Stockout history** so the operator can quantify lost revenue per tray and find chronic-empty trays (new `tray_stockout_events` table + trigger).
- **Backwards compatibility**: all changes are additive (new tables, new RPCs, new triggers — no edits to existing migration files, no schema changes that affect firmware or existing UIs).

## Non-Goals

- **No margin / profit / cost-of-goods tracking in V1.** Revenue, units, conversion, lost-revenue-estimate are computed from `sales.item_price` and `paxcounter.count`. Margin tracking with FIFO batch costs is captured as future work in "Out of Scope". This decision dropped four critical migration risks and roughly halves Phase 0.
- **No pivot/canvas-style ad-hoc chart builder.** Tabs are curated, not a blank canvas.
- **No DB-backed shared filter presets.** V1 stores presets in `localStorage` (web) / `@AppStorage` (iOS).
- **No per-user dashboard customization** (drag-and-drop widgets, custom KPIs).
- **No new edge functions.** All backend logic ships as Postgres RPCs.
- **No PDF export in V1** — CSV everywhere, PNG chart snapshot on web only. PDF is V2.
- **No 60-second auto-refresh polling.** Refresh is filter-change-triggered, pull-to-refresh, or explicit "new data available" toast (Overview tab only).
- **No iPhone geo-map in V1.** The lat/lng-based revenue map renders on web and iPad. iPhone gets a sortable list.
- **No real-time recompute on Sale INSERT.** Only Overview shows a "new data available" pill.
- **No machine uptime % or MTBF in V1.** The codebase has no historical online/offline log; computing rolling uptime would require a new `embeddeds_status_history` table outside this spec's scope.

## Architecture

### Web (Nuxt 4)

```
management-frontend/app/
├── pages/analytics/
│   └── index.vue                       # Single page, tab routing via URL hash (#sales etc.)
├── composables/
│   ├── useAnalyticsFilters.ts          # Global filter state + URL query sync + preset persistence
│   ├── useAnalyticsData.ts             # RPC dispatch per tab, debounced re-fetch, 30s in-memory cache
│   └── useAnalyticsExport.ts           # CSV export, PNG chart snapshot
├── components/analytics/
│   ├── AnalyticsFilterBar.vue          # Sticky top: date range + machines + channels + categories + VAT
│   ├── AnalyticsTabNav.vue             # Horizontal tab switcher
│   ├── AnalyticsKpiGrid.vue            # 1-4 KPI cards with period-comparison delta badges
│   ├── AnalyticsChart.vue              # Wraps ChartAreaInteractive with title/legend/loading state
│   ├── AnalyticsTable.vue              # Sortable, drill-throughable, exportable table
│   ├── AnalyticsCompareSheet.vue       # Side-by-side 2-4 machine compare overlay
│   ├── AnalyticsPresetMenu.vue         # Preset save/select/delete dropdown
│   └── tabs/
│       ├── TabOverview.vue
│       ├── TabSales.vue
│       ├── TabProducts.vue
│       ├── TabMachines.vue
│       ├── TabConversion.vue
│       └── TabOperations.vue
```

- **Tab routing via URL hash** (`/analytics#products`) instead of separate routes — keeps filter state across tab switches without remount, browser-back works.
- **Filter state**: lives in `useAnalyticsFilters` composable, backed by `useState('analytics-filters')` (SSR-safe). On client mount, syncs from URL query params. On filter change, debounced URL replace + RPC re-fetch.
- **Data fetch is per-active-tab** — switching tabs lazily fetches; results cached in `useAnalyticsData` for 30 s keyed on serialized filter state.
- **AI insights re-home**: the existing `companyInsights` block on `/` moves into `TabOverview.vue`. Dashboard `/` no longer renders it. The insights query continues to use the **company-wide** period (its existing `velocity_days` setting) — it does *not* receive the analytics filter, because re-prompting AI on every filter change is expensive and the AI summary is meant to be a stable monthly read.

### iOS (SwiftUI)

```
ios/VMflow/
├── Models/
│   └── AnalyticsFilter.swift                      # ObservableObject, persisted via @AppStorage
├── ViewModels/
│   ├── AnalyticsRootViewModel.swift               # Tab selection state
│   ├── AnalyticsOverviewViewModel.swift
│   ├── AnalyticsSalesViewModel.swift
│   ├── AnalyticsProductsViewModel.swift
│   ├── AnalyticsMachinesViewModel.swift
│   ├── AnalyticsConversionViewModel.swift
│   └── AnalyticsOperationsViewModel.swift
└── Views/Analytics/
    ├── AnalyticsRootView.swift                    # iPhone: tile menu | iPad/Mac: NavigationSplitView
    ├── AnalyticsFilterSheet.swift                 # Bottom sheet (iPhone) / inspector (iPad)
    ├── AnalyticsCompareView.swift                 # Side-by-side machine compare
    ├── Components/
    │   ├── AnalyticsKPIGroup.swift                # Wraps existing KPICard with comparison badge
    │   ├── AnalyticsChart.swift                   # SwiftUI Charts wrapper, scrubbable, scrollable
    │   ├── AnalyticsSortableList.swift            # Sortable rows with swipe + drill-through
    │   ├── ComparePeriodBadge.swift               # +12% green / -8% red badge
    │   └── AnalyticsHeatmap.swift                 # Hour×weekday or machine×hour grid
    └── Sections/
        ├── AnalyticsOverviewView.swift
        ├── AnalyticsSalesView.swift
        ├── AnalyticsProductsView.swift
        ├── AnalyticsMachinesView.swift
        ├── AnalyticsConversionView.swift
        └── AnalyticsOperationsView.swift
```

- **`SidebarItem.analytics`** added to `AppNavigation.swift` with icon `chart.xyaxis.line`. iPad/Mac shows it directly in the sidebar. iPhone surfaces it under the existing "More" tab — note this brings the More list to seven items (cashBook, products, warehouse, deals, settings + analytics + the existing five-pattern). No tab-bar slot is reused.
- **`AnalyticsRootView` is adaptive**: reads `@Environment(\.horizontalSizeClass)`. On compact (iPhone), it is a `NavigationStack` with a tile-menu landing screen — six tiles in a 2-column grid, each pushes its `AnalyticsXxxView`. On regular (iPad/Mac), it is a `NavigationSplitView` with a section list on the left and the selected section on the right.
- **Filter ownership**: `AnalyticsFilter` is an `ObservableObject` with `@Published` properties. It is owned as `@StateObject` by `AnalyticsRootView` and injected to every section via `.environmentObject(...)`. On filter change, each section's ViewModel observes a Combine `objectWillChange` from the filter and triggers a debounced reload. `@AppStorage("analytics.filter.current")` persists the JSON-encoded current filter; named presets live at `@AppStorage("analytics.filter.presets")` as a JSON array.
- **Realtime hookup**: `AnalyticsOverviewViewModel` subscribes to `RealtimeService.salesVersion`. On increment, it sets `hasNewData = true`, which the view renders as a small "Neue Daten — aktualisieren" pill above the KPIs. No automatic reload.

### Shared Backend

- **Six new Postgres RPCs** (see Data Model section). All use the same filter signature.
- **One new table**: `tray_stockout_events`.
- **No changes to existing triggers, RPCs, or schemas.** The sales trigger is untouched. The refill flow is untouched. This is critical: the codebase had a costly outage in 2026-04-11 from a sales-trigger regression, and dropping margin tracking from V1 means we don't go near it.
- All RPCs are direct supabase-js / supabase-swift `.rpc(...)` calls using the authenticated user's JWT — RLS enforced via `my_company_id()` inside each RPC.

## Data Model

### Migration 1 — Stockout Events

File: `Docker/supabase/migrations/YYYYMMDDHHMMSS_analytics_stockout_events.sql`

```sql
CREATE TABLE public.tray_stockout_events (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tray_id                uuid NOT NULL REFERENCES public.machine_trays(id) ON DELETE CASCADE,
  machine_id             uuid NOT NULL,
  item_number            int  NOT NULL,
  product_id             uuid REFERENCES public.products(id) ON DELETE SET NULL,
  started_at             timestamptz NOT NULL,
  ended_at               timestamptz,
  duration_seconds       int GENERATED ALWAYS AS
    (EXTRACT(EPOCH FROM (ended_at - started_at))::int) STORED,
  lost_units_estimated   numeric,
  lost_revenue_estimated numeric,         -- = lost_units_estimated × products.sellprice at close time
  velocity_at_close      numeric,         -- audit trail
  company_id             uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  created_at             timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_stockouts_one_open_per_tray
  ON public.tray_stockout_events (tray_id) WHERE ended_at IS NULL;

CREATE INDEX idx_stockouts_company_started
  ON public.tray_stockout_events (company_id, started_at DESC);

ALTER TABLE public.tray_stockout_events ENABLE ROW LEVEL SECURITY;

-- RLS: select / insert / update / delete WHERE company_id = my_company_id()
-- Standard pattern, see existing tables in 20260305000000_warehouse_inventory.sql for reference.
```

The unique partial index `idx_stockouts_one_open_per_tray` enforces that a single tray can have at most one open event at a time — defense against duplicate trigger firings.

**Trigger:** `AFTER UPDATE OF current_stock ON public.machine_trays`, named `zzz_tray_stockout_event` so it sorts after any other future UPDATE-OF-current_stock trigger:

- If `OLD.current_stock > 0 AND NEW.current_stock = 0`:
  ```sql
  INSERT INTO tray_stockout_events (tray_id, machine_id, item_number, product_id,
                                    started_at, company_id)
  VALUES (NEW.id, NEW.machine_id, NEW.item_number, NEW.product_id,
          now(), <NEW.company_id via lookup>)
  ON CONFLICT DO NOTHING;
  ```
- If `OLD.current_stock = 0 AND NEW.current_stock > 0`:
  ```sql
  -- Compute velocity for this product (single-product call)
  v_velocity := get_product_velocity_one(<company_id>, NEW.product_id, 30);
  v_sellprice := (SELECT sellprice FROM products WHERE id = NEW.product_id);
  v_duration_h := EXTRACT(EPOCH FROM (now() - <event.started_at>)) / 3600;

  UPDATE tray_stockout_events
  SET ended_at              = now(),
      velocity_at_close     = v_velocity,
      lost_units_estimated  = ROUND(v_velocity * v_duration_h / 24.0, 2),
      lost_revenue_estimated = ROUND(v_velocity * v_duration_h / 24.0
                                     * COALESCE(v_sellprice, 0), 2)
  WHERE tray_id = NEW.id AND ended_at IS NULL;
  ```

The trigger only fires on the literal `current_stock` column, so refills, sales, and manual adjustments all go through one path.

**New helper function `get_product_velocity_one(p_company_id uuid, p_product_id uuid, p_days int)`**: returns avg daily units for a single product in the last `p_days`. Reuses the same query as `get_product_sales_velocity` but filtered to one product and returning a scalar — avoids fetching the entire fleet's velocity table from inside a per-tray trigger. Implemented as a small `STABLE SECURITY DEFINER` SQL function.

**Pre-migration data**: `tray_stockout_events` is empty at install. Operations tab shows a banner when filter range extends before the migration timestamp: "Stockout-Daten verfügbar ab DD.MM.YYYY".

### Migration 2 — Six Analytics RPCs

File: `Docker/supabase/migrations/YYYYMMDDHHMMSS_analytics_rpcs.sql`

**Shared filter signature** (all six RPCs):

```sql
(
  p_company_id      uuid,
  p_from            timestamptz,
  p_to              timestamptz,
  p_compare_from    timestamptz,        -- NULL skips comparison
  p_compare_to      timestamptz,
  p_machine_ids     uuid[],             -- NULL or empty = all
  p_channels        text[],             -- NULL or empty = all
  p_category_ids    uuid[],             -- NULL or empty = all
  p_vat_rates       numeric[]           -- NULL or empty = all
) RETURNS jsonb
```

All RPCs are `SECURITY DEFINER`, validate `p_company_id = my_company_id()` at entry, and return `jsonb`. **Note for implementer:** `my_company_id()` and `i_am_admin()` themselves must remain `SECURITY DEFINER` — see migration `20260418000000_fix_rls_recursion_api_auth.sql`. A regression here causes RLS recursion errors (54001) — this broke production once.

**Internal helper `_analytics_filtered_sales_subquery(filters jsonb)`**: returns a `text` containing the `WHERE` clause (or a SQL view definition) for the filtered `sales` rows. All six RPCs `EXECUTE` against it, so filter logic is not duplicated six times.

**Response payload versioning**: every RPC returns `{ "version": 1, ... }` so future shape changes are visible to clients. Web/iOS check `version` and surface a "Update available" banner if mismatched.

| RPC | Returns (jsonb keys) |
|-----|----------------------|
| `analytics_overview` | `version`, `kpis: {revenue, units, avg_basket, conversion_pct}`, `kpis_compare: {...}`, `daily_series: [{date, revenue, units}]`, `top_products`, `top_machines` |
| `analytics_sales_breakdown(p_dimension text)` | `version`, `dimension`, `rows: [{key, label, revenue, units, avg_basket, count, share_revenue_pct, share_units_pct}]` — `p_dimension ∈ {'machine','product','category','channel','vat','hour','dow'}` |
| `analytics_products` | `version`, `kpis: {active_count, slow_mover_count, discontinued_count}`, `products: [{id, name, image_path, category_id, velocity, units, revenue, mix_pct, vat_rate, status, slow_mover_days}]`, `mix_shift_series` — `status ∈ {'active','slow','dead','discontinued'}` |
| `analytics_machines` | `version`, `kpis: {active_count, best_machine_id, best_revenue, avg_conversion_pct}`, `machines: [{id, name, lat, lng, status, revenue, units, conversion_pct, last_sale_gap_minutes, stock_health, current_online}]`, `heatmaps: {<machine_id>: {dow: [...], hour: [...]}}` (separated for payload size) |
| `analytics_conversion` | `version`, `kpis: {footfall, conversion_pct, best_machine_id, empty_passes}`, `machines: [{id, name, pax, sales, conversion_pct, revenue_per_visitor}]`, `hour_heatmap`, `daily_conversion_series` |
| `analytics_operations` | `version`, `kpis: {stockout_hours, lost_revenue, refill_tour_count, avg_stock_cover_days}`, `stockout_events`, `refill_tours`, `stock_cover` |

**Naming consistency**: the column is called `avg_basket` in every RPC (revenue / count). All units are explicit:
- `revenue numeric` — EUR (matching `sales.item_price`)
- `units int` — count of sale rows
- `conversion_pct numeric` — 0..100, two decimals
- `share_*_pct numeric` — 0..100
- All durations in seconds or minutes, named accordingly

`get_product_sales_velocity` (existing) is reused by `analytics_products`. `analytics_operations.refill_tours` is computed from `activity_log` rows grouped by `metadata->>'tour_id'` (with the same 10-minute fallback bucketing logic that `useTourHistory.ts` uses today) — there is **no `tour_history` table**.

`analytics_operations.stock_cover` joins `machine_trays` with `get_product_sales_velocity` and computes `cover_days = current_stock / NULLIF(velocity, 0)`.

### Backwards Compatibility

- New table is additive; no existing column or trigger is modified.
- Pre-migration data: stockout events table is empty; all other queries work normally on existing sales / machine_trays / paxcounter rows.
- Stockout banner ("Daten verfügbar ab …") is shown for any filter window extending before the migration timestamp.
- All RPCs are new functions — no existing function is replaced.

## Tab Contents

Global filter bar (always visible at top, sticky on scroll): **date range** with presets (Today / 7d / 30d / 90d / YTD / 12M / Custom) + period-comparison toggle, **machines** multi-select, **channel** toggles (cashless / cash / card), **categories** multi-select, **VAT-rates** multi-select. Reset button + "Save as preset" dropdown. URL query sync on web. Filter panel collapses to a "Filters · 3 active" pill on small screens.

### Tab 1 — Overview

- **KPI cards (4)**: Revenue · Units · Avg basket · Conversion %
  Each shows current period absolute value + period-comparison delta badge (`+12%` green / `-8%` red, with arrow icon).
- **Main chart**: daily revenue line over selected period, with units as second y-axis. Period-comparison overlay (dotted) toggled via filter bar. Scrubbable on iOS via `chartXSelection`.
- **Top 5 Products** compact table (image, name, units, revenue, mix %). Click name → push to product detail. Click numeric cell → set product filter, switch to Sales tab.
- **Top 5 Machines** compact table (name, status badge, revenue, conversion %). Click name → push to machine detail. Click numeric cell → set machine filter.
- **AI Insights module** — the existing `companyInsights` UI moves here verbatim. Uses the company's `velocity_days` setting, not the analytics filter.

### Tab 2 — Sales (Breakdown Workbench)

- **KPI cards (4)**: Revenue · Units · Avg basket · Sales count
- **Dimension switcher** — picker: Machine / Product / Category / Channel / VAT rate / Hour / Day-of-week
- **Visualization**: bar chart by dimension value (toggle metric: revenue / units / avg-basket). For Hour or Day-of-week dimension, render as heatmap (weekday × hour) instead of bar.
- **Sortable table** below: all dimension values, columns revenue / units / avg-basket / share-revenue-% / share-units-%. Click row → set corresponding filter, stay on tab.
- Drill cell (number) → filter; drill name → detail.

### Tab 3 — Products

- **KPI cards (4)**: Active · Slow-movers (no sale 30 d) · Discontinued · Categories with sales
- **Product list**: image + name. Columns: Velocity (units/day) · Units · Revenue · Mix % · VAT · Last sold · Status badge (active / slow / dead / discontinued)
- **Sub-filters**: category, status toggle, "only slow-movers"
- **Search** by name (web `<input>`, iOS `.searchable`)
- **Mix-shift chart**: stacked-area over time, category share of revenue
- Drill: row name/image → existing `ProductDetailSheet` (iOS) or `/products` page with that row pre-expanded (web — note: there is no `/products/[id]` route today; we open the detail modal in-place)

### Tab 4 — Machines

- **KPI cards (4)**: Active count · Best machine (name + revenue) · Avg conversion % · Total stockout hours (period)
- **Machine table/cards**: name, status badge, revenue, units, conversion %, last-sale-gap, stock-health bar (existing component), online indicator
- **Heatmap toggle**: weekday × hour per machine
- **Compare button**: multiselect up to 4 machines → opens `AnalyticsCompareSheet` with side-by-side mini-charts (revenue trend, conversion trend, top-3 products per machine). On iPhone presented as stepwise sheet.
- **Geo map** (web + iPad only): bubbles from `sales.lat/lng`, size = revenue, color = conversion percentile
- Drill: machine name → existing `MachineDetailView` / `/machines/[id]`

### Tab 5 — Conversion (Pax × Sales — the unique-here surface)

- **KPI cards (4)**: Footfall · Conversion % · Best converting machine · Empty passes (visitors − sales)
- **Heatmap**: machines × hour, color = conversion %
- **Scatter**: x = traffic, y = revenue, each point a machine. Diagonal reference at fleet-average conversion. Click point → push to machine detail.
- **Daily conversion trend**: line chart, with Δ vs comparison period
- **Per-machine table**: pax · sales · conversion % · revenue per visitor

### Tab 6 — Operations

- **KPI cards (4)**: Stockout hours · Lost revenue (€) · Refill tours · Avg stock cover days
- **Stockout events list** from `tray_stockout_events`: machine · tray · product · started_at · duration · estimated lost €. Sortable by lost €. Click → opens machine-detail with the tray pre-focused.
- **Refill efficiency** from `activity_log` grouped by `metadata->>'tour_id'` (same logic as `useTourHistory.ts`): per-tour duration, units refilled, machines visited, total restocked-units. Compute units-per-minute as efficiency proxy.
- **Stock-cover-days** per tray (current_stock / daily_velocity), sorted ascending. Trays under 3 days highlighted red. Click → opens Refill wizard with that machine pre-selected.

(Note: machine uptime % was discussed and dropped from V1 — see Non-Goals — because the codebase has no historical online/offline log.)

### Drill-Through Convention (applies everywhere)

| Click target | Behavior |
|--------------|----------|
| Numeric cell (revenue, units, conversion, etc.) | Sets the corresponding global filter, stays on current tab |
| Name or image (product, machine, category) | Pushes to the existing detail page/sheet |
| "Compare" buttons | Opens `AnalyticsCompareSheet`, no tab change |

iOS uses `NavigationLink` for pushes and `.onTapGesture` for filter-set actions. Web uses `<NuxtLink>` for pushes and click-handlers for filter updates.

### iOS-Specific Tab Adaptations

- **Overview**: KPI grid 2×2 on iPhone / 1×4 on iPad. Main chart full-width, scrollable on iPhone via `.chartScrollableAxes(.horizontal)` + `.chartXVisibleDomain(length: 30 * 86400)`. Minimum iOS deployment target stays at the project's existing baseline (iOS 17+ confirmed by `Charts` API usage in `DashboardView.swift`).
- **Sales**: dimension switcher as scrollable tag-pills (`ScrollView(.horizontal)`) — segmented control caps at ~5 items.
- **Products**: `.searchable` searchbar, `List` with thumbnails, sub-filters via toolbar `Menu`.
- **Machines**: existing `MachineCard` list. Compare on iPhone is stepwise; on iPad multi-select inline. Geo map only on iPad.
- **Conversion**: full heatmap only on iPad. iPhone reduces to a list with conversion bars per row.
- **Operations**: list of stockouts with `.swipeActions` ("Plan tour", "Mark resolved"). Refill tours collapsible per day.

## Filter System & Cross-Cutting

### Filter URL/preset serialization (single canonical format, web ↔ iOS-compatible)

JSON object with these exact keys, base64url-encoded when used in a URL query:
```
{
  "v": 1,                                  // schema version
  "from": "2026-04-09T00:00:00Z",          // ISO 8601 UTC
  "to":   "2026-05-09T23:59:59Z",
  "compare": false,                        // bool, period-comparison toggle
  "machines": ["uuid1","uuid2"],           // [] = all
  "channels": ["cashless","cash"],         // [] = all
  "categories": ["uuid"],                  // [] = all
  "vatRates": [0.07, 0.19]                 // [] = all
}
```
Web URL: `/analytics?f=<base64url>#sales`. Length budget ~1500 chars; for longer filter sets the URL falls back to `?preset=<name>`.

iOS `@AppStorage` writes the same JSON (without base64), so a "save preset on iPhone, share via web URL" round-trip works.

### Loading states

- **Filter change**: existing data fades to 60% opacity, inline spinner appears next to filter bar, debounced 300 ms, then re-fetch and fade back to 100%.
- **Initial tab load**: skeleton boxes for charts, shimmer rows for tables.
- **iOS first load**: `ProgressView` overlay; subsequent reloads show inline spinner only.

### Error handling

- **RPC failure**: per-tab toast + retry button. Other tabs continue working.
- **Lock-timeout / fail-fast policy**: each RPC sets `SET LOCAL statement_timeout = '10s'` at entry. If an aggregation exceeds it, the RPC returns an error and the tab shows a "Query timeout — try a smaller date range" message.
- **Filter apply fails**: data stays visible with banner "Filter konnte nicht angewendet werden".
- **Empty result**: existing `ContentUnavailableView` (iOS) / empty-state component (web).
- **Pre-migration date range**: Operations tab banner "Stockout-Daten verfügbar ab DD.MM.YYYY".
- **RPC `version` mismatch**: client surfaces "Update verfügbar — bitte App neu laden" banner.

### Caching

- **Web**: `useAnalyticsData` keeps 30-second in-memory cache keyed by `(tab, filterHash)`. Manual refresh and filter change bypass.
- **iOS**: `@StateObject` ViewModel persists across tab navigation within Analytics root; tab-switching does not re-fetch unless filter changed.

### Realtime hint banner

- **Overview tab only**: subscribes to Sale `INSERT` realtime events. On increment, sets `hasNewData = true`. Renders compact "🔄 Neue Daten verfügbar — aktualisieren" pill above the KPI grid. User-triggered refresh.

### RLS

- New `tray_stockout_events` uses standard `company_id = my_company_id()` RLS pattern.
- All six RPCs are `SECURITY DEFINER` and validate `p_company_id = my_company_id()` at entry as defense-in-depth.
- Both `admin` and `viewer` roles can read all analytics — revenue and conversion are business insights, not PII.

### Tests

- **Vitest (web, `management-frontend/app/composables/__tests__/`)**:
  - `useAnalyticsFilters`: URL/JSON serialization round-trip, preset save/load, filter merge with defaults, reset behavior
  - `useAnalyticsExport`: CSV column ordering, BOM for Excel, locale-aware decimal separator
  - `AnalyticsTable.spec.ts`: sorting and drill-through click handling
- **Deno tests** for each RPC, located **next to a representative consumer** following the existing project pattern (`Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts` is the precedent — tests live with their owner). Since no edge function owns these RPCs, place tests at `Docker/supabase/tests/analytics/`:
  - Each RPC: filter combinations including empty/null arrays, period-comparison correctness, RLS isolation between two seeded companies
  - `analytics_sales_breakdown` for each `p_dimension` value
  - `version: 1` field present in every response
- **SQL trigger tests** (Deno test file using `pg` client): `tray_stockout_events` trigger covers open → close → reopen sequence, the unique-partial-index prevents duplicate open events, lost_revenue math is correct given a known velocity.
- **iOS XCTest baseline**: `AnalyticsFilter` codable round-trip, preset persistence; smoke test for one ViewModel (`AnalyticsOverviewViewModel`).

### Export

- **CSV**, V1, all platforms. Per-tab table data:
  - **Encoding**: UTF-8 with BOM
  - **Delimiter**: `;` (German Excel default; English Excel users open via "Get Data → From Text/CSV" — acceptable for V1)
  - **Decimal separator**: locale-aware via `Intl.NumberFormat` (web) / `Locale.current` (iOS) — comma in de-DE, point in en-US
  - **Column headers**: translated via existing i18n (`analytics.columns.revenue`, etc.) — match the on-screen header
  - **Date format**: ISO 8601 `YYYY-MM-DD HH:mm:ss` (sortable, machine-readable, regardless of locale)
  - **Column order per tab**: matches the on-screen table left-to-right
  - **File name**: `vmflow-analytics-{tab}-{from}-{to}.csv`
- **PNG chart snapshot** — V1, web only. Library: `html-to-image`. Triggered from per-chart toolbar button. iOS PNG export deferred.

### i18n

- **Web**: new namespace `analytics.*` in `i18n/locales/de.json` and `en.json`. Reuse existing `formatCurrency` from `app/lib/utils.ts`. Tooltip strings ("Einkaufspreis fehlt …" — *no longer relevant since margin tracking is dropped*; replace with "Stockout-Daten verfügbar ab …" etc.) all live as i18n keys.
- **iOS**: extend `Localizable.xcstrings` with `analytics.*` keys. Use `.formatted(.currency(code: "EUR"))` for amounts, `.formatted(.percent)` for shares.
- Chart axis labels and tooltip values pass through translation; chart legends use `t()` / `String(localized:)`.

## Build Order

Phases 0 and 1 are strict prerequisites; Phases 2-5 contain parallelizable work. With margin tracking removed, Phase 0 is now small and low-risk.

### Phase 0 — Stockout Foundation (BLOCKING but small)

1. Migration 1: `tray_stockout_events` table, indexes, RLS, trigger, helper function `get_product_velocity_one`
2. Verification on dev DB: drive `current_stock` to 0 and back across a few trays, confirm event lifecycle, confirm unique-index prevents duplicate open events, confirm `lost_revenue_estimated` math is correct (`velocity × hours / 24 × sellprice`)

### Phase 1 — Backend RPCs

3. Migration 2: `_analytics_filtered_sales_subquery` shared helper + the six analytics RPCs + `version` field in every response
4. Deno tests per RPC + performance check on realistic sample data (50 machines × 90 days × ~10k sales)
5. Index audit: `EXPLAIN ANALYZE` each RPC with 90-day window; if any exceeds 500 ms, add covering indexes

### Phase 2 — Web Foundation (parallelizable with Phase 4)

6. Composables: `useAnalyticsFilters`, `useAnalyticsData`, `useAnalyticsExport`
7. Shared components: `AnalyticsFilterBar`, `AnalyticsTabNav`, `AnalyticsKpiGrid`, `AnalyticsChart`, `AnalyticsTable`, `AnalyticsCompareSheet`, `AnalyticsPresetMenu`
8. `/analytics/index.vue` skeleton with hash-based tab routing

### Phase 3 — Web Tabs (parallelizable after Phase 2)

9. Six tab components in priority order: Overview → Sales → Machines → Products → Conversion → Operations.

### Phase 4 — iOS Foundation (parallelizable with Phase 2)

10. `AnalyticsFilter` model with `Codable` + `@AppStorage` persistence (same JSON as web)
11. `AnalyticsRootView` with adaptive layout (compact tile menu, regular split view) + `SidebarItem.analytics` registration; confirm More-tab list growth is acceptable
12. Shared views: `AnalyticsKPIGroup`, `AnalyticsChart`, `AnalyticsSortableList`, `ComparePeriodBadge`, `AnalyticsHeatmap`
13. `AnalyticsFilterSheet` (bottom sheet on iPhone, inspector on iPad)

### Phase 5 — iOS Sections (parallelizable after Phase 4)

14. Six section views in same priority order as web

### Phase 6 — Polish & Release

15. i18n strings for all keys (Web `de.json` / `en.json`, iOS `Localizable.xcstrings`)
16. CSV export wiring + PNG chart snapshot (web)
17. Migrate AI insights from `/` dashboard to `TabOverview.vue` (and remove from dashboard)
18. Test suites complete: Vitest, Deno, SQL trigger tests, XCTest baseline
19. Update `CLAUDE.md` with new table, RPCs, migration order
20. Verification on real production-like data set (or staging)

### Critical-path summary

```
Phase 0 → Phase 1 → (Phase 2 in parallel with Phase 4) → (Phase 3 in parallel with Phase 5) → Phase 6
```

## Risks & Mitigations

- **Risk: stockout trigger collides with future triggers on `current_stock`**
  *Mitigation:* trigger named `zzz_tray_stockout_event` to sort last alphabetically. Future triggers should use `aaa_*`/`mmm_*` prefixes to control order. Document the convention in this trigger's migration file.

- **Risk: RPC performance on large datasets**
  *Mitigation:* shared `_analytics_filtered_sales_subquery` helper applies `WHERE` indexes early. Index audit at end of Phase 1 (verify `EXPLAIN ANALYZE` on each RPC with 90-day window stays under 500 ms). RPCs set `SET LOCAL statement_timeout = '10s'` so a runaway query fails fast rather than locking the request.

- **Risk: filter URL grows unwieldy with many machines selected**
  *Mitigation:* serialize filter as base64url-encoded JSON; if length exceeds 1500 chars, fall back to `?preset=xyz` referencing the named preset. Document the threshold in `useAnalyticsFilters`.

- **Risk: iOS Charts framework limitations on long horizontal series**
  *Mitigation:* use `.chartScrollableAxes(.horizontal)` + `.chartXVisibleDomain(length: 30 * 86400)` for any series longer than 30 days. Test on iPhone SE viewport size.

- **Risk: stockout duplicates from concurrent updates**
  *Mitigation:* unique partial index `idx_stockouts_one_open_per_tray (tray_id) WHERE ended_at IS NULL` rejects duplicate open events at the DB level. Trigger uses `ON CONFLICT DO NOTHING` for the open path.

- **Risk: stockout trigger silently breaks after a future migration changes `machine_trays.current_stock` semantics**
  *Mitigation:* SQL trigger test in Phase 0 step 2 covers open → close → manual stock edit → close, asserting `lost_units_estimated` is correctly computed. Re-runs in CI.

- **Risk: AI insights now covers a different period than the analytics filter, confusing users**
  *Mitigation:* in `TabOverview.vue`, render the AI block with its own header showing "Auswertung der letzten {company.velocity_days} Tage" so the period is explicit, distinct from the filter pill.

## Open Questions (Resolved during brainstorming)

- ✅ Architecture style: themed tabs with global filter bar (not pivot-canvas)
- ✅ V1 scope: revenue / units / conversion — **margin tracking deferred to V2**
- ✅ Web scope: all six tabs Big Bang
- ✅ iOS scope: all six sections Big Bang
- ✅ Filter persistence: `localStorage` / `@AppStorage` with shared JSON format
- ✅ Realtime: filter-change + pull-to-refresh + Overview "new data" pill (no auto-recompute)
- ✅ AI insights placement: migrate from `/` dashboard to `TabOverview.vue`
- ✅ iPhone geo map: out of scope V1
- ✅ Machine uptime %: out of scope V1 (no historical data source)

## Out of Scope (Future)

- **Margin / profit / cost-of-goods analytics** — would require `products.cost_price` + per-batch `unit_cost` tracking + a tray-level FIFO ledger. Significant migration risk on the sales hot path (the layered approach was reviewed and judged too costly for V1). Worth doing once the analytics surface itself is validated.
- **Machine uptime % and MTBF** — needs `embeddeds_status_history` table and firmware/server hooks to populate it.
- DB-synced filter presets across devices
- Per-user dashboard customization
- PDF report export
- iPhone geo map
- Cost-of-refill / labor-cost tracking
- Anomaly detection with push notifications
- Natural-language Q&A over analytics data
- Forecast/projection models beyond simple trend lines
- A/B price testing tracking
- Cohort analysis by month-of-installation
- Goal tracking
- 60-second auto-refresh polling
