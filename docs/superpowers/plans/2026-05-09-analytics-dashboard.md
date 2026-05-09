# Analytics Dashboard Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a comprehensive `/analytics` page (Web) plus a native iOS Analytics section, both with six themed tabs (Overview, Sales, Products, Machines, Conversion, Operations) sharing a global filter bar. Add `tray_stockout_events` for lost-revenue tracking and six new Postgres RPCs serving both platforms.

**Architecture:** One new Postgres table + six new RPCs serve both surfaces. Web uses Nuxt 4 with `useState`-backed filter composable, URL-hash tab routing, and 30 s in-memory cache. iOS uses SwiftUI with `@StateObject AnalyticsFilter` injected via `.environmentObject(...)` and `@AppStorage` persistence. Filter JSON format is identical across platforms so presets round-trip.

**Tech Stack:** PostgreSQL 15.8 (Supabase), Nuxt 4 + Vue 3 + TailwindCSS 4 + shadcn-nuxt, SwiftUI + Charts framework (iOS 17+), Vitest, plain SQL `*.test.sql` (Docker/supabase/tests pattern), XCTest.

**Spec:** [2026-05-09-analytics-dashboard-design.md](../specs/2026-05-09-analytics-dashboard-design.md)

**Reference prior art:**
- `Docker/supabase/migrations/20260317000000_machine_insights_rpc.sql` — RPC pattern with SECURITY DEFINER + my_company_id() check
- `Docker/supabase/migrations/20260418000000_fix_rls_recursion_api_auth.sql` — `SET search_path = ''` convention
- `Docker/supabase/tests/get_product_detail_kpis.test.sql` — SQL test pattern (BEGIN; DO $$ … $$; ROLLBACK;)
- `management-frontend/app/composables/useTourHistory.ts` — `activity_log` grouped by `metadata->>'tour_id'` with 10-min fallback
- `management-frontend/app/components/ChartAreaInteractive.vue` — chart wrapper to reuse
- `ios/VMflow/Views/Dashboard/DashboardView.swift` — KPICard adaptive grid + `chartXSelection` patterns
- `ios/VMflow/Navigation/AppNavigation.swift` — `SidebarItem` + `compactTab: nil` pattern (cashbook precedent)
- `ios/VMflow/VMflowApp.swift:121-166` — `MoreView` extension pattern

**Schema facts the plan relies on:**
- `sales(id, machine_id uuid → vendingMachine, product_id uuid → products, item_price float8 — EUR not cents, item_number bigint, channel text, tax_rate_snapshot numeric(6,4), tax_amount, price_net, lat, lng, created_at)`
- `machine_trays(id, machine_id, item_number bigint, product_id, capacity, current_stock, fill_when_below)` — has NO `company_id`; resolve via `vendingMachine.company`
- `vendingMachine(id, name, company uuid, …)` — quoted camelCase identifier; column is `company` (not `company_id`)
- `paxcounter(id, embedded_id, machine_id, count, created_at, …)`
- `products(id, name, sellprice float8 — EUR, description, company, category)` — column is `category` (not `category_id`)
- `activity_log(id, created_at, company_id, user_id, kind, metadata jsonb, …)` — refill tours grouped by `metadata->>'tour_id'`
- `embeddeds(id, status, last_seen, online_since, …)` — uptime history NOT tracked, V1 uses status only
- `tax_rate_snapshot` is **decimal** (e.g. 0.07, 0.19), nullable for pre-tax-infrastructure sales
- RLS helpers `my_company_id()` and `i_am_admin()` are SECURITY DEFINER (per `20260418000000_fix_rls_recursion_api_auth.sql`)
- `companies.velocity_days int default 30` — used by AI insights, NOT analytics filter

**Branching strategy:** Each chunk commits independently and leaves the app in a working state. Chunk 1 + 2 are backend-only (no UI changes user can see). Chunk 3 + 4 ship Web Analytics incrementally. Chunk 5 + 6 ship iOS Analytics incrementally. Chunk 7 polishes (deletes duplicate AI insights from `/`, updates docs). Web and iOS can ship in either order after Chunk 2 — neither blocks the other.

**Test execution:**
- SQL tests: `bash Docker/supabase/tests/run-sql-tests.sh` (requires `supabase start`)
- Vitest: `cd management-frontend && npx vitest run` (or `--watch`)
- XCTest: `xcodebuild test -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 15'`

**Migration timestamps:** Latest existing migration is `20260508000000_track_per_machine.sql`. New analytics migrations use `20260509000000` (stockouts) and `20260509000100` (RPCs).

**Skill references:**
- @superpowers:test-driven-development — write the failing test first, every task
- @superpowers:verification-before-completion — run the verification command, observe output, before marking work done

---

## Chunk 1: Phase 0 — Stockout Foundation

**Goal:** Add `tray_stockout_events` table, helper `get_product_velocity_one`, and the `zzz_tray_stockout_event` trigger. Ship it with a comprehensive SQL trigger test that covers open/close, the 5-min clamp, single-transaction double transitions, and the partial unique index. Phase 0 of the spec.

**Files:**
- Create: `Docker/supabase/migrations/20260509000000_analytics_stockout_events.sql`
- Create: `Docker/supabase/tests/tray_stockout_event_trigger.test.sql`
- Modify: `CLAUDE.md` (add new table to "Database Tables" section, mention helper under the trigger)

**Workflow note for the executor:** the migration is written **once** as a complete file (table + RLS + indexes + helper + trigger function + trigger), then applied **once** via `supabase migration up`. Do NOT iterate by editing-and-reapplying the same timestamped migration — the project's migration-tracking marks it as applied after first run, so subsequent edits would silently diverge between environments. If you need to iterate, drop the partial state first (`DROP TABLE public.tray_stockout_events CASCADE; DELETE FROM supabase_migrations.schema_migrations WHERE version = '20260509000000';`) and rerun `supabase migration up`. **NEVER run `supabase db reset`** — see CLAUDE.md memory.

### Task 1.1: Write the failing trigger test (lifecycle scenario)

**Files:**
- Create: `Docker/supabase/tests/tray_stockout_event_trigger.test.sql`

- [ ] **Step 1: Create the test file**

```sql
-- Docker/supabase/tests/tray_stockout_event_trigger.test.sql
-- Integration test for the zzz_tray_stockout_event trigger.
-- Runs in one transaction that is rolled back at the end.
-- Pattern matches Docker/supabase/tests/get_product_detail_kpis.test.sql.

BEGIN;
SET LOCAL TIME ZONE 'UTC';

-- ─── Test 1.1: open → close lifecycle ───────────────────────────────────────
DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_machine   uuid := gen_random_uuid();
  v_product   uuid := gen_random_uuid();
  v_tray      uuid;
  v_event_id  uuid;
  v_open_count int;
  v_lost_units numeric;
  v_lost_revenue numeric;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'StockoutTestCo');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'so@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'so@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  INSERT INTO public.products (id, name, sellprice, company)
    VALUES (v_product, 'Test Snack', 1.50, v_company);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine, 'Test Machine', v_company);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine, 1, v_product, 10, 5)
    RETURNING id INTO v_tray;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text,
    true);

  -- Open: drive current_stock to 0
  UPDATE public.machine_trays SET current_stock = 0 WHERE id = v_tray;

  SELECT count(*) INTO v_open_count
  FROM public.tray_stockout_events
  WHERE tray_id = v_tray AND ended_at IS NULL;

  ASSERT v_open_count = 1, format('expected 1 open event, got %s', v_open_count);

  SELECT id INTO v_event_id
  FROM public.tray_stockout_events
  WHERE tray_id = v_tray AND ended_at IS NULL;

  -- Backdate to 2 hours ago to simulate a real outage.
  -- Trigger close branch must not overwrite started_at, only ended_at.
  UPDATE public.tray_stockout_events
  SET started_at = now() - interval '2 hours'
  WHERE id = v_event_id;

  -- Close: refill stock back to positive
  UPDATE public.machine_trays SET current_stock = 7 WHERE id = v_tray;

  SELECT count(*) INTO v_open_count
  FROM public.tray_stockout_events
  WHERE tray_id = v_tray AND ended_at IS NULL;

  ASSERT v_open_count = 0, format('expected 0 open events after close, got %s', v_open_count);

  SELECT lost_units_estimated, lost_revenue_estimated
    INTO v_lost_units, v_lost_revenue
  FROM public.tray_stockout_events
  WHERE id = v_event_id;

  -- 2-hour outage with no prior sales → velocity = 0 → loss = 0.
  -- Assert math ran (NOT NULL) and produced non-negative values.
  ASSERT v_lost_units IS NOT NULL, 'lost_units should be set on close';
  ASSERT v_lost_units >= 0, 'lost_units must be non-negative';
  ASSERT v_lost_revenue IS NOT NULL, 'lost_revenue should be set on close';
  ASSERT v_lost_revenue >= 0, 'lost_revenue must be non-negative';

  RAISE NOTICE 'Test 1.1 (open + close lifecycle) PASSED';
END;
$$;

ROLLBACK;
```

- [ ] **Step 2: Run the test — expect failure**

Run from the worktree root:
```bash
bash Docker/supabase/tests/run-sql-tests.sh
```

Expected output: the runner prints `── Running tray_stockout_event_trigger.test.sql ──` followed by a psql error containing `relation "public.tray_stockout_events" does not exist`, then `  FAIL`. The other test (`get_product_detail_kpis.test.sql`) should still print `  PASS`. The script exits with code 1.

- [ ] **Step 3: Commit the failing test**

```bash
git add Docker/supabase/tests/tray_stockout_event_trigger.test.sql
git commit -m "test(analytics): add failing test for tray stockout trigger lifecycle"
```

### Task 1.2: Write Migration 1 — complete file in one shot

**Files:**
- Create: `Docker/supabase/migrations/20260509000000_analytics_stockout_events.sql`

- [ ] **Step 1: Create the migration file in full**

```sql
-- Docker/supabase/migrations/20260509000000_analytics_stockout_events.sql
-- Adds tray_stockout_events table with trigger-managed lifecycle for analytics.
-- Open: machine_trays.current_stock crosses positive → 0 (INSERT event row)
-- Close: machine_trays.current_stock crosses 0 → positive (UPDATE event row,
--        compute lost_units / lost_revenue with a < 5 min duration clamp).
--
-- Helper get_product_velocity_one is internal-only (REVOKE PUBLIC).
-- Trigger named zzz_* so it sorts last alphabetically among future triggers
-- on machine_trays.current_stock.

-- ── Table ─────────────────────────────────────────────────────────────────────
CREATE TABLE public.tray_stockout_events (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tray_id                uuid NOT NULL REFERENCES public.machine_trays(id) ON DELETE CASCADE,
  machine_id             uuid NOT NULL REFERENCES public."vendingMachine"(id) ON DELETE CASCADE,
  item_number            bigint NOT NULL,
  product_id             uuid REFERENCES public.products(id) ON DELETE SET NULL,
  started_at             timestamptz NOT NULL,
  ended_at               timestamptz,
  duration_seconds       int GENERATED ALWAYS AS
    (EXTRACT(EPOCH FROM (ended_at - started_at))::int) STORED,
  lost_units_estimated   numeric,
  lost_revenue_estimated numeric,
  velocity_at_close      numeric,
  company_id             uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  created_at             timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_stockouts_one_open_per_tray
  ON public.tray_stockout_events (tray_id) WHERE ended_at IS NULL;

CREATE INDEX idx_stockouts_company_started
  ON public.tray_stockout_events (company_id, started_at DESC);

ALTER TABLE public.tray_stockout_events ENABLE ROW LEVEL SECURITY;

-- SELECT-only for authenticated users; INSERT/UPDATE/DELETE only via SECURITY DEFINER
-- trigger context (which bypasses RLS as function owner).
CREATE POLICY tray_stockout_events_select ON public.tray_stockout_events
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

GRANT SELECT ON public.tray_stockout_events TO authenticated;
GRANT ALL    ON public.tray_stockout_events TO service_role;

-- ── Helper: per-product daily velocity ───────────────────────────────────────
-- Internal-only: revoked from PUBLIC to prevent cross-company velocity probe
-- via PostgREST. The trigger calls it from its own SECURITY DEFINER context.

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

REVOKE ALL ON FUNCTION public.get_product_velocity_one(uuid, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_product_velocity_one(uuid, uuid, int) TO service_role;

-- ── Trigger function: open / close stockout events with 5-min clamp ──────────
-- < 5 min duration zeros out lost_units/lost_revenue (admin miscount-correction
-- noise — real outages last hours).

CREATE OR REPLACE FUNCTION public.handle_tray_stockout_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_company_id  uuid;
  v_velocity    numeric;
  v_sellprice   numeric;
BEGIN
  SELECT vm.company INTO v_company_id
  FROM public."vendingMachine" vm WHERE vm.id = NEW.machine_id;
  IF v_company_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Open: stock crossed positive → 0
  IF OLD.current_stock > 0 AND NEW.current_stock = 0 THEN
    INSERT INTO public.tray_stockout_events
      (tray_id, machine_id, item_number, product_id, started_at, company_id)
    VALUES
      (NEW.id, NEW.machine_id, NEW.item_number, NEW.product_id, now(), v_company_id)
    ON CONFLICT DO NOTHING;
    RETURN NEW;
  END IF;

  -- Close: stock crossed 0 → positive
  IF OLD.current_stock = 0 AND NEW.current_stock > 0 THEN
    SELECT public.get_product_velocity_one(v_company_id, NEW.product_id, 30)
      INTO v_velocity;
    SELECT sellprice INTO v_sellprice
      FROM public.products WHERE id = NEW.product_id;

    -- Single UPDATE; reads started_at from the row inside the CASE expressions.
    -- Zero rows updated when no open event existed (e.g. stockout at migration
    -- time, data fix) → no-op, fine.
    UPDATE public.tray_stockout_events
    SET ended_at              = now(),
        velocity_at_close     = v_velocity,
        lost_units_estimated  = CASE
          WHEN EXTRACT(EPOCH FROM (now() - started_at)) < 300 THEN 0
          ELSE ROUND(COALESCE(v_velocity, 0)
                     * EXTRACT(EPOCH FROM (now() - started_at)) / 86400.0, 2)
        END,
        lost_revenue_estimated = CASE
          WHEN EXTRACT(EPOCH FROM (now() - started_at)) < 300 THEN 0
          ELSE ROUND(COALESCE(v_velocity, 0)
                     * EXTRACT(EPOCH FROM (now() - started_at)) / 86400.0
                     * COALESCE(v_sellprice, 0), 2)
        END
    WHERE tray_id = NEW.id AND ended_at IS NULL;
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_tray_stockout_event() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.handle_tray_stockout_event() TO service_role;

-- ── Trigger ──────────────────────────────────────────────────────────────────
-- DROP IF EXISTS for idempotency (project convention per CLAUDE.md migration notes).
DROP TRIGGER IF EXISTS zzz_tray_stockout_event ON public.machine_trays;
CREATE TRIGGER zzz_tray_stockout_event
  AFTER UPDATE OF current_stock ON public.machine_trays
  FOR EACH ROW EXECUTE FUNCTION public.handle_tray_stockout_event();
```

- [ ] **Step 2: Apply the migration**

```bash
cd Docker/supabase
supabase migration up
cd ../..
```

Expected: output contains `Applying migration 20260509000000_analytics_stockout_events.sql ... done` (or equivalent).

- [ ] **Step 3: Smoke-check via psql**

```bash
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres \
  -c "SELECT count(*) FROM information_schema.columns WHERE table_name='tray_stockout_events';" \
  -c "SELECT public.get_product_velocity_one('00000000-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 30);" \
  -c "SELECT tgname FROM pg_trigger WHERE tgname='zzz_tray_stockout_event';"
```

Expected:
- column count is 13 (id, tray_id, machine_id, item_number, product_id, started_at, ended_at, duration_seconds, lost_units_estimated, lost_revenue_estimated, velocity_at_close, company_id, created_at)
- velocity helper returns `0`
- trigger name `zzz_tray_stockout_event` is listed

- [ ] **Step 4: Run the trigger test — expect PASS**

```bash
bash Docker/supabase/tests/run-sql-tests.sh
```

Expected: `tray_stockout_event_trigger.test.sql` runner prints `Test 1.1 (open + close lifecycle) PASSED` (NOTICE) and `  PASS`. Other tests still pass. Script exits 0.

- [ ] **Step 5: Commit the migration**

```bash
git add Docker/supabase/migrations/20260509000000_analytics_stockout_events.sql
git commit -m "feat(analytics): add tray_stockout_events table + trigger

Tracks per-tray stockout periods for lost-revenue analytics. Trigger
opens an event on stock positive → 0 transition, closes on 0 →
positive, with a 5-minute clamp on lost-revenue estimate to absorb
admin miscount corrections. Includes get_product_velocity_one
helper (internal-only, REVOKE PUBLIC)."
```

### Task 1.3: Extend the trigger test — clamp + double-transition + unique-index

**Files:**
- Modify: `Docker/supabase/tests/tray_stockout_event_trigger.test.sql`

- [ ] **Step 1: Append three more `DO $$ … $$` blocks**

Append after the existing `END; $$;` (Test 1.1 block) but **before** the trailing `ROLLBACK;`:

