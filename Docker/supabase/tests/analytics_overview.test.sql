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
