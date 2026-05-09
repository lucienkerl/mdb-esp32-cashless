# Analytics Dashboard (Web + iOS Big Bang)

**Date:** 2026-05-09
**Status:** Draft

## Problem

The product has three surfaces that touch sales data today and none of them answer the question *"how is my fleet actually performing, and where do I lose or make money?"*:

- **`/` Dashboard** is a daily-pulse view: today/week/month KPIs, a 7-day chart, recent sales, top-5 products. Good for the morning glance, but it can't slice by category, channel, weekday or hour, and it cannot answer "which machine has been losing me money for two weeks?".
- **`/reports`** is a tax/accounting export tool — DATEV CSV, VAT breakdown. It does not visualize trends, does not compare periods, and does not surface anomalies. It is a deliverable for the tax advisor, not a decision tool.
- **`/machines/[id]`** has a 30-day chart per machine and AI insights, but only one machine at a time and no cross-machine comparison.

The operator needs a comprehensive analytics surface that lets them slice the entire dataset by any dimension, compare periods, find slow-movers and stockouts, and quantify lost revenue. They want a BI-tool feel — sortable tables, filtered charts, drill-throughs — without leaving the product.

A second motivation: profit. Today the system only tracks `sales.item_price` (gross EUR). Cost of goods is unknown, so the operator cannot tell whether a fast-moving product is actually profitable. Margin analysis must be unlocked at the same time, with batch-accurate cost tracking so that occasional discount procurement is reflected in real margin numbers, not a blended average.

## Goals

- **Comprehensive `/analytics` page on web**, six themed tabs (Overview, Sales, Products, Machines, Conversion, Operations) with a global filter bar that applies across all tabs.
- **Native iOS Analytics section** with the same six sections, adaptive layout: tile-menu on iPhone (under "More" tab), `NavigationSplitView` on iPad/Mac.
- **FIFO-accurate margin tracking**: every sale snapshots the actual unit cost from the originating warehouse batch via a tray-level layer ledger, so discount procurement directly improves reported margins.
- **Single source of truth for backend aggregations**: the same six SQL RPCs serve web and iOS — no duplicate aggregation logic.
- **Drill-throughs that respect the filter model**: clicking a numeric cell sets a global filter; clicking a name pushes to the existing detail page.
- **Filter persistence**: shareable URL on web, `@AppStorage` on iOS, named presets on both.
- **Backwards compatibility**: all changes are additive (new columns nullable, new tables additive, no in-place migration edits). Existing firmware, sales triggers, and frontend pages keep working unchanged.

## Non-Goals

- **No pivot/canvas-style ad-hoc chart builder.** The user explicitly chose themed tabs (Option B) over Tableau-style flexibility (Option A). The analytics page is curated, not a blank canvas.
- **No DB-backed shared filter presets.** V1 stores presets in `localStorage` (web) / `@AppStorage` (iOS). DB-sync of presets across devices is V2.
- **No per-user dashboard customization** (drag-and-drop widgets, custom KPIs). Layout is fixed.
- **No new edge functions.** All backend logic ships as Postgres RPCs callable directly from the supabase-js / supabase-swift clients.
- **No PDF export in V1** — CSV everywhere, PNG chart snapshot on web only. PDF is V2.
- **No 60-second auto-refresh polling.** Analytics queries are heavy aggregations; refresh is filter-change-triggered, pull-to-refresh, or explicit "new data available" toast (Overview tab only).
- **No cost-of-refill or labor-cost tracking** — refill efficiency is measured in units/tour and tour-duration, not €/hour. (Would require manual time entry which is out of scope.)
- **No iPhone geo-map in V1.** The lat/lng-based revenue map renders on web and iPad. iPhone gets a sortable list. Geo-map for iPhone is V2.
- **No batch-cost propagation through manual stock edits.** When an admin manually edits `machine_trays.current_stock`, the reconciliation trigger uses `products.cost_price` as the new layer cost — not a deeper inference from prior batches.
- **No real-time recompute on Sale INSERT.** Only Overview shows a "new data available" pill; user triggers refresh manually.

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
│   ├── AnalyticsTabNav.vue             # Horizontal tab switcher with badge counts
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
- **`/analytics` page replaces the sales-trend section of `/`**: the existing `companyInsights` AI module migrates to `TabOverview.vue` and is removed from the dashboard. Dashboard stays daily-pulse-focused.

