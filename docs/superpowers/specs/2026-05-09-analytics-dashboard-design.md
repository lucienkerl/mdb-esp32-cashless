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
- **Native iOS Analytics section** with the same six sections, adaptive layout: single screen with section picker on iPhone (under "More" tab), `NavigationSplitView` on iPad/Mac.
- **Single source of truth for backend aggregations**: the same six SQL RPCs serve web and iOS — no duplicate aggregation logic.
- **Drill-throughs that respect the filter model**: clicking a numeric cell sets a global filter; clicking a name pushes to the existing detail page.
- **Filter persistence**: shareable URL on web, `@AppStorage` on iOS, named presets on both, identical serialization format on both platforms.
- **Stockout history** so the operator can quantify lost revenue per tray and find chronic-empty trays (new `tray_stockout_events` table + trigger).
- **Backwards compatibility**: all changes are additive (new table, new RPCs, new triggers — no edits to existing migration files, no schema changes that affect firmware or existing UIs).

## Non-Goals

- **No margin / profit / cost-of-goods tracking in V1.** Revenue, units, conversion, lost-revenue-estimate are computed from `sales.item_price` and `paxcounter.count`. Margin tracking is captured in "Out of Scope".
- **No pivot/canvas-style ad-hoc chart builder.** Tabs are curated.
- **No DB-backed shared filter presets.** V1 stores presets in `localStorage` (web) / `@AppStorage` (iOS).
- **No per-user dashboard customization.**
- **No new edge functions.** Backend logic ships as Postgres RPCs.
- **No PDF export in V1** — CSV everywhere, PNG chart snapshot on web only.
- **No 60-second auto-refresh polling.**
- **No iPhone geo-map in V1.**
- **No real-time recompute on Sale INSERT** — Overview shows a "new data available" pill only.
- **No machine uptime % or MTBF in V1.** Uptime *could* be computed from `embeddeds.last_seen` plus an MQTT history we'd have to aggregate, but doing it precisely requires non-trivial work outside this spec's scope.

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
│   ├── AnalyticsChart.vue              # Wraps existing ChartAreaInteractive
│   ├── AnalyticsTable.vue              # Sortable, drill-throughable, exportable; reuses SortHeader.vue
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
- **Filter state**: `useAnalyticsFilters` composable, backed by `useState('analytics-filters')` (SSR-safe). On client mount, syncs from URL query params. On filter change, debounced URL replace + RPC re-fetch.
- **Per-tab fetch only** — switching tabs lazily fetches; results cached for 30 s keyed on serialized filter state.

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
    ├── AnalyticsRootView.swift                    # iPhone: section Picker + content; iPad: NavigationSplitView
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

- **`SidebarItem.analytics`** added to `AppNavigation.swift` with icon `chart.xyaxis.line`. iPad/Mac shows it directly in the sidebar. iPhone surfaces it under the existing "More" tab — `MoreView` (currently 5 entries: cashBook, products, warehouse, deals, settings) gains a sixth `NavigationLink` for analytics. Same pattern as cashbook took.
- **iPhone UX**: tapping "Analytics" in More opens directly into the Overview section. A horizontal scrolling pill-picker at the top of `AnalyticsRootView` switches between the six sections in-place — no separate tile-menu screen, matches the cashbook precedent of "two taps to content".
- **iPad/Mac**: `AnalyticsRootView` is a `NavigationSplitView` with the six section names as a sidebar list and the selected section's view in the detail column.
- **Filter ownership**: `AnalyticsFilter` is an `ObservableObject` with `@Published` properties. Owned as `@StateObject` by `AnalyticsRootView`, injected to every section via `.environmentObject(...)`. Each section's ViewModel observes `objectWillChange` and triggers a debounced reload (300 ms). `@AppStorage("analytics.filter.current")` persists the JSON-encoded current filter; named presets live at `@AppStorage("analytics.filter.presets")` as a JSON array.
- **Realtime hookup**: `AnalyticsOverviewViewModel` subscribes to `RealtimeService.salesVersion` (already company-wide). On increment, sets `hasNewData = true`, view renders a "Neue Daten — aktualisieren" pill above the KPIs. No automatic reload.
- **Minimum iOS deployment target** stays at the project's existing baseline (read from `ios/VMflow.xcodeproj` build settings before implementation; current SF Symbol `chart.xyaxis.line` requires iOS 16+, current `Charts` API features used here require iOS 17+).