```sql

-- ─── Test 1.2: < 5-min duration clamps loss to 0 ────────────────────────────
DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_machine   uuid := gen_random_uuid();
  v_product   uuid := gen_random_uuid();
  v_tray      uuid;
  v_event_id  uuid;
  v_lost_units numeric;
  v_lost_revenue numeric;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'ClampTestCo');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'clamp@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'clamp@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');
  INSERT INTO public.products (id, name, sellprice, company)
    VALUES (v_product, 'ClampSnack', 2.00, v_company);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine, 'ClampMachine', v_company);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine, 1, v_product, 10, 5)
    RETURNING id INTO v_tray;

  -- Seed velocity > 0 so math would produce nonzero loss without the clamp.
  -- (NOTE: the BEFORE-INSERT trigger on sales decrements machine_trays.current_stock,
  --  but the tray currently sits at 5, so it goes to 4; trigger fires on UPDATE OF
  --  current_stock — but 4 → 4 is no real change for the stockout trigger which
  --  only acts on positive ↔ 0 boundary, so this seed is safe.)
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine, 1, 2.00, 'cashless', now() - interval '1 day');

  -- Open
  UPDATE public.machine_trays SET current_stock = 0 WHERE id = v_tray;

  SELECT id INTO v_event_id
  FROM public.tray_stockout_events
  WHERE tray_id = v_tray AND ended_at IS NULL;

  -- Backdate to 2 minutes ago (well under the 5-min clamp)
  UPDATE public.tray_stockout_events
  SET started_at = now() - interval '2 minutes'
  WHERE id = v_event_id;

  -- Close
  UPDATE public.machine_trays SET current_stock = 4 WHERE id = v_tray;

  SELECT lost_units_estimated, lost_revenue_estimated
    INTO v_lost_units, v_lost_revenue
  FROM public.tray_stockout_events WHERE id = v_event_id;

  ASSERT v_lost_units = 0,
    format('clamp failed: lost_units should be 0, got %s', v_lost_units);
  ASSERT v_lost_revenue = 0,
    format('clamp failed: lost_revenue should be 0, got %s', v_lost_revenue);

  RAISE NOTICE 'Test 1.2 (< 5 min duration clamp) PASSED';
END;
$$;

-- ─── Test 1.3: 0 → positive → 0 within one DO block opens fresh event ───────
DO $$
DECLARE
  v_company    uuid := gen_random_uuid();
  v_user       uuid := gen_random_uuid();
  v_machine    uuid := gen_random_uuid();
  v_product    uuid := gen_random_uuid();
  v_tray       uuid;
  v_open_count int;
  v_total_count int;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'DoubleTestCo');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'dbl@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'dbl@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');
  INSERT INTO public.products (id, name, sellprice, company)
    VALUES (v_product, 'DblSnack', 1.00, v_company);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine, 'DblMachine', v_company);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine, 1, v_product, 10, 0)
    RETURNING id INTO v_tray;

  -- Stock starts at 0; bumping to positive runs the close branch but no open
  -- event exists → WHERE filter matches zero rows → silent no-op.
  UPDATE public.machine_trays SET current_stock = 5 WHERE id = v_tray;

  -- Drop back to 0 → open branch creates a fresh event.
  UPDATE public.machine_trays SET current_stock = 0 WHERE id = v_tray;

  SELECT count(*) INTO v_total_count
  FROM public.tray_stockout_events WHERE tray_id = v_tray;

  SELECT count(*) INTO v_open_count
  FROM public.tray_stockout_events WHERE tray_id = v_tray AND ended_at IS NULL;

  ASSERT v_total_count = 1,
    format('expected exactly 1 event total, got %s', v_total_count);
  ASSERT v_open_count = 1,
    format('expected 1 open event after final 0, got %s', v_open_count);

  RAISE NOTICE 'Test 1.3 (0 → positive → 0 within one DO block) PASSED';
END;
$$;

-- ─── Test 1.4: partial unique index rejects duplicate open event ────────────
-- Bypass RLS via service_role to test the index directly. Authenticated users
-- get only SELECT, so a direct duplicate-INSERT under their JWT would be RLS-
-- denied (no exception, just zero rows inserted) — not what we want to test.
DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_machine   uuid := gen_random_uuid();
  v_product   uuid := gen_random_uuid();
  v_tray      uuid;
  v_caught_sqlstate text := NULL;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'UniqueTestCo');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'u@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'u@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');
  INSERT INTO public.products (id, name, sellprice, company)
    VALUES (v_product, 'USnack', 1.00, v_company);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine, 'UMachine', v_company);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine, 1, v_product, 10, 5)
    RETURNING id INTO v_tray;

  -- Open one event via the trigger
  UPDATE public.machine_trays SET current_stock = 0 WHERE id = v_tray;

  -- Bypass RLS for the manual duplicate-INSERT test
  SET LOCAL ROLE postgres;

  BEGIN
    INSERT INTO public.tray_stockout_events
      (tray_id, machine_id, item_number, product_id, started_at, company_id)
    VALUES (v_tray, v_machine, 1, v_product, now(), v_company);
  EXCEPTION
    WHEN OTHERS THEN
      v_caught_sqlstate := SQLSTATE;
  END;

  RESET ROLE;

  ASSERT v_caught_sqlstate = '23505',
    format('expected unique_violation (23505), got %L', v_caught_sqlstate);

  RAISE NOTICE 'Test 1.4 (partial unique index blocks duplicate opens) PASSED';
END;
$$;
```

- [ ] **Step 2: Run the test suite — expect all four tests PASS**

```bash
bash Docker/supabase/tests/run-sql-tests.sh
```

Expected: NOTICE lines for Tests 1.1, 1.2, 1.3, 1.4 all appear; runner prints `  PASS`; script exits 0.

- [ ] **Step 3: Commit the extended tests**

```bash
git add Docker/supabase/tests/tray_stockout_event_trigger.test.sql
git commit -m "test(analytics): cover stockout 5-min clamp + double-transition + unique index"
```

### Task 1.4: Performance verification — 50-tray refill simulation

This is a verification task, not a code change. **No commit unless results require code changes.**

- [ ] **Step 1: Run the 50-tray simultaneous-refill perf check**

```bash
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_machine   uuid := gen_random_uuid();
  v_t0        timestamptz;
  v_t1        timestamptz;
  v_elapsed_ms numeric;
  v_tray_id   uuid;
  v_product_ids uuid[] := ARRAY[]::uuid[];
  v_product   uuid;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'PerfTestCo');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'perf@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'perf@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine, 'PerfMachine', v_company);

  -- 50 distinct products so the velocity helper genuinely re-computes per row
  FOR i IN 1..50 LOOP
    v_product := gen_random_uuid();
    v_product_ids := v_product_ids || v_product;
    INSERT INTO public.products (id, name, sellprice, company)
      VALUES (v_product, 'PerfSnack' || i, 1.00, v_company);
    INSERT INTO public.machine_trays
      (machine_id, item_number, product_id, capacity, current_stock)
      VALUES (v_machine, i, v_product, 10, 0)
      RETURNING id INTO v_tray_id;
    INSERT INTO public.tray_stockout_events
      (tray_id, machine_id, item_number, product_id, started_at, company_id)
      VALUES (v_tray_id, v_machine, i, v_product, now() - interval '1 hour', v_company);
  END LOOP;

  -- 30-day-deep sales history per product (one per day) for realistic velocity
  FOR i IN 1..50 LOOP
    FOR d IN 1..30 LOOP
      INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
        VALUES (v_machine, i, 1.00, 'cashless', now() - (d || ' days')::interval);
    END LOOP;
  END LOOP;

  -- Time the 50-tray simultaneous refill (one statement, 50 trigger invocations)
  v_t0 := clock_timestamp();
  UPDATE public.machine_trays SET current_stock = 5
    WHERE machine_id = v_machine;
  v_t1 := clock_timestamp();

  v_elapsed_ms := EXTRACT(EPOCH FROM (v_t1 - v_t0)) * 1000;
  RAISE NOTICE 'PERF: 50-tray refill trigger overhead: % ms', round(v_elapsed_ms, 2);

  IF v_elapsed_ms > 500 THEN
    RAISE WARNING 'PERF: 50-tray refill exceeded 500 ms budget (% ms) — surface to spec author for materialized-view escape hatch decision', v_elapsed_ms;
  END IF;
END;
$$;

ROLLBACK;
SQL
```

- [ ] **Step 2: Read the elapsed-ms NOTICE and decide**

Expected: NOTICE shows under 500 ms on a typical dev laptop. If the WARNING fires:
- Do NOT proceed silently
- Stop and surface to the spec author: "Phase 0 perf gate exceeded — please decide on materialized velocity view per spec §Risks"
- The spec explicitly classifies this as an out-of-spec change to be escalated

### Task 1.5: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add `tray_stockout_events` to the Tables list**

Open `CLAUDE.md`, find the line:
```
- `mdb_log` – MDB state-change diagnostics history per device
```

Add immediately after:
```
- `tray_stockout_events` – per-tray stockout history with lost-revenue estimates; trigger-managed (`zzz_tray_stockout_event` on `machine_trays.current_stock`); SELECT-only RLS for authenticated users; uses internal helper `get_product_velocity_one(company_id, product_id, days)` (SECURITY DEFINER, service_role-only, REVOKE PUBLIC)
```

