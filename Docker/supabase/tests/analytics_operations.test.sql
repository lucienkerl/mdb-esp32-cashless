-- Docker/supabase/tests/analytics_operations.test.sql
-- Failing tests for analytics_operations RPC (TDD: RPC does not exist yet).
-- Expected failure: ERROR: function analytics_operations(...) does not exist
-- After Task 2.3 migration these must all pass.

BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $$
DECLARE
  v_company_a   uuid := gen_random_uuid();
  v_company_b   uuid := gen_random_uuid();
  v_user_a      uuid := gen_random_uuid();
  v_user_b      uuid := gen_random_uuid();
  v_machine_a   uuid := gen_random_uuid();
  v_product_a   uuid := gen_random_uuid();
  v_tray_a      uuid;
  v_stockout_id uuid;
  v_tour_id     text := gen_random_uuid()::text;
  v_result      jsonb;
  v_kpis        jsonb;
  v_stockouts   jsonb;
  v_tours       jsonb;
  v_stock_cover jsonb;
  v_so_entry    jsonb;
  v_tour_entry  jsonb;
  v_stockout_hrs numeric;
  v_lost_rev    numeric;
  v_tour_count  int;
BEGIN
  -- Two companies
  INSERT INTO public.companies (id, name) VALUES (v_company_a, 'OperationsA');
  INSERT INTO public.companies (id, name) VALUES (v_company_b, 'OperationsB');

  -- Auth users
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_a, '00000000-0000-0000-0000-000000000000', 'opa@t.local', now());
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_b, '00000000-0000-0000-0000-000000000000', 'opb@t.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_a, v_company_a, 'opa@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_b, v_company_b, 'opb@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_a, v_user_a, 'admin'),
           (v_company_b, v_user_b, 'admin');

  -- Product + machine + tray for company_a
  INSERT INTO public.products (id, name, sellprice, company)
    VALUES (v_product_a, 'OpSnack', 2.00, v_company_a);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine_a, 'OpMachA', v_company_a);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine_a, 1, v_product_a, 10, 5)
    RETURNING id INTO v_tray_a;

  -- Seed a closed stockout event (≈1 hour duration)
  -- duration_seconds is GENERATED from (ended_at - started_at), so don't INSERT it.
  INSERT INTO public.tray_stockout_events
    (tray_id, machine_id, item_number, product_id,
     started_at, ended_at,
     lost_units_estimated, lost_revenue_estimated,
     company_id)
  VALUES
    (v_tray_a, v_machine_a, 1, v_product_a,
     now() - interval '2 hours',
     now() - interval '1 hour',
     1.5, 3.0,
     v_company_a)
  RETURNING id INTO v_stockout_id;

  -- Seed a refill tour in activity_log (action = 'stock_refill_tour').
  -- Backdate created_at so it falls strictly inside the [p_from, p_to) window
  -- the RPC uses. Inside a BEGIN/ROLLBACK transaction now() is fixed, so an
  -- INSERT with default created_at = now() would equal p_to and fail the
  -- strict-less-than filter.
  INSERT INTO public.activity_log
    (created_at, company_id, user_id, entity_type, entity_id, action, metadata)
  VALUES
    (now() - interval '1 hour',
     v_company_a, v_user_a, 'stock', v_machine_a::text, 'stock_refill_tour',
     jsonb_build_object(
       'tour_id',       v_tour_id,
       'machine_id',    v_machine_a,
       'machine_name',  'OpMachA',
       'total_added',   10,
       'trays_refilled', 1,
       '_user_display', 'Test Operator'
     ));

  -- Authenticate as company_a
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text,
    true);

  SELECT public.analytics_operations(
    v_company_a,
    now() - interval '7 days', now(),
    NULL, NULL,
    NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
  ) INTO v_result;

  -- ─── Test 3.22: version=1, kpis present ──────────────────────────────────────
  ASSERT (v_result->>'version')::int = 1,
    format('3.22: version must be 1, got %s', v_result->>'version');

  v_kpis := v_result->'kpis';
  ASSERT v_kpis IS NOT NULL, '3.22: kpis must be present';

  RAISE NOTICE 'Test 3.22 (analytics_operations: version=1, kpis present) PASSED';

  -- ─── Test 3.23: kpis.stockout_hours ≈ 1.0 ────────────────────────────────────
  v_stockout_hrs := (v_kpis->>'stockout_hours')::numeric;
  ASSERT ABS(v_stockout_hrs - 1.0) <= 0.1,
    format('3.23: stockout_hours should be ≈1.0 (1 hour event), got %s', v_stockout_hrs);

  RAISE NOTICE 'Test 3.23 (kpis.stockout_hours ≈ 1.0) PASSED';

  -- ─── Test 3.24: kpis.lost_revenue ≈ 3.0 ─────────────────────────────────────
  v_lost_rev := (v_kpis->>'lost_revenue')::numeric;
  ASSERT ABS(v_lost_rev - 3.0) <= 0.01,
    format('3.24: lost_revenue should be ≈3.0, got %s', v_lost_rev);

  RAISE NOTICE 'Test 3.24 (kpis.lost_revenue ≈ 3.0) PASSED';

  -- ─── Test 3.25: kpis.refill_tour_count >= 1 ──────────────────────────────────
  v_tour_count := (v_kpis->>'refill_tour_count')::int;
  ASSERT v_tour_count >= 1,
    format('3.25: refill_tour_count must be >= 1, got %s', v_tour_count);

  RAISE NOTICE 'Test 3.25 (kpis.refill_tour_count >= 1) PASSED';

  -- ─── Test 3.26: stockout_events[] includes the seeded event ──────────────────
  v_stockouts := v_result->'stockout_events';
  ASSERT v_stockouts IS NOT NULL, '3.26: stockout_events must be present';
  ASSERT jsonb_array_length(v_stockouts) >= 1,
    format('3.26: stockout_events must have >= 1 entry, got %s', jsonb_array_length(v_stockouts));

  -- Find our specific event
  SELECT elem INTO v_so_entry
  FROM jsonb_array_elements(v_stockouts) elem
  WHERE (elem->>'id')::uuid = v_stockout_id;

  ASSERT v_so_entry IS NOT NULL,
    format('3.26: seeded stockout event (%s) must appear in stockout_events[]', v_stockout_id);
  ASSERT (v_so_entry->>'duration_seconds')::int IS NOT NULL,
    '3.26: duration_seconds must be non-null in the event row';
  ASSERT (v_so_entry->>'lost_units_estimated')::numeric IS NOT NULL,
    '3.26: lost_units_estimated must be non-null in the event row';

  RAISE NOTICE 'Test 3.26 (stockout_events[] includes seeded event with duration and loss) PASSED';

  -- ─── Test 3.27: refill_tours[] includes the seeded tour ──────────────────────
  v_tours := v_result->'refill_tours';
  ASSERT v_tours IS NOT NULL, '3.27: refill_tours must be present';
  ASSERT jsonb_array_length(v_tours) >= 1,
    format('3.27: refill_tours must have >= 1 entry, got %s', jsonb_array_length(v_tours));

  SELECT elem INTO v_tour_entry
  FROM jsonb_array_elements(v_tours) elem
  WHERE elem->>'tour_id' = v_tour_id;

  ASSERT v_tour_entry IS NOT NULL,
    format('3.27: seeded tour_id (%s) must appear in refill_tours[]', v_tour_id);

  RAISE NOTICE 'Test 3.27 (refill_tours[] includes seeded tour) PASSED';

  -- ─── Test 3.28: stock_cover is an array (non-null) ────────────────────────────
  v_stock_cover := v_result->'stock_cover';
  ASSERT v_stock_cover IS NOT NULL, '3.28: stock_cover must be present';
  ASSERT jsonb_typeof(v_stock_cover) = 'array', '3.28: stock_cover must be a JSON array';

  -- We seeded 1 tray → stock_cover should have at least 1 entry
  ASSERT jsonb_array_length(v_stock_cover) >= 1,
    format('3.28: stock_cover should be non-empty (seeded 1 tray), got length %s',
           jsonb_array_length(v_stock_cover));

  RAISE NOTICE 'Test 3.28 (stock_cover is a non-empty array) PASSED';

  -- ─── Test 3.29: cross-company isolation ───────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text,
    true);

  BEGIN
    SELECT public.analytics_operations(
      v_company_a,   -- asking for A while authenticated as B
      now() - interval '7 days', now(),
      NULL, NULL,
      NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
    ) INTO v_result;
    ASSERT FALSE, '3.29: expected cross-company access to raise';
  EXCEPTION
    WHEN OTHERS THEN
      ASSERT SQLERRM ILIKE '%company%' OR SQLERRM ILIKE '%permission%' OR SQLERRM ILIKE '%not allowed%',
        format('3.29: expected company-mismatch error, got: %s', SQLERRM);
  END;

  RAISE NOTICE 'Test 3.29 (cross-company access denied) PASSED';
END;
$$;

ROLLBACK;