### Shared Backend

- **Six new Postgres RPCs** (see Data Model section). All use the same filter signature.
- **One new table**: `tray_stockout_events`.
- **No changes to existing triggers, RPCs, or schemas.** The sales `BEFORE INSERT` trigger is untouched. Refill flows are untouched. (The codebase had a costly outage on 2026-04-11 from a sales-trigger regression — this spec deliberately steers clear.)
- All RPCs are direct `.rpc(...)` calls from supabase-js / supabase-swift using the authenticated user's JWT — RLS enforced via `my_company_id()` inside each RPC.

## Data Model

### Migration 1 — Stockout Events

File: `Docker/supabase/migrations/YYYYMMDDHHMMSS_analytics_stockout_events.sql`

```sql
CREATE TABLE public.tray_stockout_events (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tray_id                uuid NOT NULL REFERENCES public.machine_trays(id) ON DELETE CASCADE,
  machine_id             uuid NOT NULL REFERENCES public."vendingMachine"(id) ON DELETE CASCADE,
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
```

**RLS — trigger-managed audit log.** User code never INSERTs/UPDATEs/DELETEs this table; the trigger fires from `SECURITY DEFINER` context and bypasses RLS for its own writes. User-facing access is **SELECT-only**:
```sql
CREATE POLICY tray_stockout_events_select ON public.tray_stockout_events
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());
GRANT SELECT ON public.tray_stockout_events TO authenticated;
GRANT ALL    ON public.tray_stockout_events TO service_role;
-- No INSERT/UPDATE/DELETE policy for authenticated → silently denied.
```

**Trigger:** `AFTER UPDATE OF current_stock ON public.machine_trays`, named `zzz_tray_stockout_event` so it sorts after any other future trigger on the same column. Function `public.handle_tray_stockout_event()` is `SECURITY DEFINER`, `SET search_path = ''` (per project convention).

```sql
CREATE OR REPLACE FUNCTION public.handle_tray_stockout_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_company_id    uuid;
  v_velocity      numeric;
  v_sellprice     numeric;
  v_duration_h    numeric;
  v_short_close   bool;
BEGIN
  -- machine_trays has no company_id column; resolve via machine.
  SELECT vm.company INTO v_company_id
  FROM public."vendingMachine" vm WHERE vm.id = NEW.machine_id;
  IF v_company_id IS NULL THEN RETURN NEW; END IF;

  -- Open: stock crossed positive → 0
  IF OLD.current_stock > 0 AND NEW.current_stock = 0 THEN
    INSERT INTO public.tray_stockout_events
      (tray_id, machine_id, item_number, product_id, started_at, company_id)
    VALUES
      (NEW.id, NEW.machine_id, NEW.item_number, NEW.product_id, now(), v_company_id)
    ON CONFLICT DO NOTHING;  -- partial unique index handles concurrent opens
    RETURN NEW;
  END IF;

  -- Close: stock crossed 0 → positive
  IF OLD.current_stock = 0 AND NEW.current_stock > 0 THEN
    SELECT public.get_product_velocity_one(v_company_id, NEW.product_id, 30)
      INTO v_velocity;
    SELECT sellprice INTO v_sellprice FROM public.products WHERE id = NEW.product_id;

    UPDATE public.tray_stockout_events
    SET ended_at              = now(),
        velocity_at_close     = v_velocity,
        lost_units_estimated  = CASE
          WHEN EXTRACT(EPOCH FROM (now() - started_at)) < 300 THEN 0  -- < 5 min: ignore noise
          ELSE ROUND(COALESCE(v_velocity, 0) * EXTRACT(EPOCH FROM (now() - started_at)) / 86400.0, 2)
        END,
        lost_revenue_estimated = CASE
          WHEN EXTRACT(EPOCH FROM (now() - started_at)) < 300 THEN 0
          ELSE ROUND(COALESCE(v_velocity, 0) * EXTRACT(EPOCH FROM (now() - started_at)) / 86400.0
                     * COALESCE(v_sellprice, 0), 2)
        END
    WHERE tray_id = NEW.id AND ended_at IS NULL;
    -- Zero rows updated when no open event existed (e.g. stockout at migration time): no-op, fine.
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER zzz_tray_stockout_event
  AFTER UPDATE OF current_stock ON public.machine_trays
  FOR EACH ROW EXECUTE FUNCTION public.handle_tray_stockout_event();
```

