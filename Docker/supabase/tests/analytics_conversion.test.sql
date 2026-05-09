-- Docker/supabase/tests/analytics_conversion.test.sql
-- Failing tests for analytics_conversion RPC (TDD: RPC does not exist yet).
-- Expected failure: ERROR: function analytics_conversion(...) does not exist
-- After Task 2.3 migration these must all pass.

BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $$
DECLARE
  v_company_a  uuid := gen_random_uuid();
  v_company_b  uuid := gen_random_uuid();
  v_user_a     uuid := gen_random_uuid();
  v_user_b     uuid := gen_random_uuid();
  v_machine_a  uuid := gen_random_uuid();
  v_embedded_a uuid := gen_random_uuid();
  v_product_1  uuid := gen_random_uuid();
  v_result     jsonb;
  v_kpis       jsonb;
  v_machines   jsonb;
  v_footfall   int;
  v_conv_pct   numeric;
  v_empty_pass int;
  v_mach_entry jsonb;
  v_pax_val    int;
  v_sales_val  int;
BEGIN
  -- Two companies
  INSERT INTO public.companies (id, name) VALUES (v_company_a, 'ConversionA');
  INSERT INTO public.companies (id, name) VALUES (v_company_b, 'ConversionB');

  -- Auth users
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_a, '00000000-0000-0000-0000-000000000000', 'cva@t.local', now());
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_b, '00000000-0000-0000-0000-000000000000', 'cvb@t.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_a, v_company_a, 'cva@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_b, v_company_b, 'cvb@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_a, v_user_a, 'admin'),
           (v_company_b, v_user_b, 'admin');

  -- Product for company_a
  INSERT INTO public.products (id, name, sellprice, company)
    VALUES (v_product_1, 'ConvDrink', 2.00, v_company_a);

  -- Embedded device for company_a (needed for paxcounter FK)
  INSERT INTO public.embeddeds (id, company)
    VALUES (v_embedded_a, v_company_a);

  -- Machine linked to embedded device
  INSERT INTO public."vendingMachine" (id, name, company, embedded)
    VALUES (v_machine_a, 'ConvMachA', v_company_a, v_embedded_a);

  -- Tray for machine_a
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine_a, 1, v_product_1, 10, 8);

  -- Paxcounter: 100 visitors for this machine within the last 7 days
  INSERT INTO public.paxcounter (id, embedded_id, machine_id, count, created_at)
    VALUES (gen_random_uuid(), v_embedded_a, v_machine_a, 100, now() - interval '1 day');

  -- 5 sales within the same window
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine_a, 1, 2.00, 'cashless', now() - interval '1 day'),
           (v_machine_a, 1, 2.00, 'cashless', now() - interval '2 days'),
           (v_machine_a, 1, 2.00, 'cashless', now() - interval '3 days'),
           (v_machine_a, 1, 2.00, 'cashless', now() - interval '4 days'),
           (v_machine_a, 1, 2.00, 'cashless', now() - interval '5 days');

  -- Authenticate as company_a
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text,
    true);

  SELECT public.analytics_conversion(
    v_company_a,
    now() - interval '7 days', now(),
    NULL, NULL,
    NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
  ) INTO v_result;

  -- ─── Test 3.16: version=1 ────────────────────────────────────────────────────
  ASSERT (v_result->>'version')::int = 1,
    format('3.16: version must be 1, got %s', v_result->>'version');

  v_kpis := v_result->'kpis';
  ASSERT v_kpis IS NOT NULL, '3.16: kpis must be present';

  RAISE NOTICE 'Test 3.16 (analytics_conversion: version=1, kpis present) PASSED';

  -- ─── Test 3.17: kpis.footfall >= 100 ─────────────────────────────────────────
  v_footfall := (v_kpis->>'footfall')::int;
  ASSERT v_footfall >= 100,
    format('3.17: footfall must be >= 100 (seeded 100 visitors), got %s', v_footfall);

  RAISE NOTICE 'Test 3.17 (kpis.footfall >= 100) PASSED';

  -- ─── Test 3.18: kpis.conversion_pct ≈ 5.0 (±0.5) ────────────────────────────
  v_conv_pct := (v_kpis->>'conversion_pct')::numeric;
  ASSERT ABS(v_conv_pct - 5.0) <= 0.5,
    format('3.18: conversion_pct should be ≈5.0 (5 sales / 100 pax × 100), got %s', v_conv_pct);

  RAISE NOTICE 'Test 3.18 (kpis.conversion_pct ≈ 5.0) PASSED';

  -- ─── Test 3.19: kpis.empty_passes ≈ 95 (100 - 5) ────────────────────────────
  v_empty_pass := (v_kpis->>'empty_passes')::int;
  ASSERT v_empty_pass >= 90 AND v_empty_pass <= 100,
    format('3.19: empty_passes should be ≈95 (100 pax - 5 sales), got %s', v_empty_pass);

  RAISE NOTICE 'Test 3.19 (kpis.empty_passes ≈ 95) PASSED';

  -- ─── Test 3.20: machines[] has at least 1 entry with pax > 0 and sales = 5 ───
  v_machines := v_result->'machines';
  ASSERT jsonb_array_length(v_machines) >= 1, '3.20: machines[] must have at least 1 entry';

  -- Find the machine entry for our seeded machine
  SELECT elem INTO v_mach_entry
  FROM jsonb_array_elements(v_machines) elem
  WHERE (elem->>'id')::uuid = v_machine_a;

  ASSERT v_mach_entry IS NOT NULL,
    format('3.20: machine_a (%s) must appear in machines[]', v_machine_a);

  v_pax_val  := (v_mach_entry->>'pax')::int;
  v_sales_val := (v_mach_entry->>'sales')::int;

  ASSERT v_pax_val > 0,
    format('3.20: machine pax must be > 0, got %s', v_pax_val);
  ASSERT v_sales_val = 5,
    format('3.20: machine sales must be 5, got %s', v_sales_val);

  RAISE NOTICE 'Test 3.20 (machines[] entry with pax > 0 and sales = 5) PASSED';

  -- ─── Test 3.21: cross-company isolation ───────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text,
    true);

  BEGIN
    SELECT public.analytics_conversion(
      v_company_a,   -- asking for A while authenticated as B
      now() - interval '7 days', now(),
      NULL, NULL,
      NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
    ) INTO v_result;
    ASSERT FALSE, '3.21: expected cross-company access to raise';
  EXCEPTION
    WHEN OTHERS THEN
      ASSERT SQLERRM ILIKE '%company%' OR SQLERRM ILIKE '%permission%' OR SQLERRM ILIKE '%not allowed%',
        format('3.21: expected company-mismatch error, got: %s', SQLERRM);
  END;

  RAISE NOTICE 'Test 3.21 (cross-company access denied) PASSED';
END;
$$;

ROLLBACK;
