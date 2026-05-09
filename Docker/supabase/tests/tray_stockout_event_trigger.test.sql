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

ROLLBACK;