### iOS (SwiftUI)

```
ios/VMflow/
├── Models/
│   └── AnalyticsFilter.swift                      # ObservableObject, persisted via @AppStorage
├── ViewModels/
│   ├── AnalyticsRootViewModel.swift               # Tab selection state, shared filter binding
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

- **`SidebarItem.analytics`** is added to `AppNavigation.swift` with icon `chart.xyaxis.line`. iPad/Mac shows it directly in `SidebarNavigationView`. iPhone surfaces it in `MoreView` (the tab bar is full at 5 tabs and stays unchanged).
- **`AnalyticsRootView` is adaptive**: reads `@Environment(\.horizontalSizeClass)`. On compact (iPhone), it is a `NavigationStack` with a tile-menu landing screen — six tiles in a 2-column grid, each pushes its `AnalyticsXxxView`. On regular (iPad/Mac), it is a `NavigationSplitView` with a section list on the left and the selected section's view on the right.
- **Filter model** is a single `@StateObject AnalyticsFilter` owned by `AnalyticsRootView` and passed down via `@EnvironmentObject` to every section. Changes propagate as Combine publishes; each section's ViewModel watches and reloads.
- **Filter persistence**: `AnalyticsFilter` writes its serialized state to `@AppStorage("analytics.filter.current")` after each change. Named presets live under `@AppStorage("analytics.filter.presets")` as a JSON array.
- **Realtime hookup**: `AnalyticsOverviewViewModel` subscribes to `RealtimeService.salesVersion`. On increment, it sets `hasNewData = true`, which the view renders as a small "Neue Daten — aktualisieren" pill above the KPIs. No automatic reload.

### Shared Backend

- **Six new Postgres RPCs** (see Data Model section). All use the same filter signature.
- **Two new tables**: `machine_tray_stock_layers`, `tray_stockout_events`.
- **Updated trigger**: `stamp_machine_and_decrement_stock` extends to consume FIFO layers and stamp `cost_price_snapshot`.
- **Updated RPC**: `deduct_warehouse_stock_fifo` writes layer rows in addition to incrementing `current_stock`.
- **No new edge functions.** All analytics calls are direct supabase-js / supabase-swift `.rpc(...)` invocations using the authenticated user's JWT — RLS enforced via `my_company_id()` inside each RPC.

## Data Model

### Migration 1 — Cost Tracking & FIFO Layers

File: `Docker/supabase/migrations/YYYYMMDDHHMMSS_analytics_cost_tracking.sql`

**New columns (all nullable, additive):**
```
ALTER products              ADD COLUMN cost_price          float8;  -- EUR per unit, current default cost
ALTER warehouse_stock_batches ADD COLUMN unit_cost         float8;  -- EUR per unit at batch intake
ALTER sales                 ADD COLUMN cost_price_snapshot float8;  -- stamped by trigger on INSERT
```

**New table — tray-level FIFO cost layers:**
```
CREATE TABLE machine_tray_stock_layers (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  tray_id             uuid NOT NULL REFERENCES machine_trays(id) ON DELETE CASCADE,
  machine_id          uuid NOT NULL,                 -- denormalized for trigger lookup speed
  item_number         int  NOT NULL,                 -- denormalized
  product_id          uuid REFERENCES products(id) ON DELETE SET NULL,
  quantity_remaining  int  NOT NULL CHECK (quantity_remaining >= 0),
  unit_cost           float8,                        -- nullable (legacy + manual layers)
  source_batch_id     uuid REFERENCES warehouse_stock_batches(id) ON DELETE SET NULL,
  refilled_at         timestamptz NOT NULL DEFAULT now(),  -- FIFO ordering key
  company_id          uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE
);
CREATE INDEX idx_layers_active ON machine_tray_stock_layers (machine_id, item_number, refilled_at)
  WHERE quantity_remaining > 0;