(Helper is documented under the table that uses it, NOT in the user-facing "Key RPC functions" section — it's internal.)

- [ ] **Step 2: Commit docs update**

```bash
git add CLAUDE.md
git commit -m "docs: add tray_stockout_events to schema notes"
```

### Chunk 1 — Done When

- [ ] `bash Docker/supabase/tests/run-sql-tests.sh` exits 0 with PASS for both `get_product_detail_kpis.test.sql` and `tray_stockout_event_trigger.test.sql`
- [ ] All 4 NOTICE lines from `tray_stockout_event_trigger.test.sql` appear (Tests 1.1, 1.2, 1.3, 1.4 PASSED)
- [ ] 50-tray performance NOTICE shows < 500 ms (or surfaced to spec author per Task 1.4 step 2)
- [ ] CLAUDE.md updated and committed
- [ ] Four commits on the branch: failing test → migration → extended tests → docs

---

## Chunk 2: Phase 1 — Backend RPCs

**Goal:** Add `_analytics_filtered_sales` shared helper and the six analytics RPCs (`analytics_overview`, `analytics_sales_breakdown`, `analytics_products`, `analytics_machines`, `analytics_conversion`, `analytics_operations`). All RPCs share the filter signature, return `jsonb` with `version: 1`, are `SECURITY DEFINER` with `SET search_path = ''` and `SET statement_timeout = '10s'`, and validate `p_company_id = my_company_id()` at entry.

**Files:**
- Create: `Docker/supabase/migrations/20260509000100_analytics_rpcs.sql`
- Create: `Docker/supabase/tests/analytics_overview.test.sql` (template — full SQL)
- Create: `Docker/supabase/tests/analytics_sales_breakdown.test.sql`
- Create: `Docker/supabase/tests/analytics_products.test.sql`
- Create: `Docker/supabase/tests/analytics_machines.test.sql`
- Create: `Docker/supabase/tests/analytics_conversion.test.sql`
- Create: `Docker/supabase/tests/analytics_operations.test.sql`
- Modify: `CLAUDE.md`

**Pattern:** every test seeds two companies (company_a, company_b), one machine per company, ~5 sales per company spread across two products and two channels, then sets the JWT for company_a and asserts the RPC returns only company_a data with the correct shape and aggregation. The "RLS isolation" assertion is the key shared invariant across all six tests.

### Task 2.1: Write the canonical RPC test (analytics_overview) — full SQL

**Files:**
- Create: `Docker/supabase/tests/analytics_overview.test.sql`

- [ ] **Step 1: Write the test file**

```sql
-- Docker/supabase/tests/analytics_overview.test.sql
-- Integration test for analytics_overview RPC.
-- Verifies KPI math, period-comparison, top-products/machines, RLS isolation,
-- and version: 1 in response.

BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $$
DECLARE
  v_company_a uuid := gen_random_uuid();
  v_company_b uuid := gen_random_uuid();
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_machine_a uuid := gen_random_uuid();
  v_machine_b uuid := gen_random_uuid();
  v_product_1 uuid := gen_random_uuid();
  v_product_2 uuid := gen_random_uuid();
  v_result    jsonb;
  v_revenue   numeric;
  v_units     int;
  v_top_p_count int;
BEGIN
  -- Two companies
  INSERT INTO public.companies (id, name) VALUES (v_company_a, 'A');
  INSERT INTO public.companies (id, name) VALUES (v_company_b, 'B');

  -- Auth users
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_a, '00000000-0000-0000-0000-000000000000', 'a@t.local', now());
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_b, '00000000-0000-0000-0000-000000000000', 'b@t.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_a, v_company_a, 'a@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_b, v_company_b, 'b@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_a, v_user_a, 'admin'),
           (v_company_b, v_user_b, 'admin');

  -- Products + machines + trays
  INSERT INTO public.products (id, name, sellprice, company)
    VALUES (v_product_1, 'CokeA', 2.50, v_company_a),
           (v_product_2, 'PepsiA', 2.00, v_company_a);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine_a, 'MachA', v_company_a),
           (v_machine_b, 'MachB', v_company_b);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine_a, 1, v_product_1, 10, 8),
           (v_machine_a, 2, v_product_2, 10, 8);

  -- Sales for company_a within last 7 days
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine_a, 1, 2.50, 'cashless', now() - interval '1 day'),
           (v_machine_a, 1, 2.50, 'cashless', now() - interval '2 days'),
           (v_machine_a, 2, 2.00, 'cash',     now() - interval '3 days'),
           (v_machine_a, 2, 2.00, 'cashless', now() - interval '5 days'),
           (v_machine_a, 1, 2.50, 'cashless', now() - interval '6 days');

  -- One sale for company_b — must NOT appear in A's overview
  INSERT INTO public."vendingMachine" (id, name, company)
    SELECT v_machine_b, 'B-extra', v_company_b WHERE FALSE;  -- already inserted above
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine_b, 1, 99.00, 'cash', now() - interval '1 day');

  -- ─── Test 2.1.1: caller from company_a sees only A's data ─────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text,
    true);

  SELECT public.analytics_overview(
    v_company_a,
    now() - interval '7 days', now(),
    NULL, NULL,
    NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
  ) INTO v_result;

  ASSERT (v_result->>'version')::int = 1, 'version must be 1';

  v_revenue := (v_result->'kpis'->>'revenue')::numeric;
  v_units   := (v_result->'kpis'->>'units')::int;

  -- 5 sales × {2.50, 2.50, 2.00, 2.00, 2.50} = 11.50
  ASSERT v_revenue = 11.50,
    format('expected revenue=11.50 (company_a only), got %s', v_revenue);
  ASSERT v_units = 5,
    format('expected units=5 (company_a only), got %s', v_units);

  -- top_products: should contain v_product_1 (3 sales, 7.50) at top
  v_top_p_count := jsonb_array_length(v_result->'top_products');
  ASSERT v_top_p_count >= 1, 'top_products should be populated';
  ASSERT (v_result->'top_products'->0->>'product_id')::uuid = v_product_1,
    'expected v_product_1 at top of top_products by revenue';

  RAISE NOTICE 'Test 2.1.1 (overview KPIs + RLS isolation + top_products) PASSED';

  -- ─── Test 2.1.2: caller from company_b cannot read company_a data ─────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text,
    true);

  BEGIN
    SELECT public.analytics_overview(
      v_company_a,        -- ASKING for A while authenticated as B
      now() - interval '7 days', now(),
      NULL, NULL,
      NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
    ) INTO v_result;
    ASSERT FALSE, 'expected company-id mismatch to raise';
  EXCEPTION
    WHEN OTHERS THEN
      ASSERT SQLERRM ILIKE '%company%' OR SQLERRM ILIKE '%permission%' OR SQLERRM ILIKE '%not allowed%',
        format('expected company-mismatch error, got: %s', SQLERRM);
  END;

  RAISE NOTICE 'Test 2.1.2 (cross-company access denied) PASSED';
END;
$$;

ROLLBACK;
```

- [ ] **Step 2: Run — expect FAIL (function does not exist)**

```bash
bash Docker/supabase/tests/run-sql-tests.sh
```

Expected: `analytics_overview.test.sql` FAILs with `function public.analytics_overview(...) does not exist`.

- [ ] **Step 3: Commit**

```bash
git add Docker/supabase/tests/analytics_overview.test.sql
git commit -m "test(analytics): add failing test for analytics_overview RPC"
```

### Task 2.2: Write the five remaining RPC test files (template-driven)

Each file follows the same skeleton as Task 2.1 (two companies, sales seeding, JWT set, call RPC, assert shape + RLS isolation). Below is the **exact assertion checklist per file** — copy the seed scaffolding from `analytics_overview.test.sql` and adapt the assertions.

**Files:**
- Create: `Docker/supabase/tests/analytics_sales_breakdown.test.sql`
- Create: `Docker/supabase/tests/analytics_products.test.sql`
- Create: `Docker/supabase/tests/analytics_machines.test.sql`
- Create: `Docker/supabase/tests/analytics_conversion.test.sql`
- Create: `Docker/supabase/tests/analytics_operations.test.sql`

#### `analytics_sales_breakdown.test.sql` assertions
- Call with `p_dimension = 'machine'` → returns `rows` array with one entry per machine, `share_revenue_pct` summing to ~100 within the filter
- Call with `p_dimension = 'channel'` → returns one row per distinct channel (`cashless`, `cash`)
- Call with `p_dimension = 'hour'` → returns up to 24 rows keyed by hour-of-day
- Call with `p_dimension = 'dow'` → returns up to 7 rows keyed by day-of-week
- Call with invalid `p_dimension = 'foo'` → expect raise
- Cross-company isolation: caller from B asking for A → raise

#### `analytics_products.test.sql` assertions
- Returns `kpis.active_count`, `slow_mover_count`, `discontinued_count`, `categories_with_sales`
- `products[]` includes both seeded products with `velocity > 0`
- Product without recent sales gets `status = 'slow'` (configure seed to have no sales for one product in last 30 d)
- Product with `discontinued = true` gets `status = 'discontinued'`
- `mix_pct` sums to ~100 across all products
- RLS isolation

#### `analytics_machines.test.sql` assertions
- `kpis.best_machine_id` matches the machine with highest revenue
- `machines[]` excludes machines from other companies (RLS)
- `heatmaps[<machine_id>].dow` is a 7-element array, `.hour` is a 24-element array
- All heatmap cells are non-negative integers (counts)
- A machine with zero sales in the period appears in `machines[]` with `revenue = 0` (do NOT exclude empty machines — operator may want to see them)

#### `analytics_conversion.test.sql` assertions
- Seed includes `paxcounter` rows (`embedded_id`, `count`, `machine_id`)
- `kpis.footfall` = sum of paxcounter counts for the period
- `kpis.conversion_pct = ROUND(units * 100.0 / NULLIF(footfall, 0), 2)`
- `empty_passes = MAX(0, footfall - units)`
- A machine with `pax > 0` and `sales = 0` shows `conversion_pct = 0`, NOT NULL
- Period with `footfall = 0` returns `conversion_pct = NULL` or `0` (pick one — implementation choice — and document in spec follow-up)
- RLS isolation

#### `analytics_operations.test.sql` assertions
- Seed creates one closed `tray_stockout_events` row → appears in `stockout_events[]` with non-null `duration_seconds`, `lost_units_estimated`, `lost_revenue_estimated`
- Seed creates one open `tray_stockout_events` (no `ended_at`) → appears with `duration_seconds = NULL`, `lost_units_estimated = NULL`
- `kpis.stockout_hours` = sum of `duration_seconds / 3600.0` for closed events in period
- `kpis.lost_revenue` = sum of `lost_revenue_estimated` for closed events in period
- Seed creates `activity_log` rows with `metadata->>'tour_id'` populated → appears in `refill_tours[]` with the spec's full shape
- `stock_cover[]` includes one row per tray with `cover_days = ROUND(current_stock / NULLIF(velocity, 0), 1)` or NULL when velocity = 0
- RLS isolation

- [ ] **Step 1: Create all five files using the template + assertions above**

For each file, use this skeleton (adapt `<TEST_NAME>` and assertions):
```sql
BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $$
DECLARE
  v_company_a uuid := gen_random_uuid();
  v_company_b uuid := gen_random_uuid();
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  -- (machines, products, additional ids per test)
  v_result    jsonb;
BEGIN
  -- Seed two companies, users, machines, products, sales (copy from analytics_overview.test.sql)
  -- … plus test-specific seed (paxcounter for conversion, stockout events for operations, etc.)

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text,
    true);

  -- Call the RPC with full filter signature
  SELECT public.analytics_<NAME>(
    v_company_a,
    now() - interval '7 days', now(),
    NULL, NULL,
    NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
  ) INTO v_result;

  ASSERT (v_result->>'version')::int = 1, 'version must be 1';
  -- … RPC-specific assertions per checklist above

  RAISE NOTICE 'Test <TEST_NAME> PASSED';
END;
$$;

ROLLBACK;
```

- [ ] **Step 2: Run — expect ALL FIVE to FAIL (functions do not exist)**

```bash
bash Docker/supabase/tests/run-sql-tests.sh
```

Expected: 5 new FAILs (`function public.analytics_<NAME>(...) does not exist`).

- [ ] **Step 3: Commit the failing tests**

```bash
git add Docker/supabase/tests/analytics_*.test.sql
git commit -m "test(analytics): add failing tests for the five remaining analytics RPCs"
```

### Task 2.3: Write Migration 2 — full RPC implementation

> **Post-execution note (2026-05-09, commit `8dfd598`):** the SQL below contains three bugs caught during integration testing. The actually-deployed migration in `Docker/supabase/migrations/20260509000100_analytics_rpcs.sql` is corrected — diff against it before re-implementing. The bugs were:
> 1. `ROUND(SUM(s.item_price) / NULLIF(COUNT(*), 0), 2)` — `ROUND(float8, int)` doesn't exist in Postgres. Fixed by adding `::numeric` cast: `ROUND((SUM(s.item_price) / NULLIF(COUNT(*), 0))::numeric, 2)`. Same bug class as the 2026-04-11 tax-trigger prod outage.
> 2. `analytics_machines` heatmap returned 28 elements per `hour` array (instead of 24): the `LEFT JOIN cells c ON ... AND c.hour = gs.h` produced one row per matching cell (Mon@10, Tue@10, etc), so `array_agg` saw multiple values per hour. Fixed by introducing `cells_dow` and `cells_hour` CTEs that pre-aggregate per (machine, bucket) before the join.
> 3. `analytics_sales_breakdown`'s `jsonb_agg(jsonb_build_object(SUM(...)))` with same-level `GROUP BY` raised "aggregate function calls cannot be nested". Fixed by wrapping each of the 7 dimension branches in a subquery so `jsonb_agg` consumes plain rows post-GROUP-BY (matches the `analytics_overview.top_products` pattern that already worked).
>
> Plus a test-side bug: `analytics_operations.test.sql` seeded `activity_log` with default `created_at = now()`, which inside a `BEGIN/ROLLBACK` transaction equals the RPC's `p_to` value — the strict `created_at < p_to` filter then rejected the seed. Fixed by backdating `created_at = now() - interval '1 hour'` (commit `8dfd598` covers this too).

**Files:**
- Create: `Docker/supabase/migrations/20260509000100_analytics_rpcs.sql`

- [ ] **Step 1: Write the migration with helper + 6 RPCs**

```sql
-- Docker/supabase/migrations/20260509000100_analytics_rpcs.sql
-- Six analytics RPCs serving Web + iOS analytics. Shared filter signature,
-- jsonb response with version: 1. SECURITY DEFINER, statement_timeout 10s.
-- Internal helper _analytics_filtered_sales applies the WHERE clause.

-- ── Helper: filtered sales subquery ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._analytics_filtered_sales(p_filters jsonb)
RETURNS SETOF public.sales
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT s.*
  FROM public.sales s
  JOIN public."vendingMachine" vm ON vm.id = s.machine_id
  LEFT JOIN public.products p ON p.id = s.product_id
  WHERE vm.company = (p_filters->>'company_id')::uuid
    AND s.created_at >= (p_filters->>'from')::timestamptz
    AND s.created_at < (p_filters->>'to')::timestamptz
    AND (
      (p_filters->'machine_ids') IS NULL
      OR jsonb_array_length(p_filters->'machine_ids') = 0
      OR s.machine_id = ANY (
        SELECT (jsonb_array_elements_text(p_filters->'machine_ids'))::uuid
      )
    )
    AND (
      (p_filters->'channels') IS NULL
      OR jsonb_array_length(p_filters->'channels') = 0
      OR s.channel = ANY (
        SELECT jsonb_array_elements_text(p_filters->'channels')
      )
    )
    AND (
      (p_filters->'category_ids') IS NULL
      OR jsonb_array_length(p_filters->'category_ids') = 0
      OR p.category = ANY (
        SELECT (jsonb_array_elements_text(p_filters->'category_ids'))::uuid
      )
    )
    AND (
      (p_filters->'vat_rates') IS NULL
      OR jsonb_array_length(p_filters->'vat_rates') = 0
      OR (s.tax_rate_snapshot IS NOT NULL
          AND s.tax_rate_snapshot = ANY (
            SELECT (jsonb_array_elements_text(p_filters->'vat_rates'))::numeric
          ))
    );
$$;

REVOKE ALL ON FUNCTION public._analytics_filtered_sales(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._analytics_filtered_sales(jsonb) TO service_role;

-- Internal helper to build the filter jsonb consistently from the public-RPC
-- parameter list. Keeps every RPC's filter-construction call site identical.
CREATE OR REPLACE FUNCTION public._analytics_build_filters(
  p_company_id uuid, p_from timestamptz, p_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'company_id', p_company_id,
    'from',       p_from,
    'to',         p_to,
    'machine_ids', COALESCE(to_jsonb(p_machine_ids),  '[]'::jsonb),
    'channels',    COALESCE(to_jsonb(p_channels),     '[]'::jsonb),
    'category_ids',COALESCE(to_jsonb(p_category_ids), '[]'::jsonb),
    'vat_rates',   COALESCE(to_jsonb(p_vat_rates),    '[]'::jsonb)
  );
$$;

-- ── Common entry-guard ───────────────────────────────────────────────────────
-- Each RPC validates p_company_id matches the caller's company; raises on
-- mismatch with a deterministic SQLSTATE so cross-company tests can detect it.

-- ── analytics_overview ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_overview(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters       jsonb;
  v_filters_cmp   jsonb;
  v_kpis          jsonb;
  v_kpis_cmp      jsonb;
  v_daily_series  jsonb;
  v_top_products  jsonb;
  v_top_machines  jsonb;
  v_pax_count     bigint;
  v_pax_count_cmp bigint;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch or no company';
  END IF;

  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to,
    p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  -- Pax counts mirror the same machine/time filter (channels/categories don't apply)
  SELECT COALESCE(SUM(p.count), 0) INTO v_pax_count
  FROM public.paxcounter p
  JOIN public."vendingMachine" vm ON vm.id = p.machine_id
  WHERE vm.company = p_company_id
    AND p.created_at >= p_from AND p.created_at < p_to
    AND (
      cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0
      OR p.machine_id = ANY (p_machine_ids)
    );

  -- KPIs current period
  SELECT jsonb_build_object(
    'revenue',        ROUND(COALESCE(SUM(item_price), 0)::numeric, 2),
    'units',          COUNT(*),
    'avg_basket',     ROUND(COALESCE(SUM(item_price) / NULLIF(COUNT(*), 0), 0)::numeric, 2),
    'conversion_pct', ROUND((COUNT(*) * 100.0 / NULLIF(v_pax_count, 0))::numeric, 2)
  )
  INTO v_kpis
  FROM public._analytics_filtered_sales(v_filters);

  -- KPIs comparison period (if provided)
  IF p_compare_from IS NOT NULL AND p_compare_to IS NOT NULL THEN
    v_filters_cmp := public._analytics_build_filters(
      p_company_id, p_compare_from, p_compare_to,
      p_machine_ids, p_channels, p_category_ids, p_vat_rates
    );

    SELECT COALESCE(SUM(p.count), 0) INTO v_pax_count_cmp
    FROM public.paxcounter p
    JOIN public."vendingMachine" vm ON vm.id = p.machine_id
    WHERE vm.company = p_company_id
      AND p.created_at >= p_compare_from AND p.created_at < p_compare_to;

    SELECT jsonb_build_object(
      'revenue',        ROUND(COALESCE(SUM(item_price), 0)::numeric, 2),
      'units',          COUNT(*),
      'avg_basket',     ROUND(COALESCE(SUM(item_price) / NULLIF(COUNT(*), 0), 0)::numeric, 2),
      'conversion_pct', ROUND((COUNT(*) * 100.0 / NULLIF(v_pax_count_cmp, 0))::numeric, 2)
    )
    INTO v_kpis_cmp
    FROM public._analytics_filtered_sales(v_filters_cmp);
  ELSE
    v_kpis_cmp := NULL;
  END IF;

  -- Daily series
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date',    d.date,
    'revenue', d.rev,
    'units',   d.cnt
  ) ORDER BY d.date), '[]'::jsonb)
  INTO v_daily_series
  FROM (
    SELECT date_trunc('day', created_at)::date AS date,
           ROUND(SUM(item_price)::numeric, 2)  AS rev,
           COUNT(*)                            AS cnt
    FROM public._analytics_filtered_sales(v_filters)
    GROUP BY 1
  ) d;

  -- Top 5 products
  SELECT COALESCE(jsonb_agg(row ORDER BY (row->>'revenue')::numeric DESC), '[]'::jsonb)
  INTO v_top_products
  FROM (
    SELECT jsonb_build_object(
      'product_id', p.id,
      'name',       p.name,
      'image_path', p.image_path,
      'units',      COUNT(*),
      'revenue',    ROUND(SUM(s.item_price)::numeric, 2),
      'mix_pct',    ROUND((SUM(s.item_price) * 100.0 / NULLIF(
                      (SELECT SUM(item_price) FROM public._analytics_filtered_sales(v_filters)),
                      0))::numeric, 2)
    ) AS row
    FROM public._analytics_filtered_sales(v_filters) s
    JOIN public.products p ON p.id = s.product_id
    GROUP BY p.id, p.name, p.image_path
    ORDER BY SUM(s.item_price) DESC
    LIMIT 5
  ) sub;

  -- Top 5 machines
  SELECT COALESCE(jsonb_agg(row ORDER BY (row->>'revenue')::numeric DESC), '[]'::jsonb)
  INTO v_top_machines
  FROM (
    SELECT jsonb_build_object(
      'machine_id',     vm.id,
      'name',           vm.name,
      'status',         e.status,
      'revenue',        ROUND(SUM(s.item_price)::numeric, 2),
      'conversion_pct', NULL  -- per-machine pax→sales lives in analytics_machines/conversion
    ) AS row
    FROM public._analytics_filtered_sales(v_filters) s
    JOIN public."vendingMachine" vm ON vm.id = s.machine_id
    LEFT JOIN public.embeddeds e ON e.id = vm.embedded
    GROUP BY vm.id, vm.name, e.status
    ORDER BY SUM(s.item_price) DESC
    LIMIT 5
  ) sub;

  RETURN jsonb_build_object(
    'version',       1,
    'kpis',          v_kpis,
    'kpis_compare',  v_kpis_cmp,
    'daily_series',  v_daily_series,
    'top_products',  v_top_products,
    'top_machines',  v_top_machines
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_overview(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_overview(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;

-- ── analytics_sales_breakdown ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_sales_breakdown(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[],
  p_dimension text
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters jsonb;
  v_total_revenue numeric;
  v_total_units bigint;
  v_rows jsonb;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;
  IF p_dimension NOT IN ('machine','product','category','channel','vat','hour','dow') THEN
    RAISE EXCEPTION 'analytics_sales_breakdown: invalid dimension %', p_dimension;
  END IF;

  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to,
    p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  -- Filtered totals (denominator for share_*_pct)
  SELECT COALESCE(SUM(item_price), 0), COUNT(*)
  INTO v_total_revenue, v_total_units
  FROM public._analytics_filtered_sales(v_filters);

  -- Build rows depending on dimension. Each branch produces the same row shape.
  IF p_dimension = 'machine' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'key',                vm.id,
      'label',              vm.name,
      'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
      'units',              COUNT(*),
      'avg_basket',         ROUND(SUM(s.item_price) / NULLIF(COUNT(*), 0), 2),
      'count',              COUNT(*),
      'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
      'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
    ) ORDER BY SUM(s.item_price) DESC), '[]'::jsonb)
    INTO v_rows
    FROM public._analytics_filtered_sales(v_filters) s
    JOIN public."vendingMachine" vm ON vm.id = s.machine_id
    GROUP BY vm.id, vm.name;
  ELSIF p_dimension = 'product' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'key',                p.id,
      'label',              p.name,
      'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
      'units',              COUNT(*),
      'avg_basket',         ROUND(SUM(s.item_price) / NULLIF(COUNT(*), 0), 2),
      'count',              COUNT(*),
      'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
      'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
    ) ORDER BY SUM(s.item_price) DESC), '[]'::jsonb)
    INTO v_rows
    FROM public._analytics_filtered_sales(v_filters) s
    LEFT JOIN public.products p ON p.id = s.product_id
    GROUP BY p.id, p.name;
  ELSIF p_dimension = 'category' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'key',                c.id,
      'label',              c.name,
      'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
      'units',              COUNT(*),
      'avg_basket',         ROUND(SUM(s.item_price) / NULLIF(COUNT(*), 0), 2),
      'count',              COUNT(*),
      'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
      'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
    ) ORDER BY SUM(s.item_price) DESC), '[]'::jsonb)
    INTO v_rows
    FROM public._analytics_filtered_sales(v_filters) s
    LEFT JOIN public.products p ON p.id = s.product_id
    LEFT JOIN public.product_category c ON c.id = p.category
    GROUP BY c.id, c.name;
  ELSIF p_dimension = 'channel' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'key',                s.channel,
      'label',              s.channel,
      'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
      'units',              COUNT(*),
      'avg_basket',         ROUND(SUM(s.item_price) / NULLIF(COUNT(*), 0), 2),
      'count',              COUNT(*),
      'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
      'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
    )), '[]'::jsonb)
    INTO v_rows
    FROM public._analytics_filtered_sales(v_filters) s
    GROUP BY s.channel;
  ELSIF p_dimension = 'vat' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'key',                s.tax_rate_snapshot::text,
      'label',              ROUND(s.tax_rate_snapshot * 100, 2)::text || '%',
      'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
      'units',              COUNT(*),
      'avg_basket',         ROUND(SUM(s.item_price) / NULLIF(COUNT(*), 0), 2),
      'count',              COUNT(*),
      'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
      'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
    )), '[]'::jsonb)
    INTO v_rows
    FROM public._analytics_filtered_sales(v_filters) s
    WHERE s.tax_rate_snapshot IS NOT NULL
    GROUP BY s.tax_rate_snapshot;
  ELSIF p_dimension = 'hour' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'key',                EXTRACT(HOUR FROM s.created_at)::int,
      'label',              LPAD(EXTRACT(HOUR FROM s.created_at)::text, 2, '0') || ':00',
      'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
      'units',              COUNT(*),
      'avg_basket',         ROUND(SUM(s.item_price) / NULLIF(COUNT(*), 0), 2),
      'count',              COUNT(*),
      'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
      'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
    ) ORDER BY EXTRACT(HOUR FROM s.created_at)), '[]'::jsonb)
    INTO v_rows
    FROM public._analytics_filtered_sales(v_filters) s
    GROUP BY EXTRACT(HOUR FROM s.created_at);
  ELSIF p_dimension = 'dow' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'key',                EXTRACT(ISODOW FROM s.created_at)::int,
      'label',              to_char(s.created_at, 'Dy'),
      'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
      'units',              COUNT(*),
      'avg_basket',         ROUND(SUM(s.item_price) / NULLIF(COUNT(*), 0), 2),
      'count',              COUNT(*),
      'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
      'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
    ) ORDER BY EXTRACT(ISODOW FROM s.created_at)), '[]'::jsonb)
    INTO v_rows
    FROM public._analytics_filtered_sales(v_filters) s
    GROUP BY EXTRACT(ISODOW FROM s.created_at), to_char(s.created_at, 'Dy');
  END IF;

  RETURN jsonb_build_object(
    'version',   1,
    'dimension', p_dimension,
    'rows',      v_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_sales_breakdown(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_sales_breakdown(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[], text) TO authenticated;

-- ── analytics_products ───────────────────────────────────────────────────────
-- Returns per-product velocity, revenue, mix-share, status (active/slow/dead/discontinued).
-- Uses get_product_sales_velocity (existing) for batch velocity, computes per-product
-- "last sold at" timestamp for slow-mover classification (no sale in 30 days = slow).

CREATE OR REPLACE FUNCTION public.analytics_products(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters     jsonb;
  v_total_rev   numeric;
  v_kpis        jsonb;
  v_products    jsonb;
  v_mix_shift   jsonb;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;

  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to, p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  SELECT COALESCE(SUM(item_price), 0) INTO v_total_rev
  FROM public._analytics_filtered_sales(v_filters);

  SELECT jsonb_build_object(
    'active_count',         (SELECT COUNT(*) FROM public.products WHERE company = p_company_id AND COALESCE(discontinued, false) = false),
    'slow_mover_count',     (
      SELECT COUNT(*) FROM public.products p
      WHERE p.company = p_company_id
        AND COALESCE(p.discontinued, false) = false
        AND NOT EXISTS (
          SELECT 1 FROM public.sales s
          JOIN public."vendingMachine" vm ON vm.id = s.machine_id
          WHERE vm.company = p_company_id
            AND s.product_id = p.id
            AND s.created_at >= now() - interval '30 days'
        )
    ),
    'discontinued_count',   (SELECT COUNT(*) FROM public.products WHERE company = p_company_id AND discontinued = true),
    'categories_with_sales',(
      SELECT COUNT(DISTINCT p.category)
      FROM public._analytics_filtered_sales(v_filters) s
      JOIN public.products p ON p.id = s.product_id
      WHERE p.category IS NOT NULL
    )
  ) INTO v_kpis;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',              p.id,
    'name',            p.name,
    'image_path',      p.image_path,
    'category_id',     p.category,           -- alias intentional (see plan header)
    'velocity',        ROUND(COALESCE(stats.units::numeric / NULLIF(EXTRACT(EPOCH FROM (p_to - p_from))/86400.0, 0), 0), 3),
    'units',           COALESCE(stats.units, 0),
    'revenue',         ROUND(COALESCE(stats.revenue, 0)::numeric, 2),
    'mix_pct',         ROUND((COALESCE(stats.revenue, 0) * 100.0 / NULLIF(v_total_rev, 0))::numeric, 2),
    'vat_rate',        stats.vat_rate,
    'last_sold_at',    stats.last_sold_at,
    'status',          CASE
      WHEN COALESCE(p.discontinued, false) THEN 'discontinued'
      WHEN stats.units IS NULL OR stats.units = 0 THEN 'dead'
      WHEN stats.last_sold_at < now() - interval '30 days' THEN 'slow'
      ELSE 'active'
    END,
    'slow_mover_days', GREATEST(0, EXTRACT(DAY FROM (now() - COALESCE(stats.last_sold_at, p.created_at)))::int)
  ) ORDER BY COALESCE(stats.revenue, 0) DESC), '[]'::jsonb)
  INTO v_products
  FROM public.products p
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS units,
           SUM(s.item_price) AS revenue,
           MAX(s.created_at) AS last_sold_at,
           AVG(s.tax_rate_snapshot)::numeric(6,4) AS vat_rate
    FROM public._analytics_filtered_sales(v_filters) s
    WHERE s.product_id = p.id
  ) stats ON true
  WHERE p.company = p_company_id;

  -- Mix-shift series: daily revenue per category over the period
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date',        d.date,
    'category_id', d.category_id,
    'revenue',     d.rev
  ) ORDER BY d.date, d.category_id), '[]'::jsonb)
  INTO v_mix_shift
  FROM (
    SELECT date_trunc('day', s.created_at)::date AS date,
           p.category AS category_id,
           ROUND(SUM(s.item_price)::numeric, 2) AS rev
    FROM public._analytics_filtered_sales(v_filters) s
    LEFT JOIN public.products p ON p.id = s.product_id
    GROUP BY 1, 2
  ) d;

  RETURN jsonb_build_object(
    'version',          1,
    'kpis',             v_kpis,
    'products',         v_products,
    'mix_shift_series', v_mix_shift
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_products(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_products(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;

-- ── analytics_machines ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_machines(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters    jsonb;
  v_kpis       jsonb;
  v_machines   jsonb;
  v_heatmaps   jsonb;
  v_stockout_h numeric;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;
  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to, p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  SELECT COALESCE(SUM(duration_seconds), 0) / 3600.0 INTO v_stockout_h
  FROM public.tray_stockout_events
  WHERE company_id = p_company_id
    AND started_at >= p_from AND started_at < p_to
    AND ended_at IS NOT NULL;

  WITH per_machine AS (
    SELECT vm.id, vm.name, vm.location_lat AS lat, vm.location_lon AS lng, e.status, e.online_since,
           COALESCE(SUM(s.item_price), 0) AS revenue,
           COUNT(s.id) AS units,
           MAX(s.created_at) AS last_sold_at
    FROM public."vendingMachine" vm
    LEFT JOIN public.embeddeds e ON e.id = vm.embedded
    LEFT JOIN public._analytics_filtered_sales(v_filters) s ON s.machine_id = vm.id
    WHERE vm.company = p_company_id
      AND (cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0 OR vm.id = ANY (p_machine_ids))
    GROUP BY vm.id, vm.name, vm.location_lat, vm.location_lon, e.status, e.online_since
  ),
  pax_per_machine AS (
    SELECT p.machine_id,
           COALESCE(SUM(p.count), 0) AS pax_count
    FROM public.paxcounter p
    JOIN public."vendingMachine" vm ON vm.id = p.machine_id
    WHERE vm.company = p_company_id
      AND p.created_at >= p_from AND p.created_at < p_to
    GROUP BY p.machine_id
  )
  SELECT jsonb_build_object(
    'active_count',       (SELECT COUNT(*) FROM per_machine),
    'best_machine_id',    (SELECT id FROM per_machine ORDER BY revenue DESC LIMIT 1),
    'best_machine_name',  (SELECT name FROM per_machine ORDER BY revenue DESC LIMIT 1),
    'best_revenue',       (SELECT ROUND(revenue::numeric, 2) FROM per_machine ORDER BY revenue DESC LIMIT 1),
    'avg_conversion_pct', (SELECT ROUND(AVG(
                              CASE WHEN COALESCE(pp.pax_count, 0) > 0
                                THEN pm.units * 100.0 / pp.pax_count
                                ELSE NULL END
                            )::numeric, 2)
                          FROM per_machine pm LEFT JOIN pax_per_machine pp ON pp.machine_id = pm.id),
    'total_stockout_hours', ROUND(v_stockout_h::numeric, 2)
  ) INTO v_kpis
  FROM (SELECT 1) _; -- dummy to allow CTEs

  -- machines[]
  WITH per_machine AS (
    SELECT vm.id, vm.name, vm.location_lat AS lat, vm.location_lon AS lng, e.status, e.online_since,
           COALESCE(SUM(s.item_price), 0) AS revenue,
           COUNT(s.id) AS units,
           MAX(s.created_at) AS last_sold_at
    FROM public."vendingMachine" vm
    LEFT JOIN public.embeddeds e ON e.id = vm.embedded
    LEFT JOIN public._analytics_filtered_sales(v_filters) s ON s.machine_id = vm.id
    WHERE vm.company = p_company_id
      AND (cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0 OR vm.id = ANY (p_machine_ids))
    GROUP BY vm.id, vm.name, vm.location_lat, vm.location_lon, e.status, e.online_since
  ),
  pax_per_machine AS (
    SELECT p.machine_id, COALESCE(SUM(p.count), 0) AS pax_count
    FROM public.paxcounter p
    JOIN public."vendingMachine" vm ON vm.id = p.machine_id
    WHERE vm.company = p_company_id
      AND p.created_at >= p_from AND p.created_at < p_to
    GROUP BY p.machine_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                   pm.id,
    'name',                 pm.name,
    'lat',                  pm.lat,
    'lng',                  pm.lng,
    'status',               pm.status,
    'revenue',              ROUND(pm.revenue::numeric, 2),
    'units',                pm.units,
    'conversion_pct',       CASE WHEN COALESCE(pp.pax_count, 0) > 0
                              THEN ROUND((pm.units * 100.0 / pp.pax_count)::numeric, 2)
                              ELSE NULL END,
    'last_sale_gap_minutes', CASE WHEN pm.last_sold_at IS NOT NULL
                              THEN EXTRACT(EPOCH FROM (now() - pm.last_sold_at))::int / 60
                              ELSE NULL END,
    'stock_health',         NULL,  -- computed client-side from machine_trays via existing component
    'current_online',       (pm.status IS NOT NULL AND pm.status <> 'offline')
  ) ORDER BY pm.revenue DESC), '[]'::jsonb)
  INTO v_machines
  FROM per_machine pm
  LEFT JOIN pax_per_machine pp ON pp.machine_id = pm.id;

  -- heatmaps: cells = sales count
  WITH cells AS (
    SELECT s.machine_id,
           EXTRACT(ISODOW FROM s.created_at)::int AS dow,    -- 1=Mon..7=Sun
           EXTRACT(HOUR   FROM s.created_at)::int AS hour,
           COUNT(*) AS cnt
    FROM public._analytics_filtered_sales(v_filters) s
    GROUP BY 1, 2, 3
  )
  SELECT COALESCE(jsonb_object_agg(
    machine_id::text,
    jsonb_build_object(
      'dow',  (SELECT array_agg(COALESCE(c.cnt, 0) ORDER BY d) FROM (SELECT generate_series(1,7) AS d) gs LEFT JOIN cells c ON c.machine_id = m.machine_id AND c.dow = gs.d),
      'hour', (SELECT array_agg(COALESCE(c.cnt, 0) ORDER BY h) FROM (SELECT generate_series(0,23) AS h) gs LEFT JOIN cells c ON c.machine_id = m.machine_id AND c.hour = gs.h)
    )
  ), '{}'::jsonb)
  INTO v_heatmaps
  FROM (SELECT DISTINCT machine_id FROM cells) m;

  RETURN jsonb_build_object(
    'version',  1,
    'kpis',     v_kpis,
    'machines', v_machines,
    'heatmaps', v_heatmaps
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_machines(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_machines(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;

-- ── analytics_conversion ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_conversion(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters       jsonb;
  v_kpis          jsonb;
  v_machines      jsonb;
  v_hour_heatmap  jsonb;
  v_daily_series  jsonb;
  v_total_pax     bigint;
  v_total_units   bigint;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;
  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to, p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  SELECT COALESCE(SUM(p.count), 0) INTO v_total_pax
  FROM public.paxcounter p
  JOIN public."vendingMachine" vm ON vm.id = p.machine_id
  WHERE vm.company = p_company_id
    AND p.created_at >= p_from AND p.created_at < p_to
    AND (cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0 OR p.machine_id = ANY (p_machine_ids));

  SELECT COUNT(*) INTO v_total_units
  FROM public._analytics_filtered_sales(v_filters);

  SELECT jsonb_build_object(
    'footfall',         v_total_pax,
    'conversion_pct',   ROUND((v_total_units * 100.0 / NULLIF(v_total_pax, 0))::numeric, 2),
    'best_machine_id',  (
      SELECT pm.id FROM (
        SELECT vm.id,
               (COUNT(s.id) * 100.0 / NULLIF(COALESCE(SUM(p.count), 0), 0)) AS conv
        FROM public."vendingMachine" vm
        LEFT JOIN public._analytics_filtered_sales(v_filters) s ON s.machine_id = vm.id
        LEFT JOIN public.paxcounter p ON p.machine_id = vm.id
          AND p.created_at >= p_from AND p.created_at < p_to
        WHERE vm.company = p_company_id
        GROUP BY vm.id
      ) pm
      ORDER BY conv DESC NULLS LAST LIMIT 1
    ),
    'empty_passes',     GREATEST(0, v_total_pax - v_total_units)
  ) INTO v_kpis;

  -- Per-machine conversion table
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                   vm.id,
    'name',                 vm.name,
    'pax',                  COALESCE(pp.pax_count, 0),
    'sales',                COALESCE(sp.unit_count, 0),
    'conversion_pct',       CASE WHEN COALESCE(pp.pax_count, 0) > 0
                              THEN ROUND((COALESCE(sp.unit_count, 0) * 100.0 / pp.pax_count)::numeric, 2)
                              ELSE 0 END,
    'revenue_per_visitor',  CASE WHEN COALESCE(pp.pax_count, 0) > 0
                              THEN ROUND((COALESCE(sp.revenue, 0) / pp.pax_count)::numeric, 2)
                              ELSE NULL END
  ) ORDER BY vm.name), '[]'::jsonb)
  INTO v_machines
  FROM public."vendingMachine" vm
  LEFT JOIN (
    SELECT s.machine_id, COUNT(*) AS unit_count, SUM(s.item_price) AS revenue
    FROM public._analytics_filtered_sales(v_filters) s
    GROUP BY s.machine_id
  ) sp ON sp.machine_id = vm.id
  LEFT JOIN (
    SELECT p.machine_id, SUM(p.count) AS pax_count
    FROM public.paxcounter p
    WHERE p.created_at >= p_from AND p.created_at < p_to
    GROUP BY p.machine_id
  ) pp ON pp.machine_id = vm.id
  WHERE vm.company = p_company_id
    AND (cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0 OR vm.id = ANY (p_machine_ids));

  -- hour_heatmap: machine_id → 24-element array of conversion_pct per hour
  WITH pax_h AS (
    SELECT p.machine_id, EXTRACT(HOUR FROM p.created_at)::int AS h, SUM(p.count) AS pax_count
    FROM public.paxcounter p JOIN public."vendingMachine" vm ON vm.id = p.machine_id
    WHERE vm.company = p_company_id AND p.created_at >= p_from AND p.created_at < p_to
    GROUP BY 1, 2
  ),
  sales_h AS (
    SELECT s.machine_id, EXTRACT(HOUR FROM s.created_at)::int AS h, COUNT(*) AS unit_count
    FROM public._analytics_filtered_sales(v_filters) s
    GROUP BY 1, 2
  )
  SELECT COALESCE(jsonb_object_agg(
    m.id::text,
    (SELECT array_agg(
       CASE WHEN COALESCE(ph.pax_count, 0) > 0
         THEN ROUND((COALESCE(sh.unit_count, 0) * 100.0 / ph.pax_count)::numeric, 2)
         ELSE NULL END
       ORDER BY hours.h
     )
     FROM (SELECT generate_series(0, 23) AS h) hours
     LEFT JOIN pax_h ph ON ph.machine_id = m.id AND ph.h = hours.h
     LEFT JOIN sales_h sh ON sh.machine_id = m.id AND sh.h = hours.h
    )
  ), '{}'::jsonb)
  INTO v_hour_heatmap
  FROM public."vendingMachine" m
  WHERE m.company = p_company_id;

  -- daily series
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date',           d.date,
    'conversion_pct', CASE WHEN COALESCE(d.pax, 0) > 0
                        THEN ROUND((d.units * 100.0 / d.pax)::numeric, 2)
                        ELSE NULL END
  ) ORDER BY d.date), '[]'::jsonb)
  INTO v_daily_series
  FROM (
    SELECT all_days.d AS date,
           COALESCE(SUM(p.count), 0) AS pax,
           COALESCE((SELECT COUNT(*) FROM public._analytics_filtered_sales(v_filters) s
                     WHERE date_trunc('day', s.created_at) = all_days.d), 0) AS units
    FROM (
      SELECT generate_series(date_trunc('day', p_from), date_trunc('day', p_to), interval '1 day')::date AS d
    ) all_days
    LEFT JOIN public.paxcounter p
      ON date_trunc('day', p.created_at)::date = all_days.d
    LEFT JOIN public."vendingMachine" vm ON vm.id = p.machine_id AND vm.company = p_company_id
    GROUP BY all_days.d
  ) d;

  RETURN jsonb_build_object(
    'version',                1,
    'kpis',                   v_kpis,
    'machines',               v_machines,
    'hour_heatmap',           v_hour_heatmap,
    'daily_conversion_series', v_daily_series
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_conversion(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_conversion(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;

-- ── analytics_operations ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_operations(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_kpis           jsonb;
  v_stockouts      jsonb;
  v_refill_tours   jsonb;
  v_stock_cover    jsonb;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;

  -- KPIs
  SELECT jsonb_build_object(
    'stockout_hours',     ROUND((COALESCE((SELECT SUM(duration_seconds) FROM public.tray_stockout_events
                                          WHERE company_id = p_company_id
                                            AND started_at >= p_from AND started_at < p_to
                                            AND ended_at IS NOT NULL), 0) / 3600.0)::numeric, 2),
    'lost_revenue',       ROUND(COALESCE((SELECT SUM(lost_revenue_estimated) FROM public.tray_stockout_events
                                          WHERE company_id = p_company_id
                                            AND started_at >= p_from AND started_at < p_to
                                            AND ended_at IS NOT NULL), 0)::numeric, 2),
    'refill_tour_count',  (SELECT COUNT(DISTINCT metadata->>'tour_id')
                           FROM public.activity_log
                           WHERE company_id = p_company_id
                             AND created_at >= p_from AND created_at < p_to
                             AND metadata->>'tour_id' IS NOT NULL),
    'avg_stock_cover_days', (
      SELECT ROUND(AVG(NULLIF(mt.current_stock, 0)::numeric / NULLIF(public.get_product_velocity_one(p_company_id, mt.product_id, 30), 0))::numeric, 1)
      FROM public.machine_trays mt
      JOIN public."vendingMachine" vm ON vm.id = mt.machine_id
      WHERE vm.company = p_company_id
    )
  ) INTO v_kpis;

  -- stockout_events[]
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                     e.id,
    'machine_id',             e.machine_id,
    'machine_name',           vm.name,
    'tray_id',                e.tray_id,
    'item_number',            e.item_number,
    'product_id',             e.product_id,
    'product_name',           p.name,
    'started_at',             e.started_at,
    'ended_at',               e.ended_at,
    'duration_seconds',       e.duration_seconds,
    'lost_units_estimated',   e.lost_units_estimated,
    'lost_revenue_estimated', e.lost_revenue_estimated
  ) ORDER BY e.lost_revenue_estimated DESC NULLS LAST), '[]'::jsonb)
  INTO v_stockouts
  FROM public.tray_stockout_events e
  LEFT JOIN public."vendingMachine" vm ON vm.id = e.machine_id
  LEFT JOIN public.products p ON p.id = e.product_id
  WHERE e.company_id = p_company_id
    AND e.started_at >= p_from AND e.started_at < p_to;

  -- refill_tours[] — group activity_log rows by tour_id (10-min fallback bucketing
  -- intentionally NOT replicated server-side — clients pre-V2 used metadata->>'tour_id'
  -- consistently; if needed, add a CASE WHEN tour_id IS NULL THEN time-bucket-id ELSE tour_id END)
  SELECT COALESCE(jsonb_agg(t ORDER BY (t->>'started_at')::timestamptz DESC), '[]'::jsonb)
  INTO v_refill_tours
  FROM (
    SELECT jsonb_build_object(
      'tour_id',          metadata->>'tour_id',
      'started_at',       MIN(created_at),
      'ended_at',         MAX(created_at),
      'duration_minutes', GREATEST(1, EXTRACT(EPOCH FROM (MAX(created_at) - MIN(created_at)))::int / 60),
      'user_display',     (metadata->'_user_display')::text,
      'machines_count',   COUNT(DISTINCT (metadata->>'machine_id')),
      'units_added',      SUM((metadata->>'units_added')::int),
      'machines',         jsonb_agg(jsonb_build_object(
                            'machine_id',   metadata->>'machine_id',
                            'machine_name', metadata->>'machine_name',
                            'items_added',  (metadata->>'units_added')::int
                          ))
    ) AS t
    FROM public.activity_log
    WHERE company_id = p_company_id
      AND created_at >= p_from AND created_at < p_to
      AND metadata->>'tour_id' IS NOT NULL
    GROUP BY metadata->>'tour_id', metadata->'_user_display'
  ) tours;

  -- stock_cover[]
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tray_id',       mt.id,
    'machine_id',    mt.machine_id,
    'machine_name',  vm.name,
    'item_number',   mt.item_number,
    'product_id',    mt.product_id,
    'product_name',  p.name,
    'current_stock', mt.current_stock,
    'velocity',      ROUND(public.get_product_velocity_one(p_company_id, mt.product_id, 30)::numeric, 3),
    'cover_days',    CASE
      WHEN public.get_product_velocity_one(p_company_id, mt.product_id, 30) > 0
        THEN ROUND((mt.current_stock / public.get_product_velocity_one(p_company_id, mt.product_id, 30))::numeric, 1)
      ELSE NULL END
  ) ORDER BY (
    CASE WHEN public.get_product_velocity_one(p_company_id, mt.product_id, 30) > 0
      THEN mt.current_stock / public.get_product_velocity_one(p_company_id, mt.product_id, 30)
      ELSE 999999 END
  )), '[]'::jsonb)
  INTO v_stock_cover
  FROM public.machine_trays mt
  JOIN public."vendingMachine" vm ON vm.id = mt.machine_id
  LEFT JOIN public.products p ON p.id = mt.product_id
  WHERE vm.company = p_company_id;

  RETURN jsonb_build_object(
    'version',         1,
    'kpis',            v_kpis,
    'stockout_events', v_stockouts,
    'refill_tours',    v_refill_tours,
    'stock_cover',     v_stock_cover
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_operations(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_operations(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;
```

- [ ] **Step 2: Apply migration**

```bash
cd Docker/supabase
supabase migration up
cd ../..
```

Expected: `Applying migration 20260509000100_analytics_rpcs.sql ... done`.

- [ ] **Step 3: Run all SQL tests — expect ALL PASS**

```bash
bash Docker/supabase/tests/run-sql-tests.sh
```

Expected: PASS for `get_product_detail_kpis.test.sql`, `tray_stockout_event_trigger.test.sql`, and all six `analytics_*.test.sql` files.

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/migrations/20260509000100_analytics_rpcs.sql
git commit -m "feat(analytics): add six analytics RPCs + shared filter helper

_analytics_filtered_sales handles the WHERE clause; six public RPCs
(overview, sales_breakdown, products, machines, conversion, operations)
each return jsonb with version: 1. SECURITY DEFINER, statement_timeout
10s, REVOKE PUBLIC + GRANT authenticated."
```

### Task 2.4: Index audit + perf check on representative data

- [ ] **Step 1: EXPLAIN ANALYZE on each RPC with a 90-day window**

```bash
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres <<'SQL'
-- Use a real company_id from your dev DB (replace <COMPANY_ID> and <USER_ID>)
SET request.jwt.claims TO '{"sub":"<USER_ID>","role":"authenticated"}';

EXPLAIN ANALYZE
SELECT public.analytics_overview('<COMPANY_ID>'::uuid,
  now() - interval '90 days', now(), NULL, NULL,
  NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]);

