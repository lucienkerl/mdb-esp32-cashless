-- Docker/supabase/tests/analytics_sales_breakdown.test.sql
-- Failing tests for analytics_sales_breakdown RPC (TDD: RPC does not exist yet).
-- Expected failure: ERROR: function analytics_sales_breakdown(...) does not exist
-- After Task 2.3 migration these must all pass.

BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $$
DECLARE
  v_company_a  uuid := gen_random_uuid();
  v_company_b  uuid := gen_random_uuid();
  v_user_a     uuid := gen_random_uuid();
  v_user_b     uuid := gen_random_uuid();
  v_machine_1  uuid := gen_random_uuid();
  v_machine_2  uuid := gen_random_uuid();
  v_product_1  uuid := gen_random_uuid();
  v_product_2  uuid := gen_random_uuid();
  v_result     jsonb;
  v_rows       jsonb;
  v_row_count  int;
  v_sum_pct    numeric;
BEGIN
  -- Two companies
  INSERT INTO public.companies (id, name) VALUES (v_company_a, 'BreakdownA');
  INSERT INTO public.companies (id, name) VALUES (v_company_b, 'BreakdownB');

  -- Auth users
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_a, '00000000-0000-0000-0000-000000000000', 'bda@t.local', now());
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_b, '00000000-0000-0000-0000-000000000000', 'bdb@t.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_a, v_company_a, 'bda@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_b, v_company_b, 'bdb@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_a, v_user_a, 'admin'),
           (v_company_b, v_user_b, 'admin');

  -- Products and machines for company_a
  INSERT INTO public.products (id, name, sellprice, company)
    VALUES (v_product_1, 'CokeBreak', 2.50, v_company_a),
           (v_product_2, 'PepsiBreak', 2.00, v_company_a);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine_1, 'MachBreak1', v_company_a),
           (v_machine_2, 'MachBreak2', v_company_a);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine_1, 1, v_product_1, 10, 8),
           (v_machine_1, 2, v_product_2, 10, 8),
           (v_machine_2, 1, v_product_1, 10, 8);

  -- 5 sales: 3 on machine_1 (2 cashless, 1 cash), 2 on machine_2 (both cashless)
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine_1, 1, 2.50, 'cashless', now() - interval '1 day'),
           (v_machine_1, 2, 2.00, 'cash',     now() - interval '2 days'),
           (v_machine_1, 1, 2.50, 'cashless', now() - interval '3 days'),
           (v_machine_2, 1, 2.50, 'cashless', now() - interval '1 day'),
           (v_machine_2, 1, 2.50, 'cashless', now() - interval '2 days');

  -- Company_b machine + sale (must not appear in A's results)
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (gen_random_uuid(), 'MachBreakB', v_company_b);

  -- ─── Authenticate as company_a ───────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text,
    true);

  -- ─── Test 3.1: dimension='machine' → 2 rows, share_revenue_pct sums to ≈100 ─
  SELECT public.analytics_sales_breakdown(
    v_company_a,
    now() - interval '7 days', now(),
    NULL, NULL,
    NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[],
    'machine'
  ) INTO v_result;

  ASSERT (v_result->>'version')::int = 1,
    format('3.1: version must be 1, got %s', v_result->>'version');
  ASSERT v_result->>'dimension' = 'machine',
    format('3.1: dimension must be ''machine'', got %s', v_result->>'dimension');

  v_rows := v_result->'rows';
  v_row_count := jsonb_array_length(v_rows);
  ASSERT v_row_count = 2,
    format('3.1: expected 2 machine rows, got %s', v_row_count);

  -- share_revenue_pct must sum to ≈100 (±0.1 for rounding)
  SELECT SUM((elem->>'share_revenue_pct')::numeric)
    INTO v_sum_pct
  FROM jsonb_array_elements(v_rows) elem;

  ASSERT ABS(v_sum_pct - 100) <= 0.1,
    format('3.1: share_revenue_pct sum should be ≈100, got %s', v_sum_pct);

  RAISE NOTICE 'Test 3.1 (breakdown dimension=machine, 2 rows, pct sum ≈100) PASSED';

  -- ─── Test 3.2: dimension='channel' → 2 rows (cashless + cash) ───────────────
  SELECT public.analytics_sales_breakdown(
    v_company_a,
    now() - interval '7 days', now(),
    NULL, NULL,
    NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[],
    'channel'
  ) INTO v_result;

  ASSERT (v_result->>'version')::int = 1, '3.2: version must be 1';
  v_rows := v_result->'rows';
  v_row_count := jsonb_array_length(v_rows);
  ASSERT v_row_count = 2,
    format('3.2: expected 2 channel rows (cashless + cash), got %s', v_row_count);

  RAISE NOTICE 'Test 3.2 (breakdown dimension=channel, 2 rows) PASSED';

  -- ─── Test 3.3: dimension='hour' → non-empty, keys in [0,23] ─────────────────
  SELECT public.analytics_sales_breakdown(
    v_company_a,
    now() - interval '7 days', now(),
    NULL, NULL,
    NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[],
    'hour'
  ) INTO v_result;

  ASSERT (v_result->>'version')::int = 1, '3.3: version must be 1';
  v_rows := v_result->'rows';
  ASSERT jsonb_array_length(v_rows) > 0, '3.3: rows must be non-empty for hour dimension';

  -- All key values must be integers in [0, 23]
  ASSERT NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_rows) elem
    WHERE (elem->>'key')::int < 0 OR (elem->>'key')::int > 23
  ), '3.3: all hour keys must be in [0, 23]';

  RAISE NOTICE 'Test 3.3 (breakdown dimension=hour, non-empty, keys in [0,23]) PASSED';

  -- ─── Test 3.4: invalid dimension raises an error containing 'dimension' ──────
  BEGIN
    SELECT public.analytics_sales_breakdown(
      v_company_a,
      now() - interval '7 days', now(),
      NULL, NULL,
      NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[],
      'foo'
    ) INTO v_result;
    ASSERT FALSE, '3.4: expected invalid dimension to raise an error';
  EXCEPTION
    WHEN OTHERS THEN
      ASSERT SQLERRM ILIKE '%dimension%',
        format('3.4: expected dimension error, got: %s', SQLERRM);
  END;

  RAISE NOTICE 'Test 3.4 (invalid dimension raises with ''dimension'' in message) PASSED';

  -- ─── Test 3.5: cross-company isolation ───────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text,
    true);

  BEGIN
    SELECT public.analytics_sales_breakdown(
      v_company_a,   -- asking for A while authenticated as B
      now() - interval '7 days', now(),
      NULL, NULL,
      NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[],
      'machine'
    ) INTO v_result;
    ASSERT FALSE, '3.5: expected cross-company access to raise';
  EXCEPTION
    WHEN OTHERS THEN
      ASSERT SQLERRM ILIKE '%company%' OR SQLERRM ILIKE '%permission%' OR SQLERRM ILIKE '%not allowed%',
        format('3.5: expected company-mismatch error, got: %s', SQLERRM);
  END;

  RAISE NOTICE 'Test 3.5 (cross-company access denied) PASSED';
END;
$$;

ROLLBACK;