ALTER TABLE machine_tray_stock_layers ENABLE ROW LEVEL SECURITY;
-- RLS: select / insert / update / delete WHERE company_id = my_company_id()
```

**Updated trigger `stamp_machine_and_decrement_stock`** (via `CREATE OR REPLACE FUNCTION`, gleicher Funktionsname):

In addition to the existing logic (stamp `machine_id` from device, decrement `machine_trays.current_stock`, stamp `tax_rate_snapshot`):

1. Find oldest layer for `(NEW.machine_id, NEW.item_number)` with `quantity_remaining > 0`:
   `SELECT id, unit_cost FROM machine_tray_stock_layers WHERE machine_id = NEW.machine_id AND item_number = NEW.item_number AND quantity_remaining > 0 ORDER BY refilled_at ASC LIMIT 1 FOR UPDATE`
2. If found: `UPDATE ... SET quantity_remaining = quantity_remaining - 1`. `NEW.cost_price_snapshot := layer.unit_cost`.
3. If not found OR `layer.unit_cost IS NULL`: fall back to `NEW.cost_price_snapshot := (SELECT cost_price FROM products WHERE id = NEW.product_id)`. Sale still completes — analytics flags as "estimated".

**New trigger — manual stock edit reconciliation:**

A session-local variable distinguishes refill/sale decrements from manual UI edits:
- The refill RPC and the sales trigger both `SET LOCAL vmflow.skip_reconcile = 'true'` before touching `machine_trays.current_stock`.
- The reconciliation trigger fires `AFTER UPDATE OF current_stock ON machine_trays` and skips if `current_setting('vmflow.skip_reconcile', true) = 'true'`.
- On a real manual edit:
  - If `NEW.current_stock > OLD.current_stock` → INSERT new "manual" layer with `quantity_remaining = diff`, `unit_cost = products.cost_price`, `source_batch_id = NULL`.
  - If `NEW.current_stock < OLD.current_stock` → decrement layers FIFO (oldest first) until `diff` is consumed.

**Tray product change:** when `machine_trays.product_id` changes, all open layers for that tray are closed (`quantity_remaining := 0`). New layers begin with the next refill.

**Initial seed (in same migration, runs once):**
```
INSERT INTO machine_tray_stock_layers (tray_id, machine_id, item_number, product_id,
                                       quantity_remaining, unit_cost, source_batch_id,
                                       refilled_at, company_id)
SELECT mt.id, mt.machine_id, mt.item_number, mt.product_id,
       mt.current_stock, p.cost_price, NULL,
       now(), v.company_id
