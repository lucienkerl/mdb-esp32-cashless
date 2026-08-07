-- Tests für get_machine_change_float (20260807000100) und
-- record_cash_book_withdrawal (20260807000200).
--
-- Der zweite Block wird in Task 3 ergänzt; bis dahin deckt die Datei nur
-- die Bestandsabfrage ab.
--
-- Läuft in einer zurückgerollten Transaktion. Voraussetzung:
-- `supabase start` + `supabase migration up`.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_stranger  uuid := gen_random_uuid();
  v_book      uuid := gen_random_uuid();
  v_book2     uuid := gen_random_uuid();
  v_machine_a uuid := gen_random_uuid();
  v_machine_b uuid := gen_random_uuid();
  v_entry_b   uuid;
  r jsonb; a float8; n int;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'FloatRpcCo');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'floatrpc@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'floatrpc@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book, v_company, 'RpcKasse', 1000, v_user);

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id) VALUES
    (v_machine_a, 'A', v_company, v_book),
    (v_machine_b, 'B', v_company, v_book);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 1: leerer Bestand liefert [] ═══════════════════════════════════
  r := public.get_machine_change_float(v_company);
  ASSERT r = '[]'::jsonb, format('ohne Buchungen erwartet [], war %s', r);
  RAISE NOTICE 'Test 1 bestanden: leerer Bestand';

  -- ═══ Test 2: Einlagen und Rücknahmen saldieren je Automat ════════════════
  -- A: −50 −25 zurück +30  →  Float 45
  -- B: −80                 →  Float 80, danach storniert → fällt raus
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, machine_id, created_by) VALUES
    (v_book, v_company, 'change_float', -50, v_machine_a, v_user),
    (v_book, v_company, 'change_float', -25, v_machine_a, v_user),
    (v_book, v_company, 'change_float',  30, v_machine_a, v_user);

  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, machine_id, created_by)
    VALUES (v_book, v_company, 'change_float', -80, v_machine_b, v_user)
    RETURNING id INTO v_entry_b;

  r := public.get_machine_change_float(v_company);
  RAISE NOTICE 'Bestand: %', r;

  SELECT (e->>'float_balance')::float8 INTO a
    FROM jsonb_array_elements(r) e WHERE (e->>'machine_id')::uuid = v_machine_a;
  ASSERT a = 45, format('A erwartet 45, war %s', a);

  SELECT (e->>'float_balance')::float8 INTO a
    FROM jsonb_array_elements(r) e WHERE (e->>'machine_id')::uuid = v_machine_b;
  ASSERT a = 80, format('B erwartet 80 vor dem Storno, war %s', a);
  RAISE NOTICE 'Test 2 bestanden: Saldierung je Automat';

  -- ═══ Test 3: Storno entfernt den Automaten aus dem Bestand ═══════════════
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, corrects_entry_id, created_by)
    VALUES (v_book, v_company, 'reversal', 0, v_entry_b, v_user);

  r := public.get_machine_change_float(v_company);
  SELECT count(*) INTO n
    FROM jsonb_array_elements(r) e WHERE (e->>'machine_id')::uuid = v_machine_b;
  ASSERT n = 0, format('B darf nach Storno nicht mehr auftauchen, gefunden %s', n);
  RAISE NOTICE 'Test 3 bestanden: Storno nimmt den Bestand zurück';

  -- ═══ Test 4: Saldo exakt null wird ausgeblendet ══════════════════════════
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, machine_id, created_by)
    VALUES (v_book, v_company, 'change_float', 45, v_machine_a, v_user);

  r := public.get_machine_change_float(v_company);
  ASSERT r = '[]'::jsonb, format('bei Saldo 0 erwartet [], war %s', r);
  RAISE NOTICE 'Test 4 bestanden: Nullsaldo ausgeblendet';

  -- ═══ Test 4b: ein Automat in zwei Barkassen ergibt zwei Zeilen ═══════════
  -- Dokumentiertes Verhalten: der Float gehört buchhalterisch zu einer
  -- bestimmten Barkasse, ein Barkassenwechsel erzeugt daher zwei Zeilen.
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book2, v_company, 'RpcKasse2', 0, v_user);

  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, machine_id, created_by) VALUES
    (v_book,  v_company, 'change_float', -10, v_machine_a, v_user),
    (v_book2, v_company, 'change_float', -15, v_machine_a, v_user);

  r := public.get_machine_change_float(v_company);

  SELECT count(*) INTO n
    FROM jsonb_array_elements(r) e WHERE (e->>'machine_id')::uuid = v_machine_a;
  ASSERT n = 2, format('Automat in zwei Barkassen erwartet 2 Zeilen, waren %s', n);

  SELECT (e->>'float_balance')::float8 INTO a
    FROM jsonb_array_elements(r) e
   WHERE (e->>'machine_id')::uuid = v_machine_a AND (e->>'cash_book_id')::uuid = v_book;
  ASSERT a = 10, format('Zeile für Barkasse 1 erwartet 10, war %s', a);

  SELECT (e->>'float_balance')::float8 INTO a
    FROM jsonb_array_elements(r) e
   WHERE (e->>'machine_id')::uuid = v_machine_a AND (e->>'cash_book_id')::uuid = v_book2;
  ASSERT a = 15, format('Zeile für Barkasse 2 erwartet 15, war %s', a);
  RAISE NOTICE 'Test 4b bestanden: Zeile je (Automat, Barkasse)';

  -- ═══ Test 5: Fremder Nutzer bekommt NULL ═════════════════════════════════
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_stranger::text, 'role', 'authenticated')::text, true);
  r := public.get_machine_change_float(v_company);
  ASSERT r IS NULL, format('Nicht-Mitglied muss NULL bekommen, war %s', r);
  RAISE NOTICE 'Test 5 bestanden: Firmenfremder abgewiesen';

END $$;

ROLLBACK;
