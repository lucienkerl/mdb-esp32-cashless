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

(Chunks 2–7 follow in subsequent edits to this plan.)
