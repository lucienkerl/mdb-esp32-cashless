-- Tests für record_cash_book_withdrawal(..., p_floats) und die dafür
-- erweiterte reverse_cash_book_entry (20260807000500).
--
-- Auf einer Tour werden häufig mehrere Automaten in derselben Entnahme
-- geleert; schiebt der Bediener Wechselgeld in mehr als einen davon
-- zurück, muss jeder Automat seine eigene Rücklagenzeile bekommen statt
-- den gesamten Betrag einem einzigen Automaten zuzuschlagen.
--
-- Jedes Szenario bekommt eine eigene Barkasse, damit balance_after- und
-- Zeilenzahl-Assertions nicht von anderen Szenarien in derselben Kette
-- verfälscht werden.
--
-- Läuft in einer zurückgerollten Transaktion. Voraussetzung:
-- `supabase start` + `supabase migration up`.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company       uuid := gen_random_uuid();
  v_user          uuid := gen_random_uuid();
  v_other_company uuid := gen_random_uuid();
  v_other_machine uuid := gen_random_uuid();

  v_machine_a uuid := gen_random_uuid();
  v_machine_b uuid := gen_random_uuid();
  v_machine_c uuid := gen_random_uuid();

  v_book1 uuid := gen_random_uuid();
  v_book2 uuid := gen_random_uuid();
  v_book3 uuid := gen_random_uuid();
  v_book4 uuid := gen_random_uuid();
  v_book5 uuid := gen_random_uuid();
  v_book6 uuid := gen_random_uuid();
  v_book7 uuid := gen_random_uuid();
  v_book8 uuid := gen_random_uuid();

  r jsonb; res jsonb; v_err text;
  v_withdrawal1 uuid;
  v_float_ids jsonb;
  v_id uuid;
  v_amt float8; v_desc text; v_paired uuid;
  n int; n_after int;
  v_balance float8;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'MultiFloatCo');
  INSERT INTO public.companies (id, name) VALUES (v_other_company, 'FremdeFirmaMF');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'multifloat@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'multifloat@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  INSERT INTO public."vendingMachine" (id, name, company) VALUES
    (v_machine_a, 'A', v_company),
    (v_machine_b, 'B', v_company),
    (v_machine_c, 'C', v_company);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_other_machine, 'Fremd', v_other_company);

  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by) VALUES
    (v_book1, v_company, 'Buch1 mehrere Automaten',   0, v_user),
    (v_book2, v_company, 'Buch2 Nullbetrag',           0, v_user),
    (v_book3, v_company, 'Buch3 beide Parameter',      0, v_user),
    (v_book4, v_company, 'Buch4 fremder Automat',      0, v_user),
    (v_book5, v_company, 'Buch5 unveränderter Einzelfall', 0, v_user),
    (v_book6, v_company, 'Buch6 negativer Betrag',     0, v_user),
    (v_book7, v_company, 'Buch7 fehlender Automat',    0, v_user),
    (v_book8, v_company, 'Buch8 leeres Array',         0, v_user);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 1: mehrere Automaten mit Beträgen ══════════════════════════════
  -- Entnahme 300, Rücklage A=20, B=30 (eigene Beschreibung), C=10.
  -- Netto auf die Barkasse: 300 − 20 − 30 − 10 = 240.
  r := public.record_cash_book_withdrawal(
    v_book1, NULL, 300.00, 280.00, 0, 'Tour-Entnahme', 'Rücklage Standard',
    jsonb_build_array(
      jsonb_build_object('machine_id', v_machine_a, 'amount', 20.00),
      jsonb_build_object('machine_id', v_machine_b, 'amount', 30.00, 'description', 'Rücklage B eigens'),
      jsonb_build_object('machine_id', v_machine_c, 'amount', 10.00)
    )
  );
  v_withdrawal1 := (r->>'withdrawal_entry_id')::uuid;
  ASSERT v_withdrawal1 IS NOT NULL, 'withdrawal_entry_id fehlt';
  ASSERT r->>'change_float_entry_id' IS NULL,
    format('im Mehrfachfall darf change_float_entry_id NULL sein, war %s', r->>'change_float_entry_id');

  v_float_ids := r->'change_float_entry_ids';
  ASSERT jsonb_typeof(v_float_ids) = 'array', 'change_float_entry_ids muss ein Array sein';
  ASSERT jsonb_array_length(v_float_ids) = 3,
    format('erwartet 3 Rücklagenzeilen, waren %s', jsonb_array_length(v_float_ids));

  -- Je eine Zeile pro Automat, korrekt negiert, mit paired_entry_id und
  -- der erwarteten Beschreibung (eigene bzw. Fallback).
  SELECT amount, description, paired_entry_id INTO v_amt, v_desc, v_paired
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book1 AND type = 'change_float' AND machine_id = v_machine_a;
  ASSERT v_amt = -20.00, format('A erwartet -20.00, war %s', v_amt);
  ASSERT v_desc = 'Rücklage Standard', format('A erwartet Fallback-Beschreibung, war %s', v_desc);
  ASSERT v_paired = v_withdrawal1, 'A-Zeile muss auf die Entnahme zeigen';

  SELECT amount, description, paired_entry_id INTO v_amt, v_desc, v_paired
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book1 AND type = 'change_float' AND machine_id = v_machine_b;
  ASSERT v_amt = -30.00, format('B erwartet -30.00, war %s', v_amt);
  ASSERT v_desc = 'Rücklage B eigens', format('B erwartet eigene Beschreibung, war %s', v_desc);
  ASSERT v_paired = v_withdrawal1, 'B-Zeile muss auf die Entnahme zeigen';

  SELECT amount, description, paired_entry_id INTO v_amt, v_desc, v_paired
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book1 AND type = 'change_float' AND machine_id = v_machine_c;
  ASSERT v_amt = -10.00, format('C erwartet -10.00, war %s', v_amt);
  ASSERT v_desc = 'Rücklage Standard', format('C erwartet Fallback-Beschreibung, war %s', v_desc);
  ASSERT v_paired = v_withdrawal1, 'C-Zeile muss auf die Entnahme zeigen';

  -- Bestandsabfrage bestätigt die Salden je Automat in dieser Barkasse.
  r := public.get_machine_change_float(v_company);
  SELECT (e->>'float_balance')::float8 INTO v_amt FROM jsonb_array_elements(r) e
   WHERE (e->>'machine_id')::uuid = v_machine_a AND (e->>'cash_book_id')::uuid = v_book1;
  ASSERT v_amt = 20.00, format('Bestand A erwartet 20.00, war %s', v_amt);
  SELECT (e->>'float_balance')::float8 INTO v_amt FROM jsonb_array_elements(r) e
   WHERE (e->>'machine_id')::uuid = v_machine_b AND (e->>'cash_book_id')::uuid = v_book1;
  ASSERT v_amt = 30.00, format('Bestand B erwartet 30.00, war %s', v_amt);
  SELECT (e->>'float_balance')::float8 INTO v_amt FROM jsonb_array_elements(r) e
   WHERE (e->>'machine_id')::uuid = v_machine_c AND (e->>'cash_book_id')::uuid = v_book1;
  ASSERT v_amt = 10.00, format('Bestand C erwartet 10.00, war %s', v_amt);

  SELECT balance_after INTO v_balance FROM public.cash_book_entries
   WHERE cash_book_id = v_book1 ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 240.00, format('Kassenstand erwartet 240.00, war %s', v_balance);
  RAISE NOTICE 'Test 1 bestanden: mehrere Automaten je eine Rücklagenzeile';

  -- ═══ Test 2: Nullbetrag mittendrin wird übersprungen ═════════════════════
  r := public.record_cash_book_withdrawal(
    v_book2, NULL, 100.00, 90.00, 0, 'Tour-Entnahme', 'Rücklage',
    jsonb_build_array(
      jsonb_build_object('machine_id', v_machine_a, 'amount', 15.00),
      jsonb_build_object('machine_id', v_machine_b, 'amount', 0),
      jsonb_build_object('machine_id', v_machine_c, 'amount', 5.00)
    )
  );
  ASSERT jsonb_array_length(r->'change_float_entry_ids') = 2,
    format('Nullbetrag muss übersprungen werden, erwartet 2 Zeilen, waren %s',
           jsonb_array_length(r->'change_float_entry_ids'));

  SELECT count(*) INTO n FROM public.cash_book_entries
   WHERE cash_book_id = v_book2 AND type = 'change_float' AND machine_id = v_machine_b;
  ASSERT n = 0, format('für Nullbetrag darf keine Zeile entstehen, waren %s', n);

  SELECT count(*) INTO n FROM public.cash_book_entries
   WHERE cash_book_id = v_book2 AND type = 'change_float';
  ASSERT n = 2, format('Buch2 erwartet 2 Rücklagenzeilen insgesamt, waren %s', n);
  RAISE NOTICE 'Test 2 bestanden: Nullbetrag übersprungen';

  -- ═══ Test 3: p_float_back und p_floats gleichzeitig → Ablehnung ═════════
  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book3;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(
      v_book3, v_machine_a, 50.00, 50.00, 10.00, 'Entnahme', 'Rücklage',
      jsonb_build_array(jsonb_build_object('machine_id', v_machine_a, 'amount', 5.00))
    );
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%mutually exclusive%',
    format('erwartet die Ausschluss-Prüfung, kam aber: %s', v_err);

  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book3;
  ASSERT n_after = n,
    format('abgewiesener Aufruf darf keine Zeile hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 3 bestanden: p_float_back und p_floats schließen sich aus';

  -- ═══ Test 4: fremder Automat mittendrin → Ablehnung, keine Teilbuchung ═══
  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book4;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(
      v_book4, NULL, 80.00, 70.00, 0, 'Tour-Entnahme', 'Rücklage',
      jsonb_build_array(
        jsonb_build_object('machine_id', v_machine_a, 'amount', 20.00),
        jsonb_build_object('machine_id', v_other_machine, 'amount', 15.00),
        jsonb_build_object('machine_id', v_machine_c, 'amount', 10.00)
      )
    );
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%machine does not belong to this company%',
    format('erwartet die Firmenprüfung, kam aber: %s', v_err);

  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book4;
  ASSERT n_after = n,
    format('ein fremder Automat mittendrin darf keine Teilbuchung hinterlassen: vorher %s, nachher %s',
           n, n_after);
  RAISE NOTICE 'Test 4 bestanden: fremder Automat abgewiesen, keine Teilbuchung';

  -- ═══ Test 5: Storno der Mehrfach-Entnahme nimmt alle Zeilen mit ═════════
  res := public.reverse_cash_book_entry(v_withdrawal1);
  ASSERT res->>'reversal_entry_id' IS NOT NULL, 'Gegenbuchung zur Entnahme fehlt';
  ASSERT res->>'paired_reversal_entry_id' IS NOT NULL,
    'paired_reversal_entry_id muss weiterhin die erste Gegenbuchung tragen';
  ASSERT jsonb_typeof(res->'paired_reversal_entry_ids') = 'array',
    'paired_reversal_entry_ids muss ein Array sein';
  ASSERT jsonb_array_length(res->'paired_reversal_entry_ids') = 3,
    format('erwartet 3 stornierte Rücklagenzeilen, waren %s',
           jsonb_array_length(res->'paired_reversal_entry_ids'));

  -- Jede der drei ursprünglichen Rücklagenzeilen muss als storniert markiert sein.
  SELECT count(*) INTO n FROM public.cash_book_entries
   WHERE cash_book_id = v_book1 AND type = 'change_float' AND is_reversed = true;
  ASSERT n = 3, format('erwartet 3 stornierte Rücklagenzeilen, waren %s', n);

  ASSERT (SELECT is_reversed FROM public.cash_book_entries WHERE id = v_withdrawal1),
    'die Entnahme muss als storniert markiert sein';

  -- Kassenstand zurück auf 0 — Buch1 enthält ausschließlich diese Entnahme
  -- samt Rücklagen und deren Storno.
  SELECT balance_after INTO v_balance FROM public.cash_book_entries
   WHERE cash_book_id = v_book1 ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 0, format('Kassenstand nach Storno erwartet 0, war %s', v_balance);

  -- Vorgestrecktes Wechselgeld je Automat wieder auf null.
  SELECT COALESCE(-SUM(amount), 0) INTO v_amt FROM public.cash_book_entries
   WHERE cash_book_id = v_book1 AND type = 'change_float' AND machine_id = v_machine_a AND is_reversed = false;
  ASSERT v_amt = 0, format('Float A nach Storno erwartet 0, war %s', v_amt);
  SELECT COALESCE(-SUM(amount), 0) INTO v_amt FROM public.cash_book_entries
   WHERE cash_book_id = v_book1 AND type = 'change_float' AND machine_id = v_machine_b AND is_reversed = false;
  ASSERT v_amt = 0, format('Float B nach Storno erwartet 0, war %s', v_amt);
  SELECT COALESCE(-SUM(amount), 0) INTO v_amt FROM public.cash_book_entries
   WHERE cash_book_id = v_book1 AND type = 'change_float' AND machine_id = v_machine_c AND is_reversed = false;
  ASSERT v_amt = 0, format('Float C nach Storno erwartet 0, war %s', v_amt);
  RAISE NOTICE 'Test 5 bestanden: Storno nimmt alle Rücklagenzeilen mit';

  -- ═══ Test 6: der bestehende Einzelfall bleibt unverändert ═══════════════
  -- Aufruf über die volle 8-Parameter-Fassung mit p_floats = NULL — genau
  -- der Weg, den neue Clients künftig immer nehmen. change_float_entry_id
  -- muss weiterhin gefüllt sein, change_float_entry_ids leer bleiben.
  r := public.record_cash_book_withdrawal(
    v_book5, v_machine_a, 200.00, 180.00, 50.00, 'Entnahme', 'Wechselgeld Tuben', NULL
  );
  ASSERT r->>'withdrawal_entry_id' IS NOT NULL, 'withdrawal_entry_id fehlt';
  ASSERT r->>'change_float_entry_id' IS NOT NULL, 'change_float_entry_id fehlt im Einzelfall';
  ASSERT r->'change_float_entry_ids' = '[]'::jsonb,
    format('im Einzelfall erwartet change_float_entry_ids = [], war %s', r->'change_float_entry_ids');

  SELECT balance_after INTO v_balance FROM public.cash_book_entries
   WHERE cash_book_id = v_book5 ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 150.00, format('Kassenstand erwartet 150.00, war %s', v_balance);

  SELECT amount, paired_entry_id INTO v_amt, v_paired FROM public.cash_book_entries
   WHERE id = (r->>'change_float_entry_id')::uuid;
  ASSERT v_amt = -50.00, format('Rücklage erwartet -50.00, war %s', v_amt);
  ASSERT v_paired = (r->>'withdrawal_entry_id')::uuid, 'Rücklage muss weiterhin auf die Entnahme zeigen';

  -- Ein Aufruf mit nur 7 Argumenten (p_floats weggelassen, greift der
  -- Default NULL) muss weiterhin eindeutig auflösen und funktionieren —
  -- das ist die eigentliche "alte Signatur bleibt aufrufbar"-Garantie.
  r := public.record_cash_book_withdrawal(
    v_book5, NULL, 20.00, 20.00, 0, 'Entnahme ohne Rücklage', NULL
  );
  ASSERT r->>'withdrawal_entry_id' IS NOT NULL, '7-Argumente-Aufruf muss weiterhin funktionieren';
  ASSERT r->>'change_float_entry_id' IS NULL,
    'ohne Rücklage darf über den 7-Argumente-Aufruf keine Float-Zeile entstehen';
  RAISE NOTICE 'Test 6 bestanden: Einzelfall unverändert, 7-Argumente-Aufruf weiterhin eindeutig';

  -- ═══ Test 7: negativer Betrag in einem Element → Ablehnung ══════════════
  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book6;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(
      v_book6, NULL, 40.00, 40.00, 0, 'Entnahme', 'Rücklage',
      jsonb_build_array(jsonb_build_object('machine_id', v_machine_a, 'amount', -5.00))
    );
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%float back must be >= 0%',
    format('erwartet die Betragsprüfung, kam aber: %s', v_err);
  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book6;
  ASSERT n_after = n, 'ein negativer Betrag darf keine Zeile hinterlassen';
  RAISE NOTICE 'Test 7 bestanden: negativer Betrag abgewiesen';

  -- ═══ Test 8: fehlender machine_id in einem Element → Ablehnung ══════════
  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book7;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(
      v_book7, NULL, 40.00, 40.00, 0, 'Entnahme', 'Rücklage',
      jsonb_build_array(jsonb_build_object('amount', 5.00))
    );
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%change float requires a machine%',
    format('erwartet die Automaten-Vorabprüfung, kam aber: %s', v_err);
  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book7;
  ASSERT n_after = n, 'ein fehlender Automatenbezug darf keine Zeile hinterlassen';
  RAISE NOTICE 'Test 8 bestanden: fehlender Automatenbezug abgewiesen';

  -- ═══ Test 9: leeres Array verhält sich wie kein p_floats ════════════════
  r := public.record_cash_book_withdrawal(
    v_book8, NULL, 15.00, 15.00, 0, 'Entnahme', NULL, '[]'::jsonb
  );
  ASSERT r->>'change_float_entry_id' IS NULL, 'leeres Array darf keine Einzel-Float-Zeile erzeugen';
  ASSERT r->'change_float_entry_ids' = '[]'::jsonb, 'leeres Array muss leeres Ergebnis liefern';
  SELECT count(*) INTO n FROM public.cash_book_entries
   WHERE cash_book_id = v_book8 AND type = 'change_float';
  ASSERT n = 0, 'leeres Array darf keine Rücklagenzeile erzeugen';
  RAISE NOTICE 'Test 9 bestanden: leeres Array wie kein p_floats';

END $$;

ROLLBACK;