-- Repeat for each of the 6 RPCs
SQL
```

Expected: each RPC completes in < 500 ms on the dev DB (~10k sales). If any RPC exceeds 500 ms:
- Note which one + the slow operation in the EXPLAIN tree
- Add a covering index to a follow-up commit (e.g. `CREATE INDEX idx_sales_machine_created ON sales(machine_id, created_at DESC);`)
- Re-run EXPLAIN ANALYZE to confirm the index is used

- [ ] **Step 2: If a covering index was needed, commit it as a separate migration**

```bash
# Only if Step 1 surfaced a real perf gap — use timestamp 20260509000200 or later
git add Docker/supabase/migrations/20260509000200_analytics_indexes.sql
git commit -m "perf(analytics): add covering indexes for slow RPCs"
```

### Task 2.5: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add the six new RPCs to the "Key RPC functions" list**

After the existing RPC list entries, add:
```
- `analytics_overview(company_id, from, to, compare_from, compare_to, machine_ids[], channels[], category_ids[], vat_rates[])` – KPIs + daily series + top products/machines for /analytics Overview tab
- `analytics_sales_breakdown(..., dimension)` – Sales-tab breakdown by machine/product/category/channel/vat/hour/dow
- `analytics_products(...)` – Per-product KPIs + mix-shift series for Products tab
- `analytics_machines(...)` – Per-machine KPIs + heatmaps (sales count by dow/hour) for Machines tab
- `analytics_conversion(...)` – Pax × Sales conversion KPIs + heatmaps for Conversion tab
- `analytics_operations(...)` – Stockouts + refill tours + stock-cover-days for Operations tab
```

- [ ] **Step 2: Commit docs**

```bash
git add CLAUDE.md
git commit -m "docs: document six analytics RPCs"
```

### Chunk 2 — Done When

- [ ] All 8 SQL test files in `Docker/supabase/tests/` pass via `run-sql-tests.sh`
- [ ] All six `analytics_*.test.sql` files include cross-company isolation assertions
- [ ] EXPLAIN ANALYZE confirms each RPC < 500 ms on a 90-day window with realistic data
- [ ] Three commits: failing tests → migration → CLAUDE.md (+ optional perf-index commit)

---

## Chunk 3: Phase 2 + Phase 3a — Web Foundation, Overview Tab, AI Insights extraction

**Goal:** Ship the `/analytics` page skeleton with hash-routing, the global filter bar (with URL/preset persistence), and a fully-functional Overview tab. Extract the inline AI insights block from `pages/index.vue` into a reusable `<CompanyInsights />` component and render it in `TabOverview.vue` (still mounted on `/` until Chunk 7).

**Files (Phase 2 — Web Foundation):**
- Create: `management-frontend/app/composables/useAnalyticsFilters.ts` + test
- Create: `management-frontend/app/composables/useAnalyticsData.ts` + test
- Create: `management-frontend/app/composables/useAnalyticsExport.ts` + test
- Create: `management-frontend/app/components/analytics/AnalyticsFilterBar.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsTabNav.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsKpiGrid.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsChart.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsTable.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsPresetMenu.vue`
- Create: `management-frontend/app/pages/analytics/index.vue`

**Files (Phase 3a — Overview Tab + AI Insights extraction):**
- Create: `management-frontend/app/components/CompanyInsights.vue`
- Create: `management-frontend/app/components/analytics/tabs/TabOverview.vue`
- Modify: `management-frontend/app/pages/index.vue` (use extracted component, no functional change)

### Task 3.1: TDD `useAnalyticsFilters` composable

**Files:**
- Create: `management-frontend/app/composables/__tests__/useAnalyticsFilters.test.ts`
- Create: `management-frontend/app/composables/useAnalyticsFilters.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// management-frontend/app/composables/__tests__/useAnalyticsFilters.test.ts
import { describe, it, expect, beforeEach } from 'vitest'
import { useAnalyticsFilters, serializeFilter, deserializeFilter, DEFAULT_FILTER } from '../useAnalyticsFilters'