FROM machine_trays mt
JOIN vendingMachine v ON v.id = mt.machine_id
LEFT JOIN products p ON p.id = mt.product_id
WHERE mt.current_stock > 0;
```
Trays with `cost_price IS NULL` get a layer with NULL cost — analytics shows "—" for profit on those sales until the next real refill.

**Updated `deduct_warehouse_stock_fifo` RPC:**

Existing behavior: deducts from `warehouse_stock_batches` FIFO (oldest expiration first, falling back to oldest creation), increments `machine_trays.current_stock`. New behavior: for *each* batch consumed during a single refill, additionally INSERT one row in `machine_tray_stock_layers` with that batch's `unit_cost` and `source_batch_id`. If a refill consumes 50 from batch X and 30 from batch Y, two layer rows result.

### Migration 2 — Stockout Events

File: `Docker/supabase/migrations/YYYYMMDDHHMMSS_analytics_stockouts.sql`

```
CREATE TABLE tray_stockout_events (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tray_id                uuid NOT NULL REFERENCES machine_trays(id) ON DELETE CASCADE,
  machine_id             uuid NOT NULL,
  item_number            int  NOT NULL,
  product_id             uuid REFERENCES products(id) ON DELETE SET NULL,
  started_at             timestamptz NOT NULL,
  ended_at               timestamptz,                -- NULL = ongoing
  duration_seconds       int GENERATED ALWAYS AS (EXTRACT(EPOCH FROM (ended_at - started_at))::int) STORED,
  lost_units_estimated   numeric,                    -- computed at close time
  velocity_at_close      numeric,                    -- velocity used in estimate (audit trail)
  company_id             uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE
);
CREATE INDEX idx_stockouts_open ON tray_stockout_events (machine_id, tray_id) WHERE ended_at IS NULL;
CREATE INDEX idx_stockouts_company_started ON tray_stockout_events (company_id, started_at DESC);
-- RLS: my_company_id()-scoped
```

Trigger on `machine_trays AFTER UPDATE OF current_stock`:
- If `OLD.current_stock > 0 AND NEW.current_stock = 0`: INSERT new event with `started_at = now()`, `ended_at = NULL`.
- If `OLD.current_stock = 0 AND NEW.current_stock > 0`: UPDATE most recent open event for this tray, set `ended_at = now()`, compute `lost_units_estimated = velocity × duration_hours / 24`, store `velocity_at_close` from `get_product_sales_velocity` (single-product call).

Trigger only fires post-migration; pre-migration stockouts are unrecoverable. Operations tab shows a banner when filter range extends before migration date.

### Migration 3 — Six Analytics RPCs

File: `Docker/supabase/migrations/YYYYMMDDHHMMSS_analytics_rpcs.sql`

**Shared filter signature** (all six RPCs):
```
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
)
```

All RPCs are `SECURITY DEFINER`, validate `p_company_id = my_company_id()` at entry, and return `jsonb` (single row, multiple sections). Internal helper `_analytics_filtered_sales(filters jsonb)` builds the shared `WHERE` block once.

| RPC | Returns |
|-----|---------|
| `analytics_overview` | `{kpis: {revenue, units, avg_basket, profit, margin_pct, conversion_pct}, kpis_compare: {...}, daily_series: [{date, revenue, profit}], top_products: [...], top_machines: [...]}` |
| `analytics_sales_breakdown(p_dimension text)` | `{rows: [{key, label, revenue, units, avg, profit, margin_pct, count, share_pct}], dimension}` — `p_dimension ∈ {'machine','product','category','channel','vat','hour','dow'}` |
| `analytics_products` | `{kpis, products: [{id, name, image_path, category_id, velocity, units, revenue, profit, margin_avg, margin_spread, mix_pct, vat_rate, status, slow_mover_days}], mix_shift_series: [...]}` — `status ∈ {'active','slow','dead','discontinued'}` |
| `analytics_machines` | `{kpis, machines: [{id, name, lat, lng, status, revenue, units, conversion_pct, uptime_pct, last_sale_gap_minutes, stock_health, profit, dow_heatmap, hour_heatmap}]}` |
| `analytics_conversion` | `{kpis, machines: [{id, name, pax, sales, conversion_pct, revenue_per_visitor, traffic_score, revenue_score}], hour_heatmap, daily_conversion_series}` |
| `analytics_operations` | `{kpis, stockout_events: [{...}], refill_tours: [{tour_id, started_at, duration_minutes, units, machines, value_eur}], uptime: [{machine_id, name, offline_pct, longest_offline_minutes}], stock_cover: [{tray_id, machine_id, product_id, current_stock, daily_velocity, cover_days}]}` |

`get_product_sales_velocity(p_company_id, p_days)` is reused by `analytics_products` and `analytics_operations`. No duplicate aggregation.

### UI for Cost Entry (ships with Migration 1)

Without entry UI the new columns stay empty and analytics shows "—" everywhere. Therefore in the same release:

- **Web `ProductFormModal.vue`** — add `cost_price` numeric input next to `sellprice`, label "Einkaufspreis (€)", optional, hint "Wird als Standard für neue Wareneingänge verwendet"
- **Web Warehouse intake** (`useWarehouse.ts` + relevant component) — `unit_cost` field with `products.cost_price` prefill on product select, editable, hint "Bei Aktionspreis hier abweichenden Wert eintragen"
- **iOS `ProductEditSheet.swift`** — equivalent Decimal field with `.keyboardType(.decimalPad)`
- **iOS Warehouse intake** — equivalent prefill + override field

### Backwards Compatibility

- All new columns nullable. Existing firmware sales arrive with `cost_price = NULL` on the product → trigger writes `cost_price_snapshot = NULL` → analytics renders "—" for profit but counts the sale in revenue/units.
- Existing `tax_rate_snapshot` logic untouched.
- Pre-migration sales have `cost_price_snapshot = NULL` permanently (no backfill — historical FIFO state is unrecoverable). Profit aggregations explicitly exclude NULL rows from margin calc and label as "Profit available for X of Y sales".
- Stockout events table is empty pre-migration; Operations tab banner: "Stockout-Daten verfügbar ab DD.MM.YYYY".
- New tables and triggers do not affect any existing read or write path beyond the documented additions.

## Tab Contents

Global filter bar (always visible at top, sticky on scroll): date range with presets (Today / 7d / 30d / 90d / YTD / 12M / Custom) + period-comparison toggle, machines multi-select, channel toggles (cashless / cash / card), categories multi-select, VAT-rates multi-select. Reset button + "Save as preset" button. URL query sync (web). Filter panel collapses to a "Filters · 3 active" pill on small screens.

### Tab 1 — Overview

- **KPI cards (4)**: Revenue · Units · Profit (€ + margin %) · Conversion %
  Each shows current period absolute value + period-comparison delta badge (`+12%` green / `-8%` red, with arrow icon).
- **Main chart**: daily-revenue line over selected period, with profit as second y-axis. Period-comparison overlay (dotted) toggled via filter bar. Scrubbable on iOS via `chartXSelection`.
- **Top 5 Products** compact table (image, name, units, revenue, profit). Click name → push to product detail. Click numeric cell → set product filter, switch to Sales tab.
- **Top 5 Machines** compact table (name, status badge, revenue, conversion %). Click name → push to machine detail. Click numeric cell → set machine filter.
- **AI Insights module** — the existing `companyInsights` UI moves here verbatim. Dashboard `/` no longer renders it.

### Tab 2 — Sales (Breakdown Workbench)

- **KPI cards (4)**: Revenue · Units · Avg basket · Profit
- **Dimension switcher** — picker: Machine / Product / Category / Channel / VAT rate / Hour / Day-of-week
- **Visualization**: bar chart by dimension value (toggle metric: revenue / units / profit / margin %). For Hour or Day-of-week dimension, render as heatmap (weekday × hour) instead of bar.
- **Sortable table** below: all dimension values, columns revenue / units / avg / profit / margin % / share %. Click row → set corresponding filter (e.g. "Machine X"), stay on tab — other tabs respect the filter on next visit.
- **Drill cell** (number) sets filter; **drill name** pushes to detail.

### Tab 3 — Products

- **KPI cards (4)**: Active · Slow-movers (no sale 30 d) · Discontinued · Avg margin (revenue-weighted)
- **Product list**: image + name. Columns: Velocity (units/day) · Units · Revenue · Profit · **Margin avg (FIFO-weighted)** · **Margin spread** (max minus min batch cost in window — exposes discount procurement wins) · Mix % · VAT · Status badge (active / slow / dead / discontinued)
- **Sub-filters**: category, status toggle, "only slow-movers"
- **Search** by name (web `<input>`, iOS `.searchable`)
- **Mix-shift chart**: stacked-area over time, category share of revenue
- **Drill**: row name/image → existing `ProductDetailSheet` (iOS) or `/products/[id]` (web)

### Tab 4 — Machines

- **KPI cards (4)**: Active · Best (revenue) · Avg uptime % · Avg conversion %
- **Machine table/cards**: name, status badge, revenue, units, conversion %, uptime %, last-sale-gap, stock-health bar (existing component), profit
- **Heatmap toggle**: weekday × hour per machine — shows when each machine performs
- **Compare button**: multiselect up to 4 machines → opens `AnalyticsCompareSheet` with side-by-side mini-charts (revenue trend, conversion trend, top-3 products per machine). On iPhone presented as stepwise sheet (machine 1 → machine 2 → diff view).
- **Geo map** (web + iPad only): bubbles from `sales.lat/lng`, size = revenue, color = conversion percentile
- **Drill**: machine name → existing `MachineDetailView` / `/machines/[id]`

### Tab 5 — Conversion (Pax × Sales — the unique-here surface)

- **KPI cards (4)**: Footfall · Conversion % · Best converting machine · Empty passes (visitors − sales)
- **Heatmap**: machines × hour, color = conversion % — exposes peak-hours and underperformers visually
- **Scatter**: x = traffic, y = revenue, each point a machine. Diagonal reference at fleet-average conversion. Outliers below the line = underutilized footfall. Click point → pushes to machine detail.
- **Daily conversion trend**: line chart of fleet-wide conversion %, with Δ vs comparison period
- **Per-machine table**: pax · sales · conversion % · revenue per visitor

### Tab 6 — Operations

- **KPI cards (4)**: Stockout hours · Lost sales (€) · Refill tours · Avg stock cover days
- **Stockout events list** from `tray_stockout_events`: machine · tray · product · started_at · duration · estimated lost €. Sortable by lost €. Click → opens machine-detail with the tray pre-focused.
- **Refill efficiency** from `tour_history` (existing): per-tour duration, units refilled, machines visited, total value. Compute units-per-minute as efficiency proxy.
- **Uptime table** from `embeddeds.status` history + `mdb_log`: per machine, offline %, longest offline period, MTBF estimate.
- **Stock-cover-days** per tray (current_stock / daily_velocity), sorted ascending. Trays under 3 days highlighted red. Click → opens Refill wizard with that machine pre-selected.

### Drill-Through Convention (applies everywhere)

| Click target | Behavior |
|--------------|----------|
| Numeric cell (revenue, profit, conversion, etc.) | Sets the corresponding global filter, stays on current tab |
| Name or image (product, machine, category) | Pushes to the existing detail page/sheet |
| "Compare" buttons | Opens `AnalyticsCompareSheet`, no tab change |

iOS uses `NavigationLink` for pushes and `.onTapGesture` for filter-set actions. Web uses `<NuxtLink>` for pushes and click-handlers for filter updates.

### iOS-Specific Tab Adaptations

- **Overview**: KPI grid 2×2 on iPhone / 1×4 on iPad. Main chart full-width, scrollable on iPhone via `chartScrollableAxes(.horizontal)`.
- **Sales**: dimension switcher as scrollable tag-pills (`ScrollView(.horizontal)`) — segmented control caps at ~5 items.
- **Products**: `.searchable` searchbar, `List` with thumbnails, sub-filters via toolbar `Menu`.
- **Machines**: existing `MachineCard` list. Compare on iPhone is stepwise (pick machine A → pick machine B → diff view); on iPad multi-select inline. Geo map only on iPad.
- **Conversion**: full heatmap only on iPad. iPhone reduces to a list with conversion bars per row.
- **Operations**: list of stockouts with `.swipeActions` ("Plan tour", "Mark resolved"). Refill tours collapsible per day.

## Filter System & Cross-Cutting

### Filter persistence

- **Web**: filter state lives in `useState('analytics-filters')`; on change, debounced (300 ms) URL replace via `useRouter().replace({ query: serialized })`. On mount, hydrates from `route.query`. Named presets stored in `localStorage` under key `analytics.presets` as JSON array `[{name, filters}]`. Default preset on first visit: "Letzte 30 Tage, alle Maschinen".
- **iOS**: `AnalyticsFilter` is an `ObservableObject` with `@Published` properties. Each change writes `JSONEncoder().encode(self)` to `@AppStorage("analytics.filter.current")`. Named presets at `@AppStorage("analytics.filter.presets")`.

### Drill-through state propagation

When a click sets a filter on tab A and the user later opens tab B, the filter is already applied — every tab's ViewModel/composable reads the same shared filter state.

### Loading states

- **Filter change**: existing data fades to 60% opacity, inline spinner appears next to filter bar, debounced 300 ms, then re-fetch and fade back to 100%.
- **Initial tab load**: skeleton boxes for charts, shimmer rows for tables.
- **iOS first load**: `ProgressView` overlay; subsequent reloads show inline spinner only.

### Error handling

- **RPC failure**: per-tab toast + retry button. Other tabs continue working.
- **Filter apply fails**: data stays visible with banner "Filter konnte nicht angewendet werden".
- **Cost data missing for many products**: tooltip on profit columns "Einkaufspreis für N Produkte nicht gepflegt" with deeplink to Products tab.
- **Pre-migration sales**: profit shown as italic "geschätzt" (estimated) with info icon.
- **Empty result**: existing `ContentUnavailableView` (iOS) / empty-state component (web).

### Caching

- **Web**: `useAnalyticsData` keeps 30-second in-memory cache keyed by `(tab, filterHash)`. Manual refresh and filter change bypass.
- **iOS**: `@StateObject` ViewModel persists across tab navigation within Analytics root; tab-switching does not re-fetch unless filter changed.

### Realtime hint banner

- **Overview tab only**: subscribes to Sale `INSERT` realtime events. On increment, sets `hasNewData = true`. Renders compact "🔄 Neue Daten verfügbar — aktualisieren" pill above the KPI grid. User-triggered refresh; no automatic recompute.

### RLS

All new tables (`machine_tray_stock_layers`, `tray_stockout_events`) use the standard `company_id = my_company_id()` RLS pattern. All six RPCs are `SECURITY DEFINER` and validate `p_company_id = my_company_id()` at entry as defense-in-depth. Both `admin` and `viewer` roles can read all analytics — profit/margin are business insights, not PII.

### Tests

- **Vitest (web)**:
  - `useAnalyticsFilters`: URL sync round-trip, preset save/load, filter merge with defaults, reset behavior
  - `useAnalyticsExport`: CSV column ordering, BOM for Excel, locale-aware decimal separator
  - Component tests for `AnalyticsTable` sorting and drill-through click handling
- **Deno tests (`Docker/supabase/functions/_shared/__tests__/analytics-rpcs.test.ts`)** — pattern mirrors `mqtt-webhook` tests:
  - Each RPC: filter combinations including empty/null arrays, period-comparison correctness, NULL `cost_price_snapshot` handling, RLS isolation between two seeded companies
  - `analytics_sales_breakdown` for each `p_dimension` value
- **SQL trigger tests** (pgTAP-style or plain SQL assertions in a Deno test file): layer FIFO consistency after refill → sale → manual edit → product change sequences. Critical because the sales trigger is on the hot path.
- **iOS XCTest baseline**: `AnalyticsFilter` codable round-trip, preset persistence; smoke tests for one ViewModel (`AnalyticsOverviewViewModel`).

### Export

- **CSV** for every tab's primary table — V1, all platforms. UTF-8 with BOM for Excel compatibility, `;` delimiter for German locale, locale-aware number formatting via `Intl.NumberFormat`.
- **PNG chart snapshot** — V1, web only. Library: `html-to-image`. Triggered from per-chart toolbar button.
- **PDF report** — V2.

### i18n

- **Web**: new namespace `analytics.*` in `i18n/locales/de.json` and `en.json`. Reuse existing `formatCurrency` from `app/lib/utils.ts`.
- **iOS**: extend `Localizable.xcstrings` with `analytics.*` keys. Use `.formatted(.currency(code: "EUR"))` for amounts, `.formatted(.percent)` for margins.
- Chart axis labels and tooltip values pass through translation; chart legends use `t()` / `String(localized:)`.

## Build Order

Even with the Big Bang choice, internal dependencies dictate sequencing. Phases 0 and 1 are strict prerequisites; Phases 2-5 contain parallelizable work.

### Phase 0 — Data Foundation (BLOCKING)

1. Migration 1: cost_price columns + `machine_tray_stock_layers` table + indexes + RLS
2. Migration 1b: `stamp_machine_and_decrement_stock` trigger update + manual-edit reconciliation trigger + initial-seed query for existing tray stock
3. Migration 2: `tray_stockout_events` table + trigger
4. UI cost-entry fields: `cost_price` in `ProductFormModal.vue` (web) and `ProductEditSheet.swift` (iOS); `unit_cost` in warehouse intake flows on both platforms
5. `deduct_warehouse_stock_fifo` RPC update: writes layer rows per consumed batch
6. Verification on dev DB: manual refill → manual sale → assert layer consistency, snapshot correctness, fallback path

### Phase 1 — Backend RPCs

7. Migration 3: `_analytics_filtered_sales` shared helper + the six analytics RPCs
8. Deno tests per RPC + performance check on realistic sample data (50 machines × 90 days × ~10k sales)

### Phase 2 — Web Foundation (parallelizable with Phase 4)

9. Composables: `useAnalyticsFilters`, `useAnalyticsData`, `useAnalyticsExport`
10. Shared components: `AnalyticsFilterBar`, `AnalyticsTabNav`, `AnalyticsKpiGrid`, `AnalyticsChart`, `AnalyticsTable`, `AnalyticsCompareSheet`, `AnalyticsPresetMenu`
11. `/analytics/index.vue` skeleton with hash-based tab routing

### Phase 3 — Web Tabs (parallelizable after Phase 2)

12. Six tab components in priority order: Overview → Sales → Machines → Products → Conversion → Operations.
    Priority reflects user value: Overview answers the most-asked questions; Operations is the most data-dependent (needs stockout history to accumulate).

### Phase 4 — iOS Foundation (parallelizable with Phase 2)

13. `AnalyticsFilter` model with `Codable` + `@AppStorage` persistence
14. `AnalyticsRootView` with adaptive layout (compact tile menu, regular split view) + `SidebarItem.analytics` registration
15. Shared views: `AnalyticsKPIGroup`, `AnalyticsChart`, `AnalyticsSortableList`, `ComparePeriodBadge`, `AnalyticsHeatmap`
16. `AnalyticsFilterSheet` (bottom sheet on iPhone, inspector on iPad)

### Phase 5 — iOS Sections (parallelizable after Phase 4)

17. Six section views in same priority order as web

### Phase 6 — Polish & Release

18. i18n strings for all keys (Web `de.json` / `en.json`, iOS `Localizable.xcstrings`)
19. CSV export wiring + PNG chart snapshot (web)
20. Migrate AI insights from `/` dashboard to `TabOverview.vue` (and remove from dashboard)
21. Test suites complete: Vitest, Deno, SQL trigger tests, XCTest baseline
22. Update `CLAUDE.md` with new tables, RPCs, migration order
23. Verification on real production-like data set (or staging)

### Critical-path summary

```
Phase 0 → Phase 1 → (Phase 2 ‖ Phase 4) → (Phase 3 ‖ Phase 5) → Phase 6
```

## Risks & Mitigations

- **Risk: sales trigger regression destabilizes a live, hot path**
  *Mitigation:* trigger update ships as `CREATE OR REPLACE FUNCTION` in a dedicated migration that runs idempotently. Pre-deployment dev DB rehearsal is mandatory (Phase 0 step 6). Fallback path (`products.cost_price` when no layer) ensures sales never block on missing layer data.

- **Risk: `current_stock` and layer-sum drift due to a manual edit path we missed**
  *Mitigation:* the reconciliation trigger fires on every `UPDATE OF current_stock`. Ad-hoc audit query in CLAUDE.md ops notes: `SELECT tray_id, current_stock, SUM(quantity_remaining) FROM machine_trays JOIN layers GROUP BY 1,2 HAVING current_stock != SUM(quantity_remaining)`. Sales fall back to `products.cost_price` if drift exists, so margin still reports something.

- **Risk: RPC performance on large datasets**
  *Mitigation:* shared `_analytics_filtered_sales` helper applies `WHERE` indexes early. Index audit at end of Phase 1 (verify `EXPLAIN ANALYZE` on each RPC with 90-day window stays under 500 ms). If borderline, add a materialized view for the daily series and refresh on a cron.

- **Risk: existing firmware writes sales without `product_id` reaching the trigger**
  *Mitigation:* the existing trigger already infers `product_id` via `(machine_id, item_number) → machine_trays.product_id` join. Layer lookup uses the same `(machine_id, item_number)` keys, so no firmware-side change required.

- **Risk: filter URL grows unwieldy with many machines selected**
  *Mitigation:* serialize machine IDs as compact comma-separated UUIDs; if length exceeds 1500 chars, fall back to `?preset=xyz` referencing the named preset.

- **Risk: iOS Charts framework limitations on long horizontal series**
  *Mitigation:* use `.chartScrollableAxes(.horizontal)` + `.chartXVisibleDomain(length: 30 days)` for any series longer than 30 days. Test on iPhone SE viewport size.

- **Risk: cost-data debt — operator never enters `cost_price`, analytics shows "—" everywhere**
  *Mitigation:* Phase 0 ships UI fields, but they are optional. Add a one-time onboarding nudge on first visit to `/analytics`: "Pflege Einkaufspreise für genauere Analytik" with a link to Products bulk-edit. Soft enforcement only.

## Open Questions (Resolved during brainstorming)

- ✅ Architecture style: themed tabs with global filter bar (not pivot-canvas)
- ✅ Cost data approach: `products.cost_price` default + per-batch `unit_cost` override + `sales.cost_price_snapshot` via FIFO layers
- ✅ Cost flow into sale margins: batch-accurate via tray-level FIFO layers (not just `products.cost_price` snapshot)
- ✅ Web scope: all six tabs Big Bang
- ✅ iOS scope: all six sections Big Bang
- ✅ Filter persistence: `localStorage` / `@AppStorage` (no DB sync in V1)
- ✅ Realtime: filter-change + pull-to-refresh + Overview "new data" pill (no auto-recompute)
- ✅ Manual stock edit reconciliation: auto-create layer with `products.cost_price` (no modal popup)
- ✅ AI insights placement: migrate from `/` dashboard to `TabOverview.vue`
- ✅ iPhone geo map: out of scope V1

## Out of Scope (Future)

- DB-synced filter presets across devices
- Per-user dashboard customization
- PDF report export
- iPhone geo map
- Cost-of-refill / labor-cost tracking
- Anomaly detection with push notifications
- Natural-language Q&A over analytics data (extend AI insights)
- Forecast/projection models beyond simple trend lines
- A/B price testing tracking
- Cohort analysis by month-of-installation
- Goal tracking (set monthly targets, track progress)
- 60-second auto-refresh polling