**Helper function** (same migration):
```sql
CREATE OR REPLACE FUNCTION public.get_product_velocity_one(
  p_company_id uuid, p_product_id uuid, p_days int
) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT COALESCE(COUNT(*) / NULLIF(p_days::numeric, 0), 0)
  FROM public.sales s
  JOIN public."vendingMachine" vm ON vm.id = s.machine_id
  WHERE vm.company = p_company_id
    AND s.product_id = p_product_id
    AND s.created_at >= now() - (p_days || ' days')::interval;
$$;
```

**Edge cases (documented behavior):**
- **Manual stock correction** (admin fixes a miscount, going 0 → positive): trigger cannot distinguish from a real refill, *but* the `< 5 min duration` clamp zeros out `lost_units_estimated` and `lost_revenue_estimated` for short-lived "stockouts" — eliminates noise from typical correction workflows. Genuine stockouts last hours, not minutes.
- **Refill 0 → positive without prior open event** (e.g. data import, manual SQL): UPDATE branch finds zero rows, no-op. Fine.
- **Stockout open at migration time**: no event row exists; first 0 → positive UPDATE finds nothing, no-op. Subsequent stockouts work normally. Operations tab banner notes: "Stockout-Daten verfügbar ab DD.MM.YYYY".
- **Concurrent UPDATEs on same tray**: unique partial index `idx_stockouts_one_open_per_tray` rejects duplicate INSERTs; `ON CONFLICT DO NOTHING` resolves the race silently.
- **0 → positive → 0 in one transaction** (data fix): trigger fires twice; close finds nothing (no-op), open inserts new event. Correct.
- **Sale with `product_id = NULL`** (e.g. firmware sent unknown item_number that didn't match a tray): tray's `product_id` may be NULL; trigger still fires and writes NULL `product_id` into the event. Velocity helper returns 0 for NULL product, so loss estimate is 0. Acceptable.

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
  p_vat_rates       numeric[]           -- NULL or empty = all; values are decimal e.g. 0.07, 0.19
) RETURNS jsonb
```

All RPCs:
- `LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' SET statement_timeout = '10s'` (function-level GUCs — survive across transactions, not `SET LOCAL`)
- Validate `p_company_id = public.my_company_id()` at entry as defense-in-depth
- Return `jsonb` with a `version: 1` field at the root so future shape changes are visible to clients

**Note for implementer:** `my_company_id()` and `i_am_admin()` themselves must remain `SECURITY DEFINER` — see `20260418000000_fix_rls_recursion_api_auth.sql`. A regression here causes RLS recursion (54001). This broke production once.

**Internal helper `_analytics_filtered_sales(p_filters jsonb) RETURNS SETOF sales`**: applies the shared `WHERE` clause. All six RPCs `SELECT FROM _analytics_filtered_sales(jsonb_build_object(...))` so filter logic is not duplicated six times. `p_filters` includes the relevant subset of the parameters above as JSON. Filter rules:
- `tax_rate_snapshot` filter: when `p_vat_rates` is NULL or empty, all rows pass (including NULL `tax_rate_snapshot`). When set, only rows with `tax_rate_snapshot = ANY(p_vat_rates)` pass — NULL-snapshot rows are excluded.
- `category_ids` filter joins through `products.category` (column name on `products` is `category`, not `category_id` — verified against current schema).
- `machine_ids` filters on `sales.machine_id`.
- `channels` filters on `sales.channel`.

**Per-RPC return shapes (jsonb):**