describe('serializeFilter / deserializeFilter', () => {
  it('round-trips a default filter', () => {
    const enc = serializeFilter(DEFAULT_FILTER)
    expect(typeof enc).toBe('string')
    const dec = deserializeFilter(enc)
    expect(dec.from).toBe(DEFAULT_FILTER.from)
    expect(dec.to).toBe(DEFAULT_FILTER.to)
    expect(dec.machines).toEqual([])
  })

  it('drops unknown keys silently', () => {
    const future = { ...DEFAULT_FILTER, somethingNew: 'x', anotherFutureKey: [1, 2] } as any
    const enc = serializeFilter(future)
    const dec = deserializeFilter(enc)
    expect((dec as any).somethingNew).toBeUndefined()
    expect((dec as any).anotherFutureKey).toBeUndefined()
  })

  it('clamps v to current schema (1) when older URL is loaded', () => {
    const olderEncoded = serializeFilter({ ...DEFAULT_FILTER, v: 99 } as any)
    const dec = deserializeFilter(olderEncoded)
    expect(dec.v).toBe(1)
  })

  it('returns DEFAULT_FILTER when given malformed input', () => {
    const dec = deserializeFilter('not-a-real-base64url-string')
    expect(dec).toEqual(DEFAULT_FILTER)
  })
})
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useAnalyticsFilters.test.ts
```

Expected: 4 failures (`Cannot find module '../useAnalyticsFilters'`).

- [ ] **Step 3: Implement the composable**

```typescript
// management-frontend/app/composables/useAnalyticsFilters.ts
import { useState, useRoute, useRouter } from '#imports'
import { computed, watch } from 'vue'

export interface AnalyticsFilter {
  v: number                  // schema version
  from: string               // ISO 8601 UTC
  to: string                 // ISO 8601 UTC
  compare: boolean
  machines: string[]
  channels: string[]
  categories: string[]
  vatRates: number[]
}

const today = () => new Date().toISOString()
const daysAgo = (n: number) => new Date(Date.now() - n * 86400_000).toISOString()

export const DEFAULT_FILTER: AnalyticsFilter = {
  v: 1,
  from: daysAgo(30),
  to: today(),
  compare: false,
  machines: [],
  channels: [],
  categories: [],
  vatRates: [],
}

const ALLOWED_KEYS = new Set<keyof AnalyticsFilter>([
  'v', 'from', 'to', 'compare', 'machines', 'channels', 'categories', 'vatRates'
])

