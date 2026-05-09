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