| RPC | Returns |
|-----|---------|
| `analytics_overview` | `{ version: 1, kpis: {revenue, units, avg_basket, conversion_pct}, kpis_compare: {revenue, units, avg_basket, conversion_pct}, daily_series: [{date, revenue, units}], top_products: [{product_id, name, image_path, units, revenue, mix_pct}], top_machines: [{machine_id, name, status, revenue, conversion_pct}] }` |
| `analytics_sales_breakdown(p_dimension text)` | `{ version: 1, dimension, rows: [{key, label, revenue, units, avg_basket, count, share_revenue_pct, share_units_pct}] }` — `p_dimension ∈ {'machine','product','category','channel','vat','hour','dow'}`; `share_*_pct` denominators are the **filtered total** (re-normalize within the active filter, not company-wide). |
| `analytics_products` | `{ version: 1, kpis: {active_count, slow_mover_count, discontinued_count, categories_with_sales}, products: [{id, name, image_path, category_id, velocity, units, revenue, mix_pct, vat_rate, status, slow_mover_days, last_sold_at}], mix_shift_series: [{date, category_id, revenue}] }` — `status ∈ {'active','slow','dead','discontinued'}` |
| `analytics_machines` | `{ version: 1, kpis: {active_count, best_machine_id, best_machine_name, best_revenue, avg_conversion_pct, total_stockout_hours}, machines: [{id, name, lat, lng, status, revenue, units, conversion_pct, last_sale_gap_minutes, stock_health, current_online}], heatmaps: { <machine_id>: { dow: [count_mon, ..., count_sun], hour: [count_h0, ..., count_h23] } } }` — heatmap cells are **sales count** in V1 (toggle to revenue is V2). |
| `analytics_conversion` | `{ version: 1, kpis: {footfall, conversion_pct, best_machine_id, empty_passes}, machines: [{id, name, pax, sales, conversion_pct, revenue_per_visitor}], hour_heatmap: { <machine_id>: [conversion_h0, ..., conversion_h23] }, daily_conversion_series: [{date, conversion_pct}] }` — `empty_passes = MAX(0, footfall - units)` company-wide for the filtered period; per-machine empty-passes not exposed in V1. |
| `analytics_operations` | `{ version: 1, kpis: {stockout_hours, lost_revenue, refill_tour_count, avg_stock_cover_days}, stockout_events: [{id, machine_id, machine_name, tray_id, item_number, product_id, product_name, started_at, ended_at, duration_seconds, lost_units_estimated, lost_revenue_estimated}], refill_tours: [{tour_id, started_at, ended_at, duration_minutes, user_display, machines_count, units_added, machines: [{machine_id, machine_name, items_added}]}], stock_cover: [{tray_id, machine_id, machine_name, item_number, product_id, product_name, current_stock, velocity, cover_days}] }` |

**Naming consistency**:
- `revenue numeric` — EUR (matches `sales.item_price`)
- `units int` — count of sale rows
- `avg_basket numeric` — `revenue / NULLIF(count, 0)`
- `conversion_pct numeric` — 0..100, two decimals
- `share_*_pct numeric` — 0..100
- All durations in seconds or minutes, named accordingly

`get_product_sales_velocity` (existing) is reused by `analytics_products`. `analytics_operations.refill_tours` is computed from `activity_log` rows grouped by `metadata->>'tour_id'` (with the same 10-minute fallback bucketing logic that `useTourHistory.ts` uses today) — there is **no `tour_history` table**.

`analytics_operations.stock_cover` joins `machine_trays` with `get_product_sales_velocity` and computes `cover_days = current_stock / NULLIF(velocity, 0)`.

### Backwards Compatibility

- New table is additive; no existing column or trigger is modified.
- All RPCs are new functions — none replaces an existing function.
- Pre-migration data: stockout events table is empty; all other queries work normally on existing sales / machine_trays / paxcounter rows. Banner ("Daten verfügbar ab …") shown for any filter window extending before the migration timestamp.

## Tab Contents

Global filter bar (always visible at top, sticky on scroll): **date range** with presets (Today / 7d / 30d / 90d / YTD / 12M / Custom) + period-comparison toggle, **machines** multi-select, **channel** toggles (cashless / cash / card), **categories** multi-select, **VAT-rates** multi-select (options come from distinct existing `tax_rate_snapshot` values for the company, displayed as percent labels). Reset button + "Save as preset" dropdown. URL query sync on web. Filter panel collapses to a "Filters · 3 active" pill on small screens.

### Tab 1 — Overview

- **KPI cards (4)**: Revenue · Units · Avg basket · Conversion %. Period-comparison delta badge per card.
- **Main chart**: daily revenue line over selected period, with units as second y-axis. Period-comparison overlay (dotted) toggled via filter bar. Scrubbable on iOS via `chartXSelection`.
- **Top 5 Products** compact table (image, name, units, revenue, mix %). Click name → push to product detail. Click numeric cell → set product filter, switch to Sales tab.
- **Top 5 Machines** compact table (name, status badge, revenue, conversion %). Click name → push to machine detail. Click numeric cell → set machine filter.
- **AI Insights module** — the existing `companyInsights` UI is rendered here from Phase 3. Uses the company's `velocity_days` setting (from `companies.velocity_days` per CLAUDE.md), **not** the analytics filter. Header reads: "Auswertung der letzten {company.velocity_days} Tage" so the period scope is explicit and distinct from the filter pill.

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
- Drill: row name/image → existing `ProductDetailSheet` (iOS) or `ProductFormModal` opened with that product's id (web — there is no `/products/[id]` route, the existing modal pattern is reused)

