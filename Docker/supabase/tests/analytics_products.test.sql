-- Docker/supabase/tests/analytics_products.test.sql
-- Failing tests for analytics_products RPC (TDD: RPC does not exist yet).
-- Expected failure: ERROR: function analytics_products(...) does not exist
-- After Task 2.3 migration these must all pass.

BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $$
DECLARE
  v_company_a     uuid := gen_random_uuid();
  v_company_b     uuid := gen_random_uuid();
  v_user_a        uuid := gen_random_uuid();
  v_user_b        uuid := gen_random_uuid();
  v_machine_a     uuid := gen_random_uuid();
  v_product_sell  uuid := gen_random_uuid();  -- has sales → active
  v_product_dead  uuid := gen_random_uuid();  -- no sales → dead
  v_product_disc  uuid := gen_random_uuid();  -- discontinued flag
  v_category      uuid := gen_random_uuid();
  v_result        jsonb;
  v_kpis          jsonb;
  v_products      jsonb;
  v_prod_count    int;
  v_active_count  int;
  v_slow_count    int;
  v_disc_count    int;
  v_disc_status   text;
  v_dead_status   text;
BEGIN
  -- Two companies
  INSERT INTO public.companies (id, name) VALUES (v_company_a, 'ProductsA');
  INSERT INTO public.companies (id, name) VALUES (v_company_b, 'ProductsB');

  -- Auth users
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_a, '00000000-0000-0000-0000-000000000000', 'pda@t.local', now());
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_b, '00000000-0000-0000-0000-000000000000', 'pdb@t.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_a, v_company_a, 'pda@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_b, v_company_b, 'pdb@t.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_a, v_user_a, 'admin'),
           (v_company_b, v_user_b, 'admin');

  -- Category for company_a
  INSERT INTO public.product_category (id, name, company)
    VALUES (v_category, 'Beverages', v_company_a);

  -- Products: one with sales, one dead, one discontinued
  INSERT INTO public.products (id, name, sellprice, company, category, discontinued)
    VALUES (v_product_sell, 'ActiveDrink',   2.50, v_company_a, v_category, false),
           (v_product_dead, 'DeadSnack',     1.50, v_company_a, v_category, false),
           (v_product_disc, 'OldProduct',    1.00, v_company_a, v_category, true);

  -- Machine + tray for company_a
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine_a, 'ProdMachA', v_company_a);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine_a, 1, v_product_sell, 10, 8),
           (v_machine_a, 2, v_product_dead, 10, 8),
           (v_machine_a, 3, v_product_disc, 10, 5);

  -- Sales only for v_product_sell (3 sales within last 7 days)
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine_a, 1, 2.50, 'cashless', now() - interval '1 day'),
           (v_machine_a, 1, 2.50, 'cashless', now() - interval '2 days'),
           (v_machine_a, 1, 2.50, 'cashless', now() - interval '3 days');

  -- Authenticate as company_a
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text,
    true);

  SELECT public.analytics_products(
    v_company_a,
    now() - interval '30 days', now(),
    NULL, NULL,
    NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
  ) INTO v_result;

  -- ─── Test 3.6: version=1, kpis present ───────────────────────────────────────
  ASSERT (v_result->>'version')::int = 1,
    format('3.6: version must be 1, got %s', v_result->>'version');

  v_kpis := v_result->'kpis';
  ASSERT v_kpis IS NOT NULL, '3.6: kpis must be present';

  v_active_count := (v_kpis->>'active_count')::int;
  v_slow_count   := (v_kpis->>'slow_mover_count')::int;
  v_disc_count   := (v_kpis->>'discontinued_count')::int;

  ASSERT v_active_count IS NOT NULL AND v_active_count >= 0,
    format('3.6: active_count must be int >= 0, got %s', v_active_count);
  ASSERT v_slow_count IS NOT NULL AND v_slow_count >= 0,
    format('3.6: slow_mover_count must be int >= 0, got %s', v_slow_count);
  ASSERT v_disc_count IS NOT NULL AND v_disc_count >= 0,
    format('3.6: discontinued_count must be int >= 0, got %s', v_disc_count);
  ASSERT (v_kpis->>'categories_with_sales')::int >= 0,
    '3.6: categories_with_sales must be int >= 0';

  RAISE NOTICE 'Test 3.6 (analytics_products: version=1, kpis present) PASSED';

  -- ─── Test 3.7: products array includes all company_a products ────────────────
  v_products  := v_result->'products';
  v_prod_count := jsonb_array_length(v_products);
  ASSERT v_prod_count >= 3,
    format('3.7: expected at least 3 products, got %s', v_prod_count);

  RAISE NOTICE 'Test 3.7 (analytics_products: products[] has all seeded products) PASSED';

  -- ─── Test 3.8: discontinued product has status='discontinued' ────────────────
  SELECT elem->>'status' INTO v_disc_status
  FROM jsonb_array_elements(v_products) elem
  WHERE (elem->>'id')::uuid = v_product_disc;

  ASSERT v_disc_status = 'discontinued',
    format('3.8: discontinued product must have status=''discontinued'', got %s', v_disc_status);

  RAISE NOTICE 'Test 3.8 (discontinued product status=''discontinued'') PASSED';

  -- ─── Test 3.9: product with zero sales has status='dead' ─────────────────────
  SELECT elem->>'status' INTO v_dead_status
  FROM jsonb_array_elements(v_products) elem
  WHERE (elem->>'id')::uuid = v_product_dead;

  ASSERT v_dead_status = 'dead',
    format('3.9: product with no sales must have status=''dead'', got %s', v_dead_status);

  RAISE NOTICE 'Test 3.9 (zero-sales product status=''dead'') PASSED';

  -- ─── Test 3.10: cross-company isolation ──────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text,
    true);

  BEGIN
    SELECT public.analytics_products(
      v_company_a,   -- asking for A while authenticated as B
      now() - interval '30 days', now(),
      NULL, NULL,
      NULL::uuid[], NULL::text[], NULL::uuid[], NULL::numeric[]
    ) INTO v_result;
    ASSERT FALSE, '3.10: expected cross-company access to raise';
  EXCEPTION
    WHEN OTHERS THEN
      ASSERT SQLERRM ILIKE '%company%' OR SQLERRM ILIKE '%permission%' OR SQLERRM ILIKE '%not allowed%',
        format('3.10: expected company-mismatch error, got: %s', SQLERRM);
  END;

  RAISE NOTICE 'Test 3.10 (cross-company access denied) PASSED';
END;
$$;

ROLLBACK;