export function serializeFilter(f: AnalyticsFilter): string {
  // base64url-encoded JSON, only known keys
  const cleaned: Partial<AnalyticsFilter> = {}
  for (const k of ALLOWED_KEYS) cleaned[k] = (f as any)[k]
  cleaned.v = 1  // always emit current schema version
  const json = JSON.stringify(cleaned)
  // base64url
  return btoa(json).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function deserializeFilter(s: string): AnalyticsFilter {
  try {
    const padded = s.replace(/-/g, '+').replace(/_/g, '/')
    const json = atob(padded + '==='.slice((padded.length + 3) % 4))
    const raw = JSON.parse(json)
    const out: AnalyticsFilter = { ...DEFAULT_FILTER }
    for (const k of ALLOWED_KEYS) {
      if (k in raw) (out as any)[k] = raw[k]
    }
    out.v = 1  // clamp to current schema
    return out
  } catch {
    return { ...DEFAULT_FILTER }
  }
}

export function useAnalyticsFilters() {
  const filter = useState<AnalyticsFilter>('analytics-filters', () => ({ ...DEFAULT_FILTER }))

  // URL sync — read on mount (client only), write debounced on change
  if (process.client) {
    const route = useRoute()
    const router = useRouter()
    const initial = (route.query.f as string | undefined)
    if (initial) {
      filter.value = deserializeFilter(initial)
    }
    let urlSyncTimer: number | null = null
    watch(filter, (val) => {
      if (urlSyncTimer) window.clearTimeout(urlSyncTimer)
      urlSyncTimer = window.setTimeout(() => {
        router.replace({ query: { ...route.query, f: serializeFilter(val) } })
      }, 300) as unknown as number
    }, { deep: true })
  }

  function reset() { filter.value = { ...DEFAULT_FILTER } }

  // Preset persistence (localStorage)
  function savePreset(name: string) {
    if (!process.client) return
    const presets = JSON.parse(localStorage.getItem('analytics.presets') || '[]')
    const idx = presets.findIndex((p: any) => p.name === name)
    const entry = { name, filter: filter.value }
    if (idx >= 0) presets[idx] = entry; else presets.push(entry)
    localStorage.setItem('analytics.presets', JSON.stringify(presets))
  }
  function loadPreset(name: string) {
    if (!process.client) return
    const presets = JSON.parse(localStorage.getItem('analytics.presets') || '[]')
    const found = presets.find((p: any) => p.name === name)
    if (found) filter.value = { ...DEFAULT_FILTER, ...found.filter }
  }
  function listPresets(): string[] {
    if (!process.client) return []
    return JSON.parse(localStorage.getItem('analytics.presets') || '[]').map((p: any) => p.name)
  }
  function deletePreset(name: string) {
    if (!process.client) return
    const presets = JSON.parse(localStorage.getItem('analytics.presets') || '[]')
    const next = presets.filter((p: any) => p.name !== name)
    localStorage.setItem('analytics.presets', JSON.stringify(next))
  }

  return { filter, reset, savePreset, loadPreset, listPresets, deletePreset }
}
```

- [ ] **Step 4: Run test — expect PASS**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useAnalyticsFilters.test.ts
```

Expected: 4 passes.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/useAnalyticsFilters.ts \
        management-frontend/app/composables/__tests__/useAnalyticsFilters.test.ts
git commit -m "feat(analytics): useAnalyticsFilters composable with URL/preset round-trip"
```

### Task 3.2: TDD `useAnalyticsData` composable (cache + RPC dispatch)

**Files:**
- Create: `management-frontend/app/composables/__tests__/useAnalyticsData.test.ts`
- Create: `management-frontend/app/composables/useAnalyticsData.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// management-frontend/app/composables/__tests__/useAnalyticsData.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { computeFilterHash, RPC_NAME_BY_TAB } from '../useAnalyticsData'
import { DEFAULT_FILTER } from '../useAnalyticsFilters'

describe('computeFilterHash', () => {
  it('produces stable hash for same filter', () => {
    const a = computeFilterHash('overview', DEFAULT_FILTER)
    const b = computeFilterHash('overview', DEFAULT_FILTER)
    expect(a).toBe(b)
  })
  it('produces different hash for different tabs', () => {
    expect(computeFilterHash('overview', DEFAULT_FILTER))
      .not.toBe(computeFilterHash('sales', DEFAULT_FILTER))
  })
  it('produces different hash when machines change', () => {
    const f1 = { ...DEFAULT_FILTER, machines: ['m1'] }
    const f2 = { ...DEFAULT_FILTER, machines: ['m2'] }
    expect(computeFilterHash('overview', f1)).not.toBe(computeFilterHash('overview', f2))
  })
})

describe('RPC_NAME_BY_TAB', () => {
  it('maps each of the 6 tabs to its RPC', () => {
    expect(RPC_NAME_BY_TAB.overview).toBe('analytics_overview')
    expect(RPC_NAME_BY_TAB.sales).toBe('analytics_sales_breakdown')
    expect(RPC_NAME_BY_TAB.products).toBe('analytics_products')
    expect(RPC_NAME_BY_TAB.machines).toBe('analytics_machines')
    expect(RPC_NAME_BY_TAB.conversion).toBe('analytics_conversion')
    expect(RPC_NAME_BY_TAB.operations).toBe('analytics_operations')
  })
})
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useAnalyticsData.test.ts
```

- [ ] **Step 3: Implement**

```typescript
// management-frontend/app/composables/useAnalyticsData.ts
import { ref } from 'vue'
import { useSupabaseClient } from '#imports'
import type { AnalyticsFilter } from './useAnalyticsFilters'

export type AnalyticsTab = 'overview' | 'sales' | 'products' | 'machines' | 'conversion' | 'operations'

export const RPC_NAME_BY_TAB: Record<AnalyticsTab, string> = {
  overview:   'analytics_overview',
  sales:      'analytics_sales_breakdown',
  products:   'analytics_products',
  machines:   'analytics_machines',
  conversion: 'analytics_conversion',
  operations: 'analytics_operations',
}

export function computeFilterHash(tab: AnalyticsTab, f: AnalyticsFilter): string {
  return JSON.stringify([tab, f])
}

interface CacheEntry { at: number; data: any }
const CACHE_TTL_MS = 30_000

export function useAnalyticsData() {
  const cache = new Map<string, CacheEntry>()
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetch(
    tab: AnalyticsTab,
    filter: AnalyticsFilter,
    companyId: string,
    extra: Record<string, unknown> = {}
  ) {
    const key = computeFilterHash(tab, filter)
    const cached = cache.get(key)
    if (cached && Date.now() - cached.at < CACHE_TTL_MS) return cached.data

    loading.value = true
    error.value = null
    try {
      const supabase = useSupabaseClient()
      const params: Record<string, unknown> = {
        p_company_id:    companyId,
        p_from:          filter.from,
        p_to:            filter.to,
        p_compare_from:  filter.compare ? null /* TODO compute compare window */ : null,
        p_compare_to:    null,
        p_machine_ids:   filter.machines,
        p_channels:      filter.channels,
        p_category_ids:  filter.categories,
        p_vat_rates:     filter.vatRates,
        ...extra,
      }
      const { data, error: rpcError } = await (supabase as any).rpc(RPC_NAME_BY_TAB[tab], params)
      if (rpcError) throw rpcError
      cache.set(key, { at: Date.now(), data })
      return data
    } catch (e: any) {
      error.value = e?.message ?? String(e)
      throw e
    } finally {
      loading.value = false
    }
  }

  function invalidate() { cache.clear() }

  return { fetch, loading, error, invalidate }
}
```

- [ ] **Step 4: Run test — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/useAnalyticsData.ts \
        management-frontend/app/composables/__tests__/useAnalyticsData.test.ts
git commit -m "feat(analytics): useAnalyticsData composable with 30s cache"
```

### Task 3.3: TDD `useAnalyticsExport` composable (CSV)

**Files:**
- Create: `management-frontend/app/composables/__tests__/useAnalyticsExport.test.ts`
- Create: `management-frontend/app/composables/useAnalyticsExport.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// management-frontend/app/composables/__tests__/useAnalyticsExport.test.ts
import { describe, it, expect } from 'vitest'
import { rowsToCsv } from '../useAnalyticsExport'

describe('rowsToCsv', () => {
  it('emits UTF-8 BOM and ; delimiter', () => {
    const csv = rowsToCsv(
      [{ name: 'a', revenue: 1.5 }, { name: 'b', revenue: 2.7 }],
      ['name', 'revenue']
    )
    expect(csv.startsWith('﻿')).toBe(true)
    const lines = csv.replace('﻿', '').split('\n')
    expect(lines[0]).toBe('name;revenue')
    expect(lines[1]).toBe('a;1,5')         // German decimal
    expect(lines[2]).toBe('b;2,7')
  })

  it('escapes values containing ; or " or newline', () => {
    const csv = rowsToCsv(
      [{ name: 'a;b', note: 'has "quote"' }, { name: 'multi\nline', note: 'ok' }],
      ['name', 'note']
    )
    expect(csv).toContain('"a;b"')
    expect(csv).toContain('"has ""quote"""')
    expect(csv).toContain('"multi\nline"')
  })
})
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement**

```typescript
// management-frontend/app/composables/useAnalyticsExport.ts
function escapeCell(value: unknown): string {
  if (value == null) return ''
  if (typeof value === 'number') return String(value).replace('.', ',')
  const s = String(value)
  if (/[;"\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"'
  return s
}

export function rowsToCsv(rows: Record<string, unknown>[], columns: string[]): string {
  const header = columns.join(';')
  const body = rows.map(r => columns.map(c => escapeCell(r[c])).join(';')).join('\n')
  return '﻿' + header + '\n' + body
}

export function useAnalyticsExport() {
  function download(filename: string, content: string, mime = 'text/csv;charset=utf-8') {
    if (!process.client) return
    const blob = new Blob([content], { type: mime })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url; a.download = filename; a.click()
    URL.revokeObjectURL(url)
  }
  return { rowsToCsv, download }
}
```

- [ ] **Step 4: Run test — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/useAnalyticsExport.ts \
        management-frontend/app/composables/__tests__/useAnalyticsExport.test.ts
git commit -m "feat(analytics): useAnalyticsExport with German-locale CSV"
```

### Task 3.4: Build the global filter bar component

**Files:**
- Create: `management-frontend/app/components/analytics/AnalyticsFilterBar.vue`

- [ ] **Step 1: Implement the filter bar**

The filter bar reads `useAnalyticsFilters()` and renders:
- A date-range pill that opens a popover with presets (Today/7d/30d/90d/YTD/12M/Custom)
- A "Compare period" toggle
- A machines multi-select (uses existing `MultiProductCombobox.vue`-style pattern — adapt for machines)
- Channel pill toggles (cashless / cash / card)
- Categories multi-select
- VAT rates multi-select (sourced from distinct `tax_rate_snapshot` values fetched on mount)
- Reset button + Save-as-preset menu

Reuse: existing `Button`, `Popover`, `Command`, `Badge` shadcn components. Follow `AppSidebar.vue` styling for filter pills. The filter bar **emits no events** — components watch the shared composable state directly.

- [ ] **Step 2: Add a snapshot smoke test**

```typescript
// management-frontend/app/components/analytics/__tests__/AnalyticsFilterBar.spec.ts
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import AnalyticsFilterBar from '../AnalyticsFilterBar.vue'
// Use the existing test-helpers/nuxt-stubs.ts pattern
```

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/components/analytics/AnalyticsFilterBar.vue \
        management-frontend/app/components/analytics/__tests__/
git commit -m "feat(analytics): AnalyticsFilterBar with date/machines/channels/categories/vat filters"
```

### Task 3.5: Build remaining shared components

**Files:**
- Create: `management-frontend/app/components/analytics/AnalyticsTabNav.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsKpiGrid.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsChart.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsTable.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsPresetMenu.vue`

- [ ] **Step 1: AnalyticsTabNav.vue** — horizontal tab bar that syncs to URL hash. Six tabs, badge support.

```vue
<!-- management-frontend/app/components/analytics/AnalyticsTabNav.vue -->
<script setup lang="ts">
import { useRoute, useRouter } from 'vue-router'
import { computed } from 'vue'

const route = useRoute()
const router = useRouter()
const TABS = [
  { id: 'overview',   label: 'Overview' },
  { id: 'sales',      label: 'Sales' },
  { id: 'products',   label: 'Products' },
  { id: 'machines',   label: 'Machines' },
  { id: 'conversion', label: 'Conversion' },
  { id: 'operations', label: 'Operations' },
] as const

const active = computed(() => (route.hash || '#overview').slice(1))

function setTab(id: string) {
  router.replace({ ...route, hash: '#' + id })
}
</script>

<template>
  <nav class="flex gap-1 border-b">
    <button v-for="t in TABS" :key="t.id"
      class="px-3 py-2 text-sm font-medium transition-colors"
      :class="active === t.id
        ? 'border-b-2 border-primary text-primary'
        : 'text-muted-foreground hover:text-foreground'"
      @click="setTab(t.id)">
      {{ t.label }}
    </button>
  </nav>
</template>
```

- [ ] **Step 2: AnalyticsKpiGrid.vue** — accepts an array of `{ label, value, delta_pct?, format }` and renders 1-4 KPI cards in a responsive grid (1×4 desktop, 2×2 tablet, 1×N mobile). Reuse `formatCurrency` and apply green/red coloring to delta pills.

- [ ] **Step 3: AnalyticsChart.vue** — wraps `ChartAreaInteractive.vue` with title/legend/loading skeleton. Accepts `data`, `xKey`, `yKey`, `secondaryYKey?`, `compareData?` props.

- [ ] **Step 4: AnalyticsTable.vue** — sortable, drill-throughable. Reuses `SortHeader.vue`. Props: `rows`, `columns: { key, label, format?, type: 'number' | 'string' | 'currency' | 'percent', drillTo?: 'machine' | 'product' | 'category' }`. Emits `drill` with payload `{ type, value }`.

- [ ] **Step 5: AnalyticsPresetMenu.vue** — dropdown listing saved presets, with "Save current as…" + delete actions. Wraps `useAnalyticsFilters().savePreset/loadPreset/listPresets/deletePreset`.

- [ ] **Step 6: Commit each component as a separate commit** so any single one can be reverted

```bash
git add management-frontend/app/components/analytics/AnalyticsTabNav.vue
git commit -m "feat(analytics): AnalyticsTabNav tab bar with hash sync"
# repeat for each component
```

### Task 3.6: Create `/analytics/index.vue` page skeleton

**Files:**
- Create: `management-frontend/app/pages/analytics/index.vue`

- [ ] **Step 1: Implement page**

```vue
<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { computed, defineAsyncComponent } from 'vue'
import { useRoute } from 'vue-router'

const TabOverview   = defineAsyncComponent(() => import('@/components/analytics/tabs/TabOverview.vue'))
const TabSales      = defineAsyncComponent(() => import('@/components/analytics/tabs/TabSales.vue'))
const TabProducts   = defineAsyncComponent(() => import('@/components/analytics/tabs/TabProducts.vue'))
const TabMachines   = defineAsyncComponent(() => import('@/components/analytics/tabs/TabMachines.vue'))
const TabConversion = defineAsyncComponent(() => import('@/components/analytics/tabs/TabConversion.vue'))
const TabOperations = defineAsyncComponent(() => import('@/components/analytics/tabs/TabOperations.vue'))

const route = useRoute()
const active = computed(() => (route.hash || '#overview').slice(1))

const Component = computed(() => {
  switch (active.value) {
    case 'sales':      return TabSales
    case 'products':   return TabProducts
    case 'machines':   return TabMachines
    case 'conversion': return TabConversion
    case 'operations': return TabOperations
    default:           return TabOverview
  }
})
</script>

<template>
  <div class="flex flex-1 flex-col gap-4 p-4 md:p-6">
    <h1 class="text-2xl font-semibold">{{ $t('analytics.title') }}</h1>
    <AnalyticsFilterBar />
    <AnalyticsTabNav />
    <component :is="Component" />
  </div>
</template>
```

- [ ] **Step 2: Manual smoke test**

Run dev server:
```bash
cd management-frontend && npm run dev
```

Navigate to `http://localhost:3000/analytics#overview`, then `#sales`, … expect each tab placeholder to render without console errors. (TabOverview is the first one we'll fully implement; others are stubs returning "Coming soon".)

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/pages/analytics/index.vue
git commit -m "feat(analytics): /analytics page skeleton with hash-routed tabs"
```

### Task 3.7: Extract AI insights to `<CompanyInsights />` component (Phase 3 step 10a)

**Files:**
- Create: `management-frontend/app/components/CompanyInsights.vue`
- Modify: `management-frontend/app/pages/index.vue`

- [ ] **Step 1: Create `CompanyInsights.vue` by lifting the inline JSX from `pages/index.vue`**

Read `pages/index.vue:580-731` (approx — the entire `<!-- Company Insights -->` block). Move it verbatim into `components/CompanyInsights.vue`, including:
- The `useInsights()` composable usage
- The `companyInsightsExpanded` ref
- The `companyHistoryExpanded` ref
- The mount-time `fetchCompanyHistory()` call

The component takes no props (it reads from `useInsights()` directly). Uses existing `IconSparkles`, `IconRefresh`, `IconLoader2` from `@tabler/icons-vue`.

- [ ] **Step 2: Replace the inline block in `pages/index.vue` with `<CompanyInsights />`**

Find the section starting with `<!-- Company Insights -->` (around line 580) and ending before `<!-- Machines -->` (around line 734). Replace with:
```vue
<div class="px-4 lg:px-6">
  <CompanyInsights />
</div>
```

Remove the now-unused imports/refs from the script setup:
- `useInsights` import is unused if no other usage — verify and remove
- `sortedRecommendations`, `priorityVariant`, `recommendationTypeLabel` imports
- `companyData: companyInsights, companyLoading, companyError, fetchCompanyInsights, history: companyHistory, historyLoading: companyHistoryLoading, fetchHistory: fetchCompanyHistory`
- `companyInsightsExpanded`, `generateCompanyInsights`, `refreshCompanyInsights`
- `companyHistoryExpanded`, `toggleCompanyHistoryEntry`
- The `onMounted` block that called `fetchCompanyHistory`

- [ ] **Step 3: Visual smoke test**

Start dev server, visit `/`, expand the AI insights block. Behaviour should be identical to before (this is a refactor commit).

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/components/CompanyInsights.vue \
        management-frontend/app/pages/index.vue
git commit -m "refactor(dashboard): extract AI insights block into CompanyInsights.vue

No functional change. Phase 3 step 10a per the analytics plan: prepares
the component for re-use in TabOverview while keeping it on the dashboard
until Phase 6 deletes the dashboard mount."
```

### Task 3.8: Build `TabOverview.vue`

**Files:**
- Create: `management-frontend/app/components/analytics/tabs/TabOverview.vue`

- [ ] **Step 1: Implement**

```vue
<script setup lang="ts">
import { ref, watch, onMounted } from 'vue'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'
import { useAnalyticsData } from '@/composables/useAnalyticsData'
import { useOrganization } from '@/composables/useOrganization'
import CompanyInsights from '@/components/CompanyInsights.vue'

const { filter } = useAnalyticsFilters()
const { fetch, loading, error } = useAnalyticsData()
const { organization } = useOrganization()
const data = ref<any>(null)

async function load() {
  if (!organization.value?.id) return
  data.value = await fetch('overview', filter.value, organization.value.id)
}

onMounted(load)
watch(filter, load, { deep: true })
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- KPI Grid -->
    <AnalyticsKpiGrid v-if="data" :kpis="[
      { label: $t('analytics.kpi.revenue'),   value: data.kpis.revenue,        delta: data.kpis_compare ? ((data.kpis.revenue - data.kpis_compare.revenue) / data.kpis_compare.revenue * 100) : null, format: 'currency' },
      { label: $t('analytics.kpi.units'),     value: data.kpis.units,          delta: data.kpis_compare ? ((data.kpis.units - data.kpis_compare.units) / data.kpis_compare.units * 100) : null, format: 'number' },
      { label: $t('analytics.kpi.avgBasket'), value: data.kpis.avg_basket,     delta: null, format: 'currency' },
      { label: $t('analytics.kpi.conversion'),value: data.kpis.conversion_pct, delta: null, format: 'percent' },
    ]" />

    <!-- Daily series chart -->
    <AnalyticsChart v-if="data"
      :data="data.daily_series"
      x-key="date" y-key="revenue" secondary-y-key="units"
      :title="$t('analytics.overview.dailySeriesTitle')"
    />

    <!-- Top products + Top machines -->
    <div class="grid gap-4 lg:grid-cols-2">
      <AnalyticsTable v-if="data"
        :rows="data.top_products"
        :columns="[
          { key: 'name', label: $t('analytics.product'), type: 'string', drillTo: 'product' },
          { key: 'units', label: $t('analytics.units'), type: 'number' },
          { key: 'revenue', label: $t('analytics.revenue'), type: 'currency' },
          { key: 'mix_pct', label: $t('analytics.mix'), type: 'percent' },
        ]"
        :title="$t('analytics.overview.topProducts')"
      />
      <AnalyticsTable v-if="data"
        :rows="data.top_machines"
        :columns="[
          { key: 'name', label: $t('analytics.machine'), type: 'string', drillTo: 'machine' },
          { key: 'revenue', label: $t('analytics.revenue'), type: 'currency' },
        ]"
        :title="$t('analytics.overview.topMachines')"
      />
    </div>

    <!-- AI Insights -->
    <CompanyInsights />

    <!-- Loading / error -->
    <div v-if="loading" class="text-sm text-muted-foreground">{{ $t('common.loading') }}</div>
    <div v-if="error" class="text-sm text-destructive">{{ error }}</div>
  </div>
</template>
```

- [ ] **Step 2: Manual smoke test**

Visit `/analytics#overview`, expect: KPI grid, daily-series chart, two top tables, AI insights block. Filter changes (e.g., switch to 7-day window) trigger reload.

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/components/analytics/tabs/TabOverview.vue
git commit -m "feat(analytics): TabOverview with KPIs + daily chart + top products/machines + AI insights"
```

### Chunk 3 — Done When

- [ ] All Vitest tests pass: `cd management-frontend && npx vitest run`
- [ ] `/analytics#overview` renders fully with real data
- [ ] Filter changes (date range, machines) trigger reload + URL update
- [ ] Save-as-preset round-trips: save preset → reload page → preset is in dropdown
- [ ] Dashboard `/` AI insights still works (CompanyInsights is now mounted there too — no functional change)
- [ ] All commits separate per component; refactor commit explicitly says "No functional change"

---

## Chunk 4: Phase 3b — Remaining Five Web Tabs

**Goal:** Build TabSales, TabProducts, TabMachines, TabConversion, TabOperations + AnalyticsCompareSheet. Each tab follows the same pattern as TabOverview: read filter from composable, fetch data via `useAnalyticsData`, render via shared components.

**Files:**
- Create: `management-frontend/app/components/analytics/tabs/TabSales.vue`
- Create: `management-frontend/app/components/analytics/tabs/TabProducts.vue`
- Create: `management-frontend/app/components/analytics/tabs/TabMachines.vue`
- Create: `management-frontend/app/components/analytics/tabs/TabConversion.vue`
- Create: `management-frontend/app/components/analytics/tabs/TabOperations.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsCompareSheet.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsHeatmap.vue`
- Create: `management-frontend/app/components/analytics/AnalyticsGeoMap.vue` (web-only)

### Task 4.1: Build `TabSales.vue` (breakdown workbench)

**Files:**
- Create: `management-frontend/app/components/analytics/tabs/TabSales.vue`

- [ ] **Step 1: Implement**

The Sales tab has a dimension switcher (Picker with 7 options: machine/product/category/channel/vat/hour/dow), a chart, and a sortable table. For Hour or Day-of-week dimensions, render `AnalyticsHeatmap` instead of bar chart.

```vue
<script setup lang="ts">
import { ref, watch, computed, onMounted } from 'vue'
import { useAnalyticsFilters } from '@/composables/useAnalyticsFilters'
import { useAnalyticsData } from '@/composables/useAnalyticsData'
import { useOrganization } from '@/composables/useOrganization'

const { filter } = useAnalyticsFilters()
const { fetch, loading, error } = useAnalyticsData()
const { organization } = useOrganization()

const dimension = ref<'machine' | 'product' | 'category' | 'channel' | 'vat' | 'hour' | 'dow'>('machine')
const data = ref<any>(null)

async function load() {
  if (!organization.value?.id) return
  data.value = await fetch('sales', filter.value, organization.value.id, { p_dimension: dimension.value })
}

onMounted(load)
watch([filter, dimension], load, { deep: true })

const isHeatmap = computed(() => dimension.value === 'hour' || dimension.value === 'dow')
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- KPI Grid -->
    <AnalyticsKpiGrid v-if="data" :kpis="[
      { label: $t('analytics.kpi.revenue'), value: data.rows.reduce((s, r) => s + r.revenue, 0), format: 'currency' },
      { label: $t('analytics.kpi.units'), value: data.rows.reduce((s, r) => s + r.units, 0), format: 'number' },
      { label: $t('analytics.kpi.avgBasket'), value: data.rows.length ? data.rows.reduce((s, r) => s + r.revenue, 0) / data.rows.reduce((s, r) => s + r.units, 0) : 0, format: 'currency' },
      { label: $t('analytics.kpi.salesCount'), value: data.rows.length, format: 'number' },
    ]" />

    <!-- Dimension switcher -->
    <div class="flex flex-wrap gap-2">
      <button v-for="d in ['machine','product','category','channel','vat','hour','dow']" :key="d"
        class="rounded-full border px-3 py-1 text-xs font-medium transition-colors"
        :class="dimension === d ? 'bg-primary text-primary-foreground border-primary' : 'hover:bg-muted'"
        @click="dimension = d as any">
        {{ $t('analytics.dimension.' + d) }}
      </button>
    </div>

    <!-- Heatmap (hour or dow) OR bar chart (others) -->
    <AnalyticsHeatmap v-if="data && isHeatmap" :rows="data.rows" />
    <AnalyticsChart v-else-if="data" :data="data.rows" x-key="label" y-key="revenue" :title="$t('analytics.sales.byDimension', { dim: $t('analytics.dimension.' + dimension) })" />

    <!-- Table -->
    <AnalyticsTable v-if="data" :rows="data.rows" :columns="[
      { key: 'label', label: $t('analytics.label'), type: 'string' },
      { key: 'revenue', label: $t('analytics.revenue'), type: 'currency' },
      { key: 'units', label: $t('analytics.units'), type: 'number' },
      { key: 'avg_basket', label: $t('analytics.avgBasket'), type: 'currency' },
      { key: 'share_revenue_pct', label: $t('analytics.shareRevenue'), type: 'percent' },
      { key: 'share_units_pct', label: $t('analytics.shareUnits'), type: 'percent' },
    ]" @drill="(payload) => { if (dimension === 'machine') filter.machines = [payload.value]; if (dimension === 'product') {/* set product filter */} }" />
  </div>
</template>
```

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/components/analytics/tabs/TabSales.vue
git commit -m "feat(analytics): TabSales with dimension switcher (machine/product/.../dow)"
```

### Task 4.2: Build `TabProducts.vue`

Similar pattern to TabSales but uses `analytics_products` RPC. Renders: 4 KPIs (active/slow/discontinued/categories_with_sales), a search input, sub-filters (category, status, slow-only), the products list with image thumbnails + status badges, and the mix-shift stacked-area chart.

- [ ] **Step 1: Implement following TabOverview/TabSales template**
- [ ] **Step 2: Commit `feat(analytics): TabProducts with velocity/status/mix-shift`**

### Task 4.3: Build `TabMachines.vue` + `AnalyticsCompareSheet.vue` + `AnalyticsGeoMap.vue`

`TabMachines` shows: 4 KPIs, machine list/cards with `MachineCard`-like content, heatmap toggle (weekday × hour per machine), Compare button → opens `AnalyticsCompareSheet`, geo map (web only — uses `LocationPicker.vue`-style Leaflet pattern).

- [ ] **Step 1: Implement TabMachines**
- [ ] **Step 2: Implement AnalyticsCompareSheet** — modal that takes 2-4 machine IDs and renders side-by-side mini-charts (revenue trend, conversion trend, top-3 products) using `analytics_overview`-style data fetched per machine
- [ ] **Step 3: Implement AnalyticsGeoMap** — Leaflet bubbles from `data.machines[].lat/lng`, size = revenue, color = conversion percentile
- [ ] **Step 4: Commit each as separate commits**

### Task 4.4: Build `TabConversion.vue`

`analytics_conversion`-driven. Renders 4 KPIs, the machines × hour heatmap, traffic-vs-revenue scatter, daily conversion trend, per-machine table.

- [ ] **Step 1: Implement TabConversion**
- [ ] **Step 2: Implement scatter chart** — extend or wrap `AnalyticsChart.vue` to support `chartType: 'scatter'`, with diagonal reference line at fleet-avg conversion
- [ ] **Step 3: Commit `feat(analytics): TabConversion with pax × sales heatmap + scatter`**

### Task 4.5: Build `TabOperations.vue`

`analytics_operations`-driven. Renders 4 KPIs, stockout events list (sortable by lost_revenue), refill tours collapsible per day, stock-cover-days table (red < 3 days). Includes a banner when filter range extends before migration timestamp.

- [ ] **Step 1: Implement TabOperations**
- [ ] **Step 2: Hardcode the migration timestamp** for the "Stockout-Daten verfügbar ab DD.MM.YYYY" banner — the actual application timestamp from Phase 0. Read it from migration filename via build-time constant or lookup the most recent stockout event row's `created_at` (whichever is older — a defensive lookup is more robust)
- [ ] **Step 3: Commit `feat(analytics): TabOperations with stockouts + refill efficiency + stock-cover`**

### Chunk 4 — Done When

- [ ] All 5 remaining tabs render with real data
- [ ] Hour/Dow dimension on Sales tab renders as heatmap
- [ ] Compare-machines sheet opens and renders side-by-side data
- [ ] Geo map shows on web (skipped on iPhone in Chunk 6)
- [ ] Drill-throughs from any tab to product/machine detail page work
- [ ] No regressions on Vitest

---

## Chunk 5: Phase 4 + Phase 5a — iOS Foundation + Overview Section

**Goal:** Add `SidebarItem.analytics`, `AnalyticsRootView` with adaptive layout (iPhone single-screen + section picker; iPad/Mac NavigationSplitView), `AnalyticsFilterSheet`, shared SwiftUI components, and a fully-functional `AnalyticsOverviewView`.

**Files:**
- Modify: `ios/VMflow/Navigation/AppNavigation.swift` (add `.analytics` case)
- Modify: `ios/VMflow/VMflowApp.swift` (`MoreView` adds Analytics NavigationLink)
- Modify: `ios/VMflow/Navigation/SidebarNavigationView.swift` (Analytics destination)
- Create: `ios/VMflow/Models/AnalyticsFilter.swift`
- Create: `ios/VMflow/ViewModels/AnalyticsRootViewModel.swift`
- Create: `ios/VMflow/ViewModels/AnalyticsOverviewViewModel.swift`
- Create: `ios/VMflow/Views/Analytics/AnalyticsRootView.swift`
- Create: `ios/VMflow/Views/Analytics/AnalyticsFilterSheet.swift`
- Create: `ios/VMflow/Views/Analytics/Components/AnalyticsKPIGroup.swift`
- Create: `ios/VMflow/Views/Analytics/Components/AnalyticsChart.swift`
- Create: `ios/VMflow/Views/Analytics/Components/AnalyticsSortableList.swift`
- Create: `ios/VMflow/Views/Analytics/Components/ComparePeriodBadge.swift`
- Create: `ios/VMflow/Views/Analytics/Components/AnalyticsHeatmap.swift`
- Create: `ios/VMflow/Views/Analytics/Sections/AnalyticsOverviewView.swift`

### Task 5.1: Add `SidebarItem.analytics` and wire navigation

**Files:**
- Modify: `ios/VMflow/Navigation/AppNavigation.swift`
- Modify: `ios/VMflow/VMflowApp.swift`
- Modify: `ios/VMflow/Navigation/SidebarNavigationView.swift`

- [ ] **Step 1: Edit `AppNavigation.swift`**

Find the `SidebarItem` enum, add `analytics` immediately after `inbox` (so it appears in the iPad sidebar between `inbox` and `cashBook` — high prominence):
```swift
case dashboard
case machines
case refill
case inbox
case analytics      // NEW — between inbox and cashBook
case cashBook
case products
case warehouse
case deals
case settings
```

Add to `label`, `icon`, and `compactTab` switch statements:
```swift
case .analytics: "Analytics"               // label
case .analytics: "chart.xyaxis.line"       // icon
case .analytics: nil                       // compactTab — surfaces under "More"
```

- [ ] **Step 2: Edit `MoreView` in `VMflowApp.swift:121`**

Add a NavigationLink to `AnalyticsRootView()`:
```swift
NavigationLink {
    AnalyticsRootView()
} label: {
    Label("Analytics", systemImage: "chart.xyaxis.line")
}
```
Place it as the first entry of the existing Section (above CashBook), so analytics is the most prominent More-tab item.

- [ ] **Step 3: Edit `SidebarNavigationView.swift`**

Add a `case .analytics: AnalyticsRootView()` to the destination switch.

- [ ] **Step 4: Build to verify the project still compiles**

```bash
cd ios && xcodebuild -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: build succeeds (AnalyticsRootView is empty placeholder for now — see Step 5).

- [ ] **Step 5: Create a placeholder `AnalyticsRootView`** so the navigation links resolve

```swift
// ios/VMflow/Views/Analytics/AnalyticsRootView.swift
import SwiftUI

struct AnalyticsRootView: View {
  var body: some View {
    Text("Analytics — coming soon")
      .navigationTitle("Analytics")
  }
}
```

- [ ] **Step 6: Commit**

```bash
git add ios/VMflow/Navigation/AppNavigation.swift ios/VMflow/VMflowApp.swift \
        ios/VMflow/Navigation/SidebarNavigationView.swift ios/VMflow/Views/Analytics/AnalyticsRootView.swift
git commit -m "feat(ios): add SidebarItem.analytics + placeholder AnalyticsRootView

Wires navigation in MoreView (iPhone) and SidebarNavigationView
(iPad/Mac). Placeholder content; full implementation in subsequent
commits."
```

### Task 5.2: TDD `AnalyticsFilter` model

**Files:**
- Create: `ios/VMflow/Models/AnalyticsFilter.swift`
- Create: `ios/VMflowTests/AnalyticsFilterTests.swift` (XCTest baseline)

- [ ] **Step 1: Write the failing test**

```swift
// ios/VMflowTests/AnalyticsFilterTests.swift
import XCTest
@testable import VMflow

final class AnalyticsFilterTests: XCTestCase {
  func testCodableRoundTrip() throws {
    var f = AnalyticsFilter.defaultValue
    f.machines = ["uuid-1", "uuid-2"]
    f.channels = ["cashless"]
    f.vatRates = [0.07, 0.19]

    let data = try JSONEncoder().encode(f)
    let decoded = try JSONDecoder().decode(AnalyticsFilter.self, from: data)

    XCTAssertEqual(decoded.machines, ["uuid-1", "uuid-2"])
    XCTAssertEqual(decoded.channels, ["cashless"])
    XCTAssertEqual(decoded.vatRates, [0.07, 0.19])
    XCTAssertEqual(decoded.v, 1)
  }

  func testUnknownKeysAreDropped() throws {
    // Future: a filter with extra keys must not crash decoding.
    let json = #"{"v":1,"from":"2026-01-01T00:00:00Z","to":"2026-02-01T00:00:00Z","compare":false,"machines":[],"channels":[],"categories":[],"vatRates":[],"futureKey":"x"}"#
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AnalyticsFilter.self, from: data)
    XCTAssertEqual(decoded.v, 1)
    // futureKey is silently dropped because AnalyticsFilter has no such property
  }

  func testVersionClampsToOneOnDecode() throws {
    let json = #"{"v":99,"from":"2026-01-01T00:00:00Z","to":"2026-02-01T00:00:00Z","compare":false,"machines":[],"channels":[],"categories":[],"vatRates":[]}"#
    let decoded = try JSONDecoder().decode(AnalyticsFilter.self, from: json.data(using: .utf8)!)
    // v is clamped on decode, regardless of input
    XCTAssertEqual(decoded.v, 1)
  }
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd ios && xcodebuild test -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:VMflowTests/AnalyticsFilterTests
```

- [ ] **Step 3: Implement**

```swift
// ios/VMflow/Models/AnalyticsFilter.swift
import Foundation
import Combine
import SwiftUI

final class AnalyticsFilter: ObservableObject, Codable {
  @Published var v: Int = 1
  @Published var from: Date
  @Published var to: Date
  @Published var compare: Bool = false
  @Published var machines: [String] = []
  @Published var channels: [String] = []
  @Published var categories: [String] = []
  @Published var vatRates: [Double] = []

  static let defaultValue: AnalyticsFilter = {
    let f = AnalyticsFilter()
    f.from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    f.to = Date()
    return f
  }()

  init() {
    self.from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    self.to = Date()
  }

  enum CodingKeys: String, CodingKey {
    case v, from, to, compare, machines, channels, categories, vatRates
  }

  required init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.v = 1   // always clamp
    self.from = try c.decode(Date.self, forKey: .from)
    self.to = try c.decode(Date.self, forKey: .to)
    self.compare = (try? c.decode(Bool.self, forKey: .compare)) ?? false
    self.machines = (try? c.decode([String].self, forKey: .machines)) ?? []
    self.channels = (try? c.decode([String].self, forKey: .channels)) ?? []
    self.categories = (try? c.decode([String].self, forKey: .categories)) ?? []
    self.vatRates = (try? c.decode([Double].self, forKey: .vatRates)) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(1, forKey: .v)
    try c.encode(from, forKey: .from)
    try c.encode(to, forKey: .to)
    try c.encode(compare, forKey: .compare)
    try c.encode(machines, forKey: .machines)
    try c.encode(channels, forKey: .channels)
    try c.encode(categories, forKey: .categories)
    try c.encode(vatRates, forKey: .vatRates)
  }
}
```

- [ ] **Step 4: Run test — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add ios/VMflow/Models/AnalyticsFilter.swift ios/VMflowTests/AnalyticsFilterTests.swift
git commit -m "feat(ios): AnalyticsFilter model with Codable + unknown-key drop + v clamp"
```

### Task 5.3: Implement `AnalyticsRootView` adaptive layout + section picker

**Files:**
- Modify: `ios/VMflow/Views/Analytics/AnalyticsRootView.swift`
- Create: `ios/VMflow/Views/Analytics/AnalyticsFilterSheet.swift`

- [ ] **Step 1: Replace placeholder with adaptive layout**

```swift
// ios/VMflow/Views/Analytics/AnalyticsRootView.swift
import SwiftUI

enum AnalyticsSection: String, CaseIterable, Identifiable {
  case overview, sales, products, machines, conversion, operations
  var id: String { rawValue }
  var label: String {
    switch self {
    case .overview:   "Overview"
    case .sales:      "Sales"
    case .products:   "Products"
    case .machines:   "Machines"
    case .conversion: "Conversion"
    case .operations: "Operations"
    }
  }
  var icon: String {
    switch self {
    case .overview:   "chart.bar.fill"
    case .sales:      "eurosign.circle.fill"
    case .products:   "cube.box.fill"
    case .machines:   "storefront.fill"
    case .conversion: "figure.walk.motion"
    case .operations: "gauge.with.dots.needle.bottom.50percent"
    }
  }
}

struct AnalyticsRootView: View {
  @StateObject private var filter = AnalyticsFilter.defaultValue
  @State private var selectedSection: AnalyticsSection = .overview
  @State private var filterSheetPresented = false
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    Group {
      if sizeClass == .regular {
        // iPad / Mac: NavigationSplitView with section list
        NavigationSplitView {
          List(AnalyticsSection.allCases, selection: $selectedSection) { section in
            Label(section.label, systemImage: section.icon).tag(section)
          }
          .navigationTitle("Analytics")
        } detail: {
          sectionView
            .navigationTitle(selectedSection.label)
        }
      } else {
        // iPhone: single screen with horizontal section picker
        VStack(spacing: 0) {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(AnalyticsSection.allCases) { section in
                Button {
                  selectedSection = section
                } label: {
                  Label(section.label, systemImage: section.icon)
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(selectedSection == section ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSection == section ? Color.accentColor : .primary)
              }
            }
            .padding(.horizontal)
          }
          .padding(.vertical, 8)
          .background(.bar)

          sectionView
        }
        .navigationTitle("Analytics")
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              filterSheetPresented = true
            } label: {
              Image(systemName: "line.3.horizontal.decrease.circle")
            }
          }
        }
        .sheet(isPresented: $filterSheetPresented) {
          AnalyticsFilterSheet()
            .environmentObject(filter)
            .presentationDetents([.medium, .large])
        }
      }
    }
    .environmentObject(filter)
  }

  @ViewBuilder
  private var sectionView: some View {
    switch selectedSection {
    case .overview:   AnalyticsOverviewView()
    case .sales:      Text("Sales — coming soon")
    case .products:   Text("Products — coming soon")
    case .machines:   Text("Machines — coming soon")
    case .conversion: Text("Conversion — coming soon")
    case .operations: Text("Operations — coming soon")
    }
  }
}
```

- [ ] **Step 2: Create AnalyticsFilterSheet placeholder**

```swift
// ios/VMflow/Views/Analytics/AnalyticsFilterSheet.swift
import SwiftUI