### Tab 4 — Machines

- **KPI cards (4)**: Active count · Best machine (name + revenue) · Avg conversion % · Total stockout hours (period)
- **Machine table/cards**: name, status badge, revenue, units, conversion %, last-sale-gap, stock-health bar (existing component), online indicator
- **Heatmap toggle**: weekday × hour per machine (cells = sales count)
- **Compare button**: multiselect up to 4 machines → opens `AnalyticsCompareSheet` with side-by-side mini-charts (revenue trend, conversion trend, top-3 products per machine). On iPhone presented as stepwise sheet.
- **Geo map** (web + iPad only): bubbles from `sales.lat/lng`, size = revenue, color = conversion percentile
- Drill: machine name → existing `MachineDetailView` / `/machines/[id]`

### Tab 5 — Conversion (Pax × Sales — the unique-here surface)

- **KPI cards (4)**: Footfall · Conversion % · Best converting machine · Empty passes (`MAX(0, footfall - units)`, fleet-wide)
- **Heatmap**: machines × hour, color = conversion %
- **Scatter**: x = traffic, y = revenue, each point a machine. Diagonal reference at fleet-average conversion. Click point → push to machine detail.
- **Daily conversion trend**: line chart, with Δ vs comparison period
- **Per-machine table**: pax · sales · conversion % · revenue per visitor

### Tab 6 — Operations

- **KPI cards (4)**: Stockout hours · Lost revenue (€) · Refill tours · Avg stock cover days
- **Stockout events list** from `tray_stockout_events`: machine · tray · product · started_at · duration · estimated lost €. Sortable by lost €. Click → opens machine-detail with the tray pre-focused.
- **Refill efficiency** from `activity_log` grouped by `metadata->>'tour_id'`: per-tour duration, units refilled, machines visited, total restocked-units. Compute units-per-minute as efficiency proxy.
- **Stock-cover-days** per tray (current_stock / daily_velocity), sorted ascending. Trays under 3 days highlighted red. Click → opens Refill wizard with that machine pre-selected.

### Drill-Through Convention (applies everywhere)

| Click target | Behavior |
|--------------|----------|
| Numeric cell (revenue, units, conversion, etc.) | Sets the corresponding global filter, stays on current tab |
| Name or image (product, machine, category) | Pushes to the existing detail page/sheet |
| "Compare" buttons | Opens `AnalyticsCompareSheet`, no tab change |

iOS uses `NavigationLink` for pushes and `.onTapGesture` for filter-set actions. Web uses `<NuxtLink>` for pushes and click-handlers for filter updates.

### iOS-Specific Tab Adaptations

- **Overview**: KPI grid 2×2 on iPhone / 1×4 on iPad. Main chart full-width, scrollable on iPhone via `.chartScrollableAxes(.horizontal)` + `.chartXVisibleDomain(length: 30 * 86400)`.
- **Sales**: dimension switcher as scrollable tag-pills (`ScrollView(.horizontal)`) — segmented control caps at ~5 items.
- **Products**: `.searchable` searchbar, `List` with thumbnails, sub-filters via toolbar `Menu`.
- **Machines**: existing list pattern from `Views/Machines/`. Compare on iPhone is stepwise; on iPad multi-select inline. Geo map only on iPad.
- **Conversion**: full heatmap only on iPad. iPhone reduces to a list with conversion bars per row.
- **Operations**: list of stockouts with `.swipeActions` ("Plan tour", "Mark resolved"). Refill tours collapsible per day.

## Filter System & Cross-Cutting

### Filter URL/preset serialization (canonical, web ↔ iOS-compatible)

JSON object with these exact keys, base64url-encoded when used in a URL query:
```
{
  "v": 1,                                  // schema version
  "from": "2026-04-09T00:00:00Z",          // ISO 8601 UTC
  "to":   "2026-05-09T23:59:59Z",
  "compare": false,                        // bool
  "machines": ["uuid1","uuid2"],           // [] = all
  "channels": ["cashless","cash"],         // [] = all
  "categories": ["uuid"],                  // [] = all
  "vatRates": [0.07, 0.19]                 // [] = all
}
```
Web URL: `/analytics?f=<base64url>#sales`. Length budget ~1500 chars; for longer filter sets the URL falls back to `?preset=<name>`.

