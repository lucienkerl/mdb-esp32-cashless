-- Schema-, Trigger-, Storno- und Regressionstests für die Buchungsart
-- change_float (Migration 20260807000000_cash_book_change_float.sql).
--
-- Läuft in einer Transaktion, die am Ende zurückgerollt wird → keine Dev-Daten
-- werden angefasst. Plain ASSERT in einem DO-Block, kein pgTAP.
-- Fake-JWT via set_config('request.jwt.claims', ..., true), damit die
-- SECURITY-DEFINER-Prüfung von get_theoretical_cash greift.
--
-- Voraussetzung: `supabase start` + `supabase migration up`.
-- Ausführung über Docker/supabase/tests/run-sql-tests.sh.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_book      uuid := gen_random_uuid();
  v_machine   uuid := gen_random_uuid();
  v_product   uuid := gen_random_uuid();
  v_float_id  uuid;
  v_raised    boolean;
  v_balance   float8;
  v_before    jsonb;
  v_after     jsonb;
  v_machine_id_after uuid;
  v_rows      int;
BEGIN
  -- ─── Firma, Auth-User, Mitgliedschaft ────────────────────────────────────
  INSERT INTO public.companies (id, name) VALUES (v_company, 'FloatTestCo');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'float@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'float@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  -- ─── Barkasse (Anfangsbestand 500) + ein Automat ─────────────────────────
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book, v_company, 'FloatKasse', 500, v_user, true);

  UPDATE public.cash_book_entries
     SET created_at = '2026-08-01 08:00+00'
   WHERE cash_book_id = v_book AND type = 'initial';

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine, 'Automat 1', v_company, v_book);

  INSERT INTO public.products (id, name, company) VALUES (v_product, 'TestBar', v_company);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine, 1, v_product, 100, 100);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 1: change_float ohne machine_id wird abgewiesen ════════════════
  v_raised := false;
  BEGIN
    INSERT INTO public.cash_book_entries
      (cash_book_id, company_id, type, amount, created_by)
      VALUES (v_book, v_company, 'change_float', -50, v_user);
  EXCEPTION WHEN others THEN
    v_raised := true;
  END;
  ASSERT v_raised, 'change_float ohne machine_id muss abgewiesen werden';
  RAISE NOTICE 'Test 1 bestanden: machine_id ist Pflicht';

  -- ═══ Test 2: change_float mit amount = 0 wird abgewiesen ═════════════════
  v_raised := false;
  BEGIN
    INSERT INTO public.cash_book_entries
      (cash_book_id, company_id, type, amount, machine_id, created_by)
      VALUES (v_book, v_company, 'change_float', 0, v_machine, v_user);
  EXCEPTION WHEN others THEN
    v_raised := true;
  END;
  ASSERT v_raised, 'change_float mit amount = 0 muss abgewiesen werden';
  RAISE NOTICE 'Test 2 bestanden: Nullbuchung gesperrt';

  -- ═══ Test 3: gültige Einlage senkt den Kassenstand ═══════════════════════
  INSERT INTO public.cash_book_entries
    (created_at, cash_book_id, company_id, type, amount, machine_id, created_by)
    VALUES ('2026-08-02 08:00+00', v_book, v_company, 'change_float', -50, v_machine, v_user)
    RETURNING id, balance_after INTO v_float_id, v_balance;

  ASSERT v_balance = 450, format('Kassenstand nach Einlage erwartet 450, war %s', v_balance);
  RAISE NOTICE 'Test 3 bestanden: Einlage senkt den Kassenstand';

  -- ═══ Test 4: Float-Bestand = −SUM(amount) ════════════════════════════════
  SELECT -SUM(amount) INTO v_balance
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float' AND is_reversed = false;
  ASSERT v_balance = 50, format('Float erwartet 50, war %s', v_balance);
  RAISE NOTICE 'Test 4 bestanden: Float-Bestand korrekt';

  -- ═══ Test 5: Storno einer change_float-Buchung ist möglich ═══════════════
  -- Die Gegenbuchung trägt type = 'reversal' und KEINE machine_id — der
  -- Trigger-Guard darf hier nicht greifen.
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, corrects_entry_id, created_by)
    VALUES (v_book, v_company, 'reversal', 0, v_float_id, v_user);

  SELECT is_reversed INTO v_raised
    FROM public.cash_book_entries WHERE id = v_float_id;
  ASSERT v_raised, 'Originalbuchung muss nach dem Storno als reversed markiert sein';

  SELECT COALESCE(-SUM(amount), 0) INTO v_balance
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float' AND is_reversed = false;
  ASSERT v_balance = 0, format('Float nach Storno erwartet 0, war %s', v_balance);
  RAISE NOTICE 'Test 5 bestanden: Storno nimmt den Float zurück';

  -- ═══ Test 6: get_theoretical_cash ist von change_float unberührt ═════════
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine, 1, 3.00, 'cash', '2026-08-03 09:00+00');

  v_before := public.get_theoretical_cash(v_book, v_company);

  INSERT INTO public.cash_book_entries
    (created_at, cash_book_id, company_id, type, amount, machine_id, created_by)
    VALUES ('2026-08-03 10:00+00', v_book, v_company, 'change_float', -20, v_machine, v_user);

  v_after := public.get_theoretical_cash(v_book, v_company);

  ASSERT (v_before->>'cash_sales_since')::float8 = (v_after->>'cash_sales_since')::float8,
    format('change_float darf cash_sales_since nicht verschieben: vorher %s, nachher %s',
           v_before->>'cash_sales_since', v_after->>'cash_sales_since');
  RAISE NOTICE 'Test 6 bestanden: Anker und Erwartungswert unverändert';

  -- ═══ Test 7: Automat löschen trotz offener Float-Buchung ═════════════════
  -- ON DELETE SET NULL darf nicht an einem CHECK scheitern.
  DELETE FROM public.machine_trays WHERE machine_id = v_machine;
  DELETE FROM public.sales WHERE machine_id = v_machine;
  DELETE FROM public."vendingMachine" WHERE id = v_machine;

  SELECT count(*) INTO v_rows
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float';
  ASSERT v_rows = 2, format('Float-Buchungen müssen das Löschen überleben, gefunden %s', v_rows);

  SELECT machine_id INTO v_machine_id_after
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float'
   ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_machine_id_after IS NULL, 'machine_id muss nach dem Löschen NULL sein';
  RAISE NOTICE 'Test 7 bestanden: Automat bleibt löschbar';

END $$;

ROLLBACK;