struct AnalyticsFilterSheet: View {
  @EnvironmentObject var filter: AnalyticsFilter
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Date range") {
          DatePicker("From", selection: $filter.from, displayedComponents: .date)
          DatePicker("To",   selection: $filter.to,   displayedComponents: .date)
          Toggle("Compare period", isOn: $filter.compare)
        }
        // TODO: Machines / Channels / Categories / VAT rates pickers (Chunk 6)
      }
      .navigationTitle("Filters")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Reset") { /* reset to defaults */ }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }.fontWeight(.semibold)
        }
      }
    }
  }
}
```

- [ ] **Step 3: Build and run on simulator**

```bash
cd ios && xcodebuild build -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 15'
```

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/Views/Analytics/AnalyticsRootView.swift \
        ios/VMflow/Views/Analytics/AnalyticsFilterSheet.swift
git commit -m "feat(ios): AnalyticsRootView adaptive (iPhone picker / iPad split) + filter sheet"
```

### Task 5.4: Build shared analytics components

**Files:**
- Create: `ios/VMflow/Views/Analytics/Components/AnalyticsKPIGroup.swift`
- Create: `ios/VMflow/Views/Analytics/Components/AnalyticsChart.swift`
- Create: `ios/VMflow/Views/Analytics/Components/AnalyticsSortableList.swift`
- Create: `ios/VMflow/Views/Analytics/Components/ComparePeriodBadge.swift`
- Create: `ios/VMflow/Views/Analytics/Components/AnalyticsHeatmap.swift`

- [ ] **Step 1: AnalyticsKPIGroup** — wraps the existing `KPICard` in a 2×2 grid (compact) or 1×N flex (regular). Accepts `[KPI]` where `KPI` is `(label: String, value: Double, deltaPct: Double?, format: KPIFormat)`. Reuse `KPICard` from `Components/KPICard.swift`.

- [ ] **Step 2: AnalyticsChart** — wraps SwiftUI Charts. Accepts `[ChartPoint]` with `chartXSelection`, `chartScrollableAxes(.horizontal)`, `chartXVisibleDomain(length: 30 * 86400)`. Mirror the patterns from `DashboardView.swift`.

- [ ] **Step 3: AnalyticsSortableList** — `List` that supports tap-to-sort columns. Generic over a row type with a closure `{ row, columnKey -> AnyView }` for cell rendering. Includes `.swipeActions` slot for drill-through.

- [ ] **Step 4: ComparePeriodBadge** — small `Text` view with leading arrow icon (`arrow.up.right` / `arrow.down.right`) colored green/red based on sign. Format: `+12,3%` or `−8,1%` with locale-aware decimal.

- [ ] **Step 5: AnalyticsHeatmap** — grid view: 24 columns (hours) × 7 rows (weekdays) for `dimension == 'hour'×'dow'`, otherwise the input dimension. Each cell colored on a green→red gradient by value-relative-to-max. Accepts `cells: [[Double]]` (rows × cols) and `rowLabels`, `colLabels`.

- [ ] **Step 6: Commit each component**

```bash
git add ios/VMflow/Views/Analytics/Components/AnalyticsKPIGroup.swift
git commit -m "feat(ios): AnalyticsKPIGroup adaptive 2×2/1×N grid"
# repeat per file
```

### Task 5.5: Implement `AnalyticsOverviewView` + ViewModel

**Files:**
- Create: `ios/VMflow/ViewModels/AnalyticsOverviewViewModel.swift`
- Create: `ios/VMflow/Views/Analytics/Sections/AnalyticsOverviewView.swift`

- [ ] **Step 1: ViewModel — fetches `analytics_overview` via `SupabaseService`**