iOS `@AppStorage` writes the same JSON (without base64), so a preset saved on iPhone can be re-loaded from a web URL and vice versa.

**Forward compatibility**: parser drops unknown top-level keys silently and clamps `v` to the current schema version when an older URL is loaded — guarantees that future filter additions don't break shareable links.

### Loading states

- **Filter change**: existing data fades to 60% opacity, inline spinner appears next to filter bar, debounced 300 ms, then re-fetch and fade back to 100%.
- **Initial tab load**: skeleton boxes for charts, shimmer rows for tables.
- **iOS first load**: `ProgressView` overlay; subsequent reloads show inline spinner only.

### Error handling

- **RPC failure**: per-tab toast + retry button. Other tabs continue working.
- **Statement timeout**: each RPC declares `SET statement_timeout = '10s'` at function level; on timeout the tab shows "Query timeout — try a smaller date range".
- **Filter apply fails**: data stays visible with banner "Filter konnte nicht angewendet werden".
- **Empty result**: existing `ContentUnavailableView` (iOS) / empty-state component (web).
- **Pre-migration date range**: Operations tab banner "Stockout-Daten verfügbar ab DD.MM.YYYY".
- **RPC `version` mismatch**: client surfaces "Update verfügbar — bitte App neu laden" banner.

### Caching

- **Web**: `useAnalyticsData` keeps 30-second in-memory cache keyed by `(tab, filterHash)`. Manual refresh and filter change bypass.
- **iOS**: `@StateObject` ViewModel persists across tab navigation within Analytics root; tab-switching does not re-fetch unless filter changed.

### Realtime hint banner

- **Overview tab only** subscribes to Sale `INSERT` realtime via the existing `RealtimeService.salesVersion` (already company-wide). On increment, sets `hasNewData = true` → "🔄 Neue Daten verfügbar — aktualisieren" pill above KPIs. User-triggered refresh.

### RLS

- New `tray_stockout_events` uses standard `company_id = my_company_id()` SELECT-only policy (see migration 1). Writes are trigger-managed.
- All six RPCs are `SECURITY DEFINER` and validate `p_company_id = my_company_id()` at entry as defense-in-depth.
- Both `admin` and `viewer` roles can read all analytics — revenue and conversion are business insights, not PII.

### Tests

- **Vitest (web, `management-frontend/app/composables/__tests__/`)**:
  - `useAnalyticsFilters`: URL/JSON serialization round-trip including unknown-key dropping and `v` clamping, preset save/load, filter merge with defaults, reset behavior
  - `useAnalyticsExport`: CSV column ordering, BOM for Excel, locale-aware decimal separator
  - `AnalyticsTable.spec.ts`: sorting and drill-through click handling
- **Deno tests** for each RPC, located at `Docker/supabase/tests/analytics/` (analytics RPCs have no edge function owner, so a dedicated test directory mirrors the cashbook spec convention rather than the per-function colocation pattern).
  - Each RPC: filter combinations including empty/null arrays, period-comparison correctness, RLS isolation, `version: 1` present in every response
  - `analytics_sales_breakdown` for each `p_dimension` value
  - **Test fixture**: `Docker/supabase/tests/fixtures/two_companies.sql` — to be created in Phase 1 if not yet present. Seeds 2 companies, 2 admin users, 2 machines per company, ~50 sales per company, 1 stockout event per company. Fixture pattern matches the existing setup approach used by `mqtt-webhook` tests (Supabase local + service-role seed).
- **SQL trigger tests** (Deno test using `pg` client): `tray_stockout_events` trigger covers open → close → reopen, the unique-partial-index prevents duplicate open events, the `< 5 min duration` clamp produces zero loss, lost_revenue math is correct given a known velocity.
- **iOS XCTest baseline**: `AnalyticsFilter` codable round-trip, preset persistence, unknown-key drop; smoke test for one ViewModel (`AnalyticsOverviewViewModel`).

### Export

