-- Docker/supabase/tests/analytics_machines.test.sql
-- Failing tests for analytics_machines RPC (TDD: RPC does not exist yet).
-- Expected failure: ERROR: function analytics_machines(...) does not exist
-- After Task 2.3 migration these must all pass.

BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $$
DECLARE
  v_company_a    uuid := gen_random_uuid();
  v_company_b    uuid := gen_random_uuid();
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_machine_1    uuid := gen_random_uuid();  -- has sales
  v_machine_2    uuid := gen_random_uuid();  -- no sales
  v_product_1    uuid := gen_random_uuid();
  v_result       jsonb;
  v_kpis         jsonb;
  v_machines     jsonb;
  v_heatmaps     jsonb;
  v_mach_count   int;
  v_best_id      uuid;
  v_dow_arr      jsonb;
  v_hour_arr     jsonb;
BEGIN
  -- Two companies
  INSERT INTO public.companies (id, name) VALUES (v_company_a, 'MachinesA');
  INSERT INTO public.companies (id, name) VALUES (v_company_b, 'MachinesB');

  -- Auth users
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_a, '00000000-0000-0000-0000-000000000000', 'maa@t.local', now());
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_b, '00000000-0000-0000-0000-000000000000', 'mab@t.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_a, v_company_a, 'maa@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_b, v_company_b, 'mab@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_a, v_user_a, 'admin'),
           (v_company_b, v_user_b, 'admin');

  -- Product for company_a
  INSERT INTO public.products (id, name, sellprice, company)
    VALUES (v_product_1, 'MachSnack', 2.00, v_company_a);

  -- Two machines with location coordinates (München)
  INSERT INTO public."vendingMachine" (id, name, company, location_lat, location_lon)
    VALUES (v_machine_1, 'MachSales',   v_company_a, 48.137, 11.575),
           (v_machine_2, 'MachEmpty',   v_company_a, 48.140, 11.580);

  -- Trays for both machines
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine_1, 1, v_product_1, 10, 8),
           (v_machine_2, 1, v_product_1, 10, 8);

  -- Sales only for machine_1 (revenue = 10.00)
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine_1, 1, 2.00, 'cashless', now() - interval '1 day'),
           (v_machine_1, 1, 2.00, 'cashless', now() - interval '2 days'),
           (v_machine_1, 1, 2.00, 'cashless', now() - interval '3 days'),
           (v_machine_1, 1, 2.00, 'cashless', now() - interval '4 days'),
           (v_machine_1, 1, 2.00, 'cashless', now() - interval '5 days');

  -- Authenticate as company_a
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text,
    true);

  SELECT public.analytics_machines(
    v_company_a,
    now() - interval '30 days', now(),
    NULL, NULL,
    NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
  ) INTO v_result;

  -- ─── Test 3.11: version=1, kpis present ──────────────────────────────────────
  ASSERT (v_result->>'version')::int = 1,
    format('3.11: version must be 1, got %s', v_result->>'version');

  v_kpis := v_result->'kpis';
  ASSERT v_kpis IS NOT NULL, '3.11: kpis must be present';

  RAISE NOTICE 'Test 3.11 (analytics_machines: version=1, kpis present) PASSED';

  -- ─── Test 3.12: best_machine_id matches machine_1 (the one with sales) ────────
  v_best_id := (v_kpis->>'best_machine_id')::uuid;
  ASSERT v_best_id = v_machine_1,
    format('3.12: best_machine_id should be v_machine_1 (%s), got %s', v_machine_1, v_best_id);

  RAISE NOTICE 'Test 3.12 (best_machine_id = machine with sales) PASSED';

  -- ─── Test 3.13: machines[] includes both machines ─────────────────────────────
  v_machines   := v_result->'machines';
  v_mach_count := jsonb_array_length(v_machines);
  ASSERT v_mach_count = 2,
    format('3.13: expected 2 machine entries, got %s', v_mach_count);

  RAISE NOTICE 'Test 3.13 (machines[] has 2 entries including zero-sales machine) PASSED';

  -- ─── Test 3.14: heatmaps object, each machine has dow[7] and hour[24] ─────────
  v_heatmaps := v_result->'heatmaps';
  ASSERT v_heatmaps IS NOT NULL, '3.14: heatmaps must be present';
  ASSERT jsonb_typeof(v_heatmaps) = 'object', '3.14: heatmaps must be a JSON object';

  -- Check machine_1 heatmap shape
  v_dow_arr  := v_heatmaps->v_machine_1::text->'dow';
  v_hour_arr := v_heatmaps->v_machine_1::text->'hour';

  ASSERT v_dow_arr IS NOT NULL,
    format('3.14: heatmaps[%s].dow must be present', v_machine_1);
  ASSERT jsonb_array_length(v_dow_arr) = 7,
    format('3.14: dow must have 7 elements, got %s', jsonb_array_length(v_dow_arr));
  ASSERT v_hour_arr IS NOT NULL,
    format('3.14: heatmaps[%s].hour must be present', v_machine_1);
  ASSERT jsonb_array_length(v_hour_arr) = 24,
    format('3.14: hour must have 24 elements, got %s', jsonb_array_length(v_hour_arr));

  -- All dow cells must be non-negative integers
  ASSERT NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_dow_arr) elem
    WHERE elem::int < 0
  ), '3.14: all dow heatmap cells must be >= 0';

  -- All hour cells must be non-negative integers
  ASSERT NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_hour_arr) elem
    WHERE elem::int < 0
  ), '3.14: all hour heatmap cells must be >= 0';

  RAISE NOTICE 'Test 3.14 (heatmaps object with 7-dow + 24-hour arrays) PASSED';

  -- ─── Test 3.15: cross-company isolation ───────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text,
    true);

  BEGIN
    SELECT public.analytics_machines(
      v_company_a,   -- asking for A while authenticated as B
      now() - interval '30 days', now(),
      NULL, NULL,
      NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
    ) INTO v_result;
    ASSERT FALSE, '3.15: expected cross-company access to raise';
  EXCEPTION
    WHEN OTHERS THEN
      ASSERT SQLERRM ILIKE '%company%' OR SQLERRM ILIKE '%permission%' OR SQLERRM ILIKE '%not allowed%',
        format('3.15: expected company-mismatch error, got: %s', SQLERRM);
  END;

  RAISE NOTICE 'Test 3.15 (cross-company access denied) PASSED';
END;
$$;

ROLLBACK;