```swift
// ios/VMflow/ViewModels/AnalyticsOverviewViewModel.swift
import Foundation
import Combine

@MainActor
final class AnalyticsOverviewViewModel: ObservableObject {
  @Published var data: AnalyticsOverviewData?
  @Published var isLoading = false
  @Published var error: String?
  @Published var hasNewData = false  // realtime hint banner

  private var cancellables = Set<AnyCancellable>()
  private weak var filter: AnalyticsFilter?

  func bind(filter: AnalyticsFilter) {
    self.filter = filter
    filter.objectWillChange
      .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in Task { await self?.load() } }
      .store(in: &cancellables)
  }

  // Match the existing iOS RPC pattern (see CashBookViewModel.swift:154-171,
  // ProductDetailSheet.swift, RefillWizardViewModel.swift):
  //   SupabaseService.shared.client.rpc(name, params: TypedStruct)
  //     .execute()
  //     .value
  // — typed Encodable struct, NOT [String: Any].
  struct Params: Encodable {
    let p_company_id: UUID
    let p_from: Date
    let p_to: Date
    let p_compare_from: Date?
    let p_compare_to: Date?
    let p_machine_ids: [UUID]
    let p_channels: [String]
    let p_category_ids: [UUID]
    let p_vat_rates: [Double]
  }

  func load() async {
    guard let filter else { return }
    guard let companyIdStr = AuthService.shared.organization?.id,
          let companyId = UUID(uuidString: companyIdStr) else { return }

    isLoading = true
    error = nil
    defer { isLoading = false }

    let params = Params(
      p_company_id:    companyId,
      p_from:          filter.from,
      p_to:            filter.to,
      p_compare_from:  filter.compare ? Calendar.current.date(byAdding: .day, value: -Calendar.current.dateComponents([.day], from: filter.from, to: filter.to).day!, to: filter.from) : nil,
      p_compare_to:    filter.compare ? filter.from : nil,
      p_machine_ids:   filter.machines.compactMap(UUID.init),
      p_channels:      filter.channels,
      p_category_ids:  filter.categories.compactMap(UUID.init),
      p_vat_rates:     filter.vatRates
    )

    do {
      let result: AnalyticsOverviewData = try await SupabaseService.shared.client
        .rpc("analytics_overview", params: params)
        .execute()
        .value
      self.data = result
      self.hasNewData = false
    } catch {
      self.error = error.localizedDescription
    }
  }

  func subscribeRealtime() {
    RealtimeService.shared.$salesVersion
      .dropFirst()
      .sink { [weak self] _ in self?.hasNewData = true }
      .store(in: &cancellables)
  }
}

struct AnalyticsOverviewData: Codable {
  let version: Int
  let kpis: KPIs
  let kpisCompare: KPIs?
  let dailySeries: [DailyPoint]
  let topProducts: [TopProductRow]
  let topMachines: [TopMachineRow]

  enum CodingKeys: String, CodingKey {
    case version, kpis
    case kpisCompare = "kpis_compare"
    case dailySeries = "daily_series"
    case topProducts = "top_products"
    case topMachines = "top_machines"
  }

  struct KPIs: Codable {
    let revenue: Double
    let units: Int
    let avgBasket: Double
    let conversionPct: Double?
    enum CodingKeys: String, CodingKey {
      case revenue, units
      case avgBasket = "avg_basket"
      case conversionPct = "conversion_pct"
    }
  }
  struct DailyPoint: Codable {
    let date: String  // 'YYYY-MM-DD' from jsonb
    let revenue: Double
    let units: Int
  }
  struct TopProductRow: Codable {
    let productId: UUID
    let name: String
    let imagePath: String?
    let units: Int
    let revenue: Double
    let mixPct: Double
    enum CodingKeys: String, CodingKey {
      case productId = "product_id"
      case name; case imagePath = "image_path"
      case units; case revenue
      case mixPct = "mix_pct"
    }
  }
  struct TopMachineRow: Codable {
    let machineId: UUID
    let name: String
    let status: String?
    let revenue: Double
    enum CodingKeys: String, CodingKey {
      case machineId = "machine_id"
      case name; case status; case revenue
    }
  }
}
```

- [ ] **Step 2: View**

```swift
// ios/VMflow/Views/Analytics/Sections/AnalyticsOverviewView.swift
import SwiftUI
import Charts

struct AnalyticsOverviewView: View {
  @EnvironmentObject var filter: AnalyticsFilter
  @StateObject private var viewModel = AnalyticsOverviewViewModel()

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        // Realtime hint banner
        if viewModel.hasNewData {
          HStack {
            Image(systemName: "arrow.clockwise")
            Text("Neue Daten verfügbar")
            Spacer()
            Button("Aktualisieren") { Task { await viewModel.load() } }
          }
          .padding()
          .background(.thinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .padding(.horizontal)
        }

        // KPIs
        if let data = viewModel.data {
          AnalyticsKPIGroup(kpis: [
            .init(label: "Revenue",     value: data.kpis.revenue,        deltaPct: data.kpisCompare.map { (data.kpis.revenue - $0.revenue) / $0.revenue * 100 }, format: .currency),
            .init(label: "Units",       value: Double(data.kpis.units),  deltaPct: nil, format: .number),
            .init(label: "Avg basket",  value: data.kpis.avgBasket,      deltaPct: nil, format: .currency),
            .init(label: "Conversion",  value: data.kpis.conversionPct,  deltaPct: nil, format: .percent),
          ])

          // Daily chart
          AnalyticsChart(data: data.dailySeries.map { ChartPoint(x: $0.date, y: $0.revenue) })
            .frame(height: 240)
            .padding(.horizontal)

          // Top products + top machines (use AnalyticsSortableList)
          // …
        }
      }
      .padding(.vertical)
    }
    .refreshable { await viewModel.load() }
    .task {
      viewModel.bind(filter: filter)
      viewModel.subscribeRealtime()
      await viewModel.load()
    }
  }
}
```

- [ ] **Step 3: Build + run**

```bash
cd ios && xcodebuild build -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 15'
```

- [ ] **Step 4: Manual smoke test on simulator**

Open the app, navigate More → Analytics → Overview. Expect: KPI grid, daily chart, top tables. Filter sheet works. Pull-to-refresh works. New-sale realtime banner appears when a new sale comes in.

- [ ] **Step 5: Commit**

```bash
git add ios/VMflow/ViewModels/AnalyticsOverviewViewModel.swift \
        ios/VMflow/Views/Analytics/Sections/AnalyticsOverviewView.swift
git commit -m "feat(ios): AnalyticsOverviewView with KPIs + chart + realtime hint banner"
```

### Chunk 5 — Done When

- [ ] Project builds without errors on iPhone + iPad simulators
- [ ] `XCTest VMflowTests/AnalyticsFilterTests` passes
- [ ] iPhone path: More → Analytics → Overview renders fully with real data
- [ ] iPad path: Sidebar → Analytics → Overview renders in NavigationSplitView
- [ ] Filter sheet opens, date pickers work, changes trigger Overview reload (debounced 300 ms)
- [ ] Pull-to-refresh works
- [ ] Realtime hint banner appears on a new Sale INSERT (test by inserting a sale via Studio or psql)

---

## Chunk 6: Phase 5b — Remaining Five iOS Sections

**Goal:** Implement the five remaining iOS section views, each with its own ViewModel. Each view follows the AnalyticsOverviewView pattern: bind filter, fetch via `SupabaseService.rpc`, render via shared analytics components.

**Files:**
- Create: `ios/VMflow/ViewModels/AnalyticsSalesViewModel.swift`
- Create: `ios/VMflow/ViewModels/AnalyticsProductsViewModel.swift`
- Create: `ios/VMflow/ViewModels/AnalyticsMachinesViewModel.swift`
- Create: `ios/VMflow/ViewModels/AnalyticsConversionViewModel.swift`
- Create: `ios/VMflow/ViewModels/AnalyticsOperationsViewModel.swift`
- Create: `ios/VMflow/Views/Analytics/Sections/AnalyticsSalesView.swift`
- Create: `ios/VMflow/Views/Analytics/Sections/AnalyticsProductsView.swift`
- Create: `ios/VMflow/Views/Analytics/Sections/AnalyticsMachinesView.swift`
- Create: `ios/VMflow/Views/Analytics/Sections/AnalyticsConversionView.swift`
- Create: `ios/VMflow/Views/Analytics/Sections/AnalyticsOperationsView.swift`
- Create: `ios/VMflow/Views/Analytics/AnalyticsCompareView.swift` (Machines tab uses this)
- Modify: `ios/VMflow/Views/Analytics/AnalyticsRootView.swift` (replace "coming soon" placeholders)

### Task 6.1: AnalyticsSalesView with dimension picker

- [ ] **Step 1: ViewModel** — like `AnalyticsOverviewViewModel` but with an extra `@Published var dimension: String = "machine"` that triggers reload via `objectWillChange.combineLatest(...)`.
- [ ] **Step 2: View** — section picker as horizontal `ScrollView(.horizontal)` of capsule buttons (7 dimensions). For `hour` / `dow`, render `AnalyticsHeatmap` instead of `AnalyticsChart`.
- [ ] **Step 3: Wire into `AnalyticsRootView`** — replace `case .sales: Text(...)` with `AnalyticsSalesView()`
- [ ] **Step 4: Commit**

### Task 6.2: AnalyticsProductsView

- [ ] Same pattern. `.searchable` for product name search. `Menu` toolbar for category / status sub-filters.
- [ ] Drill-through: tap row name → push `ProductDetailSheet(productId:)`
- [ ] Commit

### Task 6.3: AnalyticsMachinesView + AnalyticsCompareView

- [ ] **Step 1: AnalyticsMachinesView** — list of machines with revenue, conversion, last-sale-gap, status. Compare button → opens `AnalyticsCompareView` modal.
- [ ] **Step 2: AnalyticsCompareView** — on iPhone: stepwise picker (machine A → machine B → diff view). On iPad: multi-select inline with up to 4 machines side-by-side via `HStack`.
- [ ] **Step 3: NO geo map on iPhone V1** (per spec); iPad gets one — wrap `MapKit` Map view, add bubble annotations
- [ ] **Step 4: Commit each separately**

### Task 6.4: AnalyticsConversionView

- [ ] iPad: full heatmap view via `AnalyticsHeatmap` with machines × hour grid.
- [ ] iPhone: simplified — list with conversion-rate horizontal bar per machine.
- [ ] Scatter plot: use SwiftUI Charts `PointMark`, with reference line at fleet-avg conversion.
- [ ] Commit.

### Task 6.5: AnalyticsOperationsView

- [ ] List of stockout events with `.swipeActions` ("Plan tour", "Mark resolved").
- [ ] Refill tours collapsible per day (use `DisclosureGroup`).
- [ ] Stock-cover-days table with red-highlighting for `cover_days < 3`.
- [ ] Pre-migration banner (date < migration timestamp).
- [ ] Commit.

### Chunk 6 — Done When

- [ ] All 6 iOS sections render fully with real data
- [ ] iPhone heatmap fallback (Conversion) renders as bar list
- [ ] AnalyticsCompareView works on iPhone (stepwise) and iPad (parallel)
- [ ] All sections trigger reload on filter change
- [ ] No regressions on `xcodebuild test`

---

## Chunk 7: Phase 6 — Polish & Release

**Goal:** Wire up i18n strings, CSV export buttons, PNG chart snapshot (web), remove duplicate AI insights mount from `/`, run all tests, update docs, verify on real-data set.

**Files:**
- Modify: `management-frontend/i18n/locales/de.json` + `en.json` — add `analytics.*` namespace
- Modify: `ios/VMflow/Resources/Localizable.xcstrings` — add `analytics.*` keys
- Modify: `management-frontend/app/components/analytics/AnalyticsTable.vue` — wire CSV download button
- Modify: `management-frontend/app/components/analytics/AnalyticsChart.vue` — add PNG export button
- Modify: `management-frontend/app/pages/index.vue` — remove `<CompanyInsights />` mount (Phase 6 step 18)
- Modify: `CLAUDE.md` — final analytics section update
- New: `package.json` — add `html-to-image` dep (web)

### Task 7.1: i18n strings (web)

- [ ] **Step 1: Add `analytics.*` keys to `de.json`**

```json
"analytics": {
  "title": "Analytics",
  "kpi": {
    "revenue": "Umsatz",
    "units": "Stück",
    "avgBasket": "Ø Bonwert",
    "conversion": "Conversion",
    "salesCount": "Verkäufe"
  },
  "dimension": {
    "machine": "Automat",
    "product": "Produkt",
    "category": "Kategorie",
    "channel": "Channel",
    "vat": "MwSt-Satz",
    "hour": "Stunde",
    "dow": "Wochentag"
  },
  "label": "Bezeichnung",
  "revenue": "Umsatz",
  "units": "Stück",
  "avgBasket": "Ø Bonwert",
  "shareRevenue": "Anteil Umsatz",
  "shareUnits": "Anteil Stück",
  "machine": "Automat",
  "product": "Produkt",
  "mix": "Mix",
  "overview": {
    "dailySeriesTitle": "Tagesumsatz",
    "topProducts": "Top 5 Produkte",
    "topMachines": "Top 5 Automaten"
  },
  "sales": {
    "byDimension": "Umsatz nach {dim}"
  },
  "operations": {
    "stockoutsBeforeBanner": "Stockout-Daten verfügbar ab {date}"
  },
  "filterBar": {
    "today": "Heute",
    "last7d": "7 Tage",
    "last30d": "30 Tage",
    "last90d": "90 Tage",
    "ytd": "YTD",
    "last12m": "12 Monate",
    "custom": "Eigener",
    "comparePeriod": "Vorperiode anzeigen",
    "reset": "Zurücksetzen",
    "savePreset": "Als Preset speichern",
    "presetMenu": "Presets"
  }
}
```

- [ ] **Step 2: Mirror to `en.json`**

- [ ] **Step 3: Verify translations in dev**

```bash
cd management-frontend && npm run dev
```

Visit `/analytics` in both `de` and `en`, confirm all labels translate.

- [ ] **Step 4: Commit `feat(analytics): i18n strings for /analytics (de + en)`**

### Task 7.2: i18n strings (iOS)

- [ ] **Step 1: Add keys to `Localizable.xcstrings`** matching the web namespace structure (use `analytics.title`, `analytics.kpi.revenue`, etc.)
- [ ] **Step 2: Verify via simulator language switch**
- [ ] **Step 3: Commit `feat(ios): localize Analytics strings`**

### Task 7.3: CSV export buttons

- [ ] **Step 1: Add `Download CSV` button to each `AnalyticsTable` instance** — wires `useAnalyticsExport().rowsToCsv()` and `download()` with the locale-aware filename `vmflow-analytics-{tab}-{from}-{to}.csv`
- [ ] **Step 2: Smoke-test** on Sales tab — download a CSV, open in Excel, confirm German decimal separators and `;` delimiter
- [ ] **Step 3: Commit `feat(analytics): CSV export per tab`**

### Task 7.4: PNG chart snapshot (web only)

- [ ] **Step 1: Add `html-to-image` dependency**

```bash
cd management-frontend && npm install html-to-image
```

- [ ] **Step 2: Add a `Download PNG` button to `AnalyticsChart.vue`** that calls `htmlToImage.toPng(chartRef.value)` and triggers download
- [ ] **Step 3: Smoke-test on Overview tab — download a PNG, open it**
- [ ] **Step 4: Commit `feat(analytics): PNG chart snapshot via html-to-image (web)`**

### Task 7.5: Remove duplicate AI insights from `/` Dashboard

**Files:**
- Modify: `management-frontend/app/pages/index.vue`

- [ ] **Step 1: Remove `<CompanyInsights />` and surrounding `<div class="px-4 lg:px-6">…</div>`** that wraps it
- [ ] **Step 2: Remove the import line** `import CompanyInsights from '@/components/CompanyInsights.vue'`
- [ ] **Step 3: Verify `/` still works** (should look like dashboard before AI insights existed; the rest of the dashboard is unchanged)
- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/pages/index.vue
git commit -m "refactor(dashboard): remove duplicate AI insights — now lives only in /analytics

The CompanyInsights component is unchanged and still renders in
TabOverview. Phase 6 step 18 of the analytics plan."
```

### Task 7.6: Update CLAUDE.md (final)

- [ ] **Step 1: Add a new "Analytics page" section under "Frontend Pages"** with a brief description
- [ ] **Step 2: Add `useAnalyticsFilters / useAnalyticsData / useAnalyticsExport`** to the composables list
- [ ] **Step 3: Confirm `tray_stockout_events` and the six RPCs are in the schema sections** (already added in Chunks 1 + 2)
- [ ] **Step 4: Commit `docs: document analytics page + composables in CLAUDE.md`**

### Task 7.7: Full test suite + verification on real-data set

- [ ] **Step 1: Run all tests**

```bash
bash Docker/supabase/tests/run-sql-tests.sh
cd management-frontend && npx vitest run
cd ../ios && xcodebuild test -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: all green.

- [ ] **Step 2: Manual end-to-end on staging or production-like data set**

- Visit `/analytics`, exercise each tab and filter
- Save a preset, reload page, verify it loads
- Share a URL with `?f=...`, open in incognito, verify filter state restores
- Switch to dark mode, verify contrast
- Open the iOS app on simulator, exercise each section, confirm filter persistence via app restart

- [ ] **Step 3: Commit nothing for this step — it's verification, not code**

If any issue surfaces, fix it as a separate targeted commit and reference this verification step in the message.

### Chunk 7 — Done When

- [ ] All i18n keys present in de + en (web) + xcstrings (iOS)
- [ ] CSV downloads work on every tab in both German and English locales
- [ ] PNG chart snapshot works on web
- [ ] `/` Dashboard no longer renders AI insights; `/analytics#overview` does
- [ ] All test suites green
- [ ] Manual E2E verification done on real data
- [ ] CLAUDE.md final update committed

---

## Plan-Level Done When

- [ ] Chunks 1–7 each pass their own "Done When"
- [ ] Both migrations (`20260509000000_analytics_stockout_events.sql` and `20260509000100_analytics_rpcs.sql`) applied successfully via `supabase migration up` on dev DB
- [ ] Web `/analytics` ships all six tabs with the global filter bar
- [ ] iOS Analytics ships all six sections with adaptive layout
- [ ] AI insights migrated from `/` to `/analytics#overview`
- [ ] No regressions on existing tests (Vitest, SQL, XCTest)
- [ ] CLAUDE.md updated with new tables, RPCs, page, composables
- [ ] No `supabase db reset` was ever invoked