- **CSV**, V1, all platforms. Per-tab table data:
  - **Encoding**: UTF-8 with BOM
  - **Delimiter**: `;` (German Excel default)
  - **Decimal separator**: locale-aware via `Intl.NumberFormat` (web) / `Locale.current` (iOS) — comma in de-DE, point in en-US
  - **Column headers**: translated via existing i18n (`analytics.columns.revenue`, etc.) — match the on-screen header
  - **Date format**: ISO 8601 `YYYY-MM-DD HH:mm:ss`
  - **Column order per tab**: matches the on-screen table left-to-right
  - **File name**: `vmflow-analytics-{tab}-{from}-{to}.csv`
- **PNG chart snapshot** — V1, web only. Library: `html-to-image`. Triggered from per-chart toolbar button. iOS PNG export deferred.

### i18n

- **Web**: new namespace `analytics.*` in `i18n/locales/de.json` and `en.json`. Reuse existing `formatCurrency` from `app/lib/utils.ts`. Strings like "Stockout-Daten verfügbar ab …" are i18n keys, not hardcoded text.
- **iOS**: extend `Localizable.xcstrings` with `analytics.*` keys. Use `.formatted(.currency(code: "EUR"))` for amounts, `.formatted(.percent)` for shares.
- Chart axis labels and tooltip values pass through translation; chart legends use `t()` / `String(localized:)`.

## Build Order

Phases 0 and 1 are strict prerequisites; Phases 2-5 contain parallelizable work.

### Phase 0 — Stockout Foundation (BLOCKING but small)

1. Migration 1: `tray_stockout_events` table, indexes, RLS (SELECT-only), trigger function `handle_tray_stockout_event`, trigger `zzz_tray_stockout_event`, helper `get_product_velocity_one`
2. Verification on dev DB:
   - Drive `current_stock` to 0 and back across a few trays, confirm event lifecycle, confirm unique-index prevents duplicate open events
   - Confirm `lost_revenue_estimated` math (`velocity × duration_h / 24 × sellprice`)
   - Confirm `< 5 min duration` clamp produces 0
   - **Performance check**: simulate a 50-tray refill in a single transaction (50 simultaneous `current_stock` UPDATEs); confirm aggregate trigger overhead stays under 500 ms. The `get_product_velocity_one` call is the dominant cost; if it exceeds budget, cache via materialized view (out-of-spec change, raise the question).

### Phase 1 — Backend RPCs

3. Migration 2: `_analytics_filtered_sales` shared helper + the six analytics RPCs + function-level `SET statement_timeout = '10s'` + `version: 1` field in every response
4. Two-company test fixture at `Docker/supabase/tests/fixtures/two_companies.sql`
5. Deno tests per RPC + performance check on realistic sample data (50 machines × 90 days × ~10k sales)
6. Index audit: `EXPLAIN ANALYZE` each RPC with 90-day window; if any exceeds 500 ms, add covering indexes

### Phase 2 — Web Foundation (parallelizable with Phase 4)

7. Composables: `useAnalyticsFilters`, `useAnalyticsData`, `useAnalyticsExport`
8. Shared components: `AnalyticsFilterBar`, `AnalyticsTabNav`, `AnalyticsKpiGrid`, `AnalyticsChart`, `AnalyticsTable`, `AnalyticsCompareSheet`, `AnalyticsPresetMenu`
9. `/analytics/index.vue` skeleton with hash-based tab routing

### Phase 3 — Web Tabs (parallelizable after Phase 2)

10. Six tab components in priority order: Overview → Sales → Machines → Products → Conversion → Operations.
    Overview includes the AI insights block from this phase (the existing `companyInsights` component is rendered inside `TabOverview.vue`).

### Phase 4 — iOS Foundation (parallelizable with Phase 2)

11. `AnalyticsFilter` model with `Codable` + `@AppStorage` persistence (same JSON as web, with unknown-key dropping)
12. `AnalyticsRootView` with adaptive layout (iPhone single-screen with horizontal section picker; iPad/Mac NavigationSplitView) + `SidebarItem.analytics` registration in `AppNavigation.swift` + `MoreView` entry in `VMflowApp.swift`
13. Shared views: `AnalyticsKPIGroup`, `AnalyticsChart`, `AnalyticsSortableList`, `ComparePeriodBadge`, `AnalyticsHeatmap`
14. `AnalyticsFilterSheet` (bottom sheet on iPhone, inspector on iPad)

### Phase 5 — iOS Sections (parallelizable after Phase 4)

15. Six section views in same priority order as web

