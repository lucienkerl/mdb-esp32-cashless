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

-- ═════════════════════════════════════════════════════════════════════════
-- record_cash_book_withdrawal
-- ═════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_company uuid := gen_random_uuid();
  v_user    uuid := gen_random_uuid();
  v_book    uuid := gen_random_uuid();
  v_machine uuid := gen_random_uuid();
  v_other_company uuid := gen_random_uuid();
  v_other_machine uuid := gen_random_uuid();
  r jsonb; v_raised boolean; v_err text; v_balance float8; n int; n_after int;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'WithdrawRpcCo');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'wdrpc@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'wdrpc@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book, v_company, 'WdKasse', 0, v_user);

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine, 'A', v_company, v_book);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 6: ohne Rücklage entsteht genau eine Zeile ═════════════════════
  r := public.record_cash_book_withdrawal(v_book, v_machine, 100.00, 95.00, 0,
                                          'Geldentnahme', NULL);
  ASSERT r->>'withdrawal_entry_id' IS NOT NULL, 'withdrawal_entry_id fehlt';
  ASSERT r->>'change_float_entry_id' IS NULL,
    format('ohne Rücklage darf keine Float-Zeile entstehen, war %s', r->>'change_float_entry_id');

  SELECT balance_after INTO v_balance
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 100.00, format('Kassenstand erwartet 100.00, war %s', v_balance);
  RAISE NOTICE 'Test 6 bestanden: Entnahme ohne Rücklage';

  -- ═══ Test 7: mit Rücklage entstehen zwei Zeilen in richtiger Reihenfolge ═
  r := public.record_cash_book_withdrawal(v_book, v_machine, 200.00, 180.00, 50.00,
                                          'Geldentnahme', 'Wechselgeld Tuben');
  ASSERT r->>'change_float_entry_id' IS NOT NULL, 'change_float_entry_id fehlt';

  -- Netto: 100 + 200 − 50 = 250
  SELECT balance_after INTO v_balance
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 250.00, format('Kassenstand erwartet 250.00, war %s', v_balance);

  -- Die Float-Zeile muss die höhere entry_number tragen (Entnahme zuerst).
  SELECT type = 'change_float' INTO v_raised
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_raised, 'die Wechselgeldbuchung muss nach der Entnahme stehen';
  RAISE NOTICE 'Test 7 bestanden: verkettete Doppelbuchung';

  -- ═══ Test 8: Float-Bestand nach der Doppelbuchung ════════════════════════
  r := public.get_machine_change_float(v_company);
  SELECT (e->>'float_balance')::float8 INTO v_balance
    FROM jsonb_array_elements(r) e WHERE (e->>'machine_id')::uuid = v_machine;
  ASSERT v_balance = 50.00, format('Float erwartet 50.00, war %s', v_balance);
  RAISE NOTICE 'Test 8 bestanden: Bestand nach Doppelbuchung';

  -- ═══ Test 9: Rücklage ohne Automat wird abgewiesen, ohne Teilbuchung ═════
  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(v_book, NULL, 10.00, 10.00, 5.00,
                                               'Geldentnahme', NULL);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  -- Auf die konkrete Meldung prüfen, nicht nur "irgendwas schlug fehl" — sonst
  -- bliebe der Test grün, wenn ein anderer Fehler zuerst greift. Gleiches
  -- Muster wie in den übrigen Testdateien dieses Verzeichnisses.
  ASSERT v_err LIKE '%change float requires a machine%',
    format('erwartet wurde die Automaten-Vorabprüfung, kam aber: %s', v_err);

  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book;
  ASSERT n_after = n,
    format('abgewiesener Aufruf darf keine Zeile hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 9 bestanden: keine halbe Buchung';

  -- ═══ Test 10: fremder Automat wird abgewiesen ════════════════════════════
  -- cash_book_entries bindet machine_id nicht an company_id. Ohne die
  -- Prüfung in der RPC ließe sich auf einen fremden Automaten buchen.
  INSERT INTO public.companies (id, name) VALUES (v_other_company, 'FremdeFirma');
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_other_machine, 'Fremd', v_other_company);

  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(v_book, v_other_machine, 10.00, 10.00, 0,
                                               'Geldentnahme', NULL);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%machine does not belong to this company%',
    format('erwartet wurde die Firmenprüfung, kam aber: %s', v_err);

  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book;
  ASSERT n_after = n,
    format('abgewiesener Aufruf darf keine Zeile hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 10 bestanden: fremder Automat abgewiesen';

END $$;

ROLLBACK;