### Phase 6 — Polish & Release

16. i18n strings for all keys (Web `de.json` / `en.json`, iOS `Localizable.xcstrings`)
17. CSV export wiring + PNG chart snapshot (web)
18. **Remove duplicate AI insights from `/` Dashboard** — the block was only added to `TabOverview` in Phase 3 step 10; this step deletes the older copy from `pages/index.vue`. Net effect: AI insights migrate from Dashboard to Analytics. (No new code in Phase 6, just deletion.)
19. Test suites complete: Vitest, Deno, SQL trigger tests, XCTest baseline
20. Update `CLAUDE.md` with new table, RPCs, migration order
21. Verification on real production-like data set (or staging)

### Critical-path summary

```
Phase 0 → Phase 1 → (Phase 2 in parallel with Phase 4) → (Phase 3 in parallel with Phase 5) → Phase 6
```

## Risks & Mitigations

- **Risk: stockout trigger collides with future triggers on `current_stock`**
  *Mitigation:* trigger named `zzz_tray_stockout_event` to sort last alphabetically. Future triggers should use `aaa_*`/`mmm_*` prefixes to control order. Document the convention in this trigger's migration file.

- **Risk: RPC performance on large datasets**
  *Mitigation:* shared `_analytics_filtered_sales` helper applies `WHERE` indexes early. Index audit at end of Phase 1. RPCs declare `SET statement_timeout = '10s'` at function level — runaway queries fail fast rather than locking the request.

- **Risk: filter URL grows unwieldy with many machines selected**
  *Mitigation:* serialize filter as base64url-encoded JSON; if length exceeds 1500 chars, fall back to `?preset=xyz` referencing the named preset.

- **Risk: iOS Charts framework limitations on long horizontal series**
  *Mitigation:* use `.chartScrollableAxes(.horizontal)` + `.chartXVisibleDomain(length: 30 * 86400)` for any series longer than 30 days.

- **Risk: stockout duplicates from concurrent updates**
  *Mitigation:* unique partial index `idx_stockouts_one_open_per_tray (tray_id) WHERE ended_at IS NULL` rejects duplicate open events at the DB level. Trigger uses `ON CONFLICT DO NOTHING`.

- **Risk: stockout trigger fires false-positive lost-revenue when admin manually corrects a stock miscount**
  *Mitigation:* `< 5 min duration` clamp zeros out loss estimates for short-lived "stockouts". Real outages last hours.

- **Risk: AI insights now lives only in Analytics, but a user landing on `/` after Phase 6 might miss it**
  *Mitigation:* dashboard's existing top KPI strip remains; the AI block was never the primary surface. Acceptable scope reduction. (If product feedback says otherwise, leaving a small `Insights →` link on dashboard pointing to `/analytics#overview` is a follow-up of <1 hour.)

## Open Questions (Resolved during brainstorming)

- ✅ Architecture style: themed tabs with global filter bar (not pivot-canvas)
- ✅ V1 scope: revenue / units / conversion — margin tracking deferred to V2
- ✅ Web scope: all six tabs Big Bang
- ✅ iOS scope: all six sections Big Bang
- ✅ Filter persistence: `localStorage` / `@AppStorage` with shared JSON format
- ✅ Realtime: filter-change + pull-to-refresh + Overview "new data" pill (no auto-recompute)
- ✅ AI insights placement: render in `TabOverview` from Phase 3; remove from dashboard in Phase 6
- ✅ iPhone geo map: out of scope V1
- ✅ Machine uptime %: out of scope V1
- ✅ iPhone navigation: single-screen with horizontal section picker (not tile-menu — matches cashbook precedent depth)
- ✅ Stockout false-positives from manual corrections: clamp loss to 0 for events shorter than 5 minutes
- ✅ VAT filter source: `sales.tax_rate_snapshot`, NULL rows excluded only when filter is set

## Out of Scope (Future)

- **Margin / profit / cost-of-goods analytics** — would require `products.cost_price` + per-batch `unit_cost` tracking + a tray-level FIFO ledger. Significant migration risk on the sales hot path. Worth doing once the analytics surface itself is validated.
- **Machine uptime % and MTBF** — needs an `embeddeds_status_history` table populated from MQTT status events.
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
- iOS PNG / PDF chart export
- Heatmap cell metric toggle (count ↔ revenue)
- Per-machine `empty_passes` exposure
