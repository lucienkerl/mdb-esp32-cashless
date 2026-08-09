-- Tests für record_cash_book_withdrawal (20260807000200).
--
-- Verschoben aus cash_book_change_float_rpc.test.sql (20260809000000): diese
-- Datei deckte ursprünglich sowohl get_machine_change_float als auch
-- record_cash_book_withdrawal ab. Die Bestandsabfrage get_machine_change_float
-- wurde mit der Bestandsanzeige selbst ersatzlos gestrichen und in derselben
-- Migration per DROP FUNCTION entfernt — die hier verbliebenen Fälle prüfen
-- ausschließlich record_cash_book_withdrawal und wurden in eine eigene Datei
-- verschoben statt eine halb leere Datei zurückzulassen. Der ehemalige
-- Test 8 ("Float-Bestand nach der Doppelbuchung") rief die inzwischen
-- entfernte RPC auf; er prüft denselben Sachverhalt jetzt direkt über
-- cash_book_entries.
--
-- Läuft in einer zurückgerollten Transaktion. Voraussetzung:
-- `supabase start` + `supabase migration up`.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company uuid := gen_random_uuid();
  v_user    uuid := gen_random_uuid();
  v_book    uuid := gen_random_uuid();
  v_machine uuid := gen_random_uuid();
  v_other_company uuid := gen_random_uuid();
  v_other_machine uuid := gen_random_uuid();
  v_other_book uuid := gen_random_uuid();
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

  -- ═══ Test 8: Float-Buchung nach der Doppelbuchung korrekt gebucht ════════
  -- Direkt über cash_book_entries geprüft statt über die inzwischen
  -- entfernte get_machine_change_float-RPC (20260809000000).
  SELECT COALESCE(-SUM(amount), 0) INTO v_balance
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float' AND machine_id = v_machine
     AND is_reversed = false;
  ASSERT v_balance = 50.00, format('Float erwartet 50.00, war %s', v_balance);
  RAISE NOTICE 'Test 8 bestanden: Float-Buchung nach der Doppelbuchung';

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

  -- ═══ Test 11: fremde Barkasse wird abgewiesen ════════════════════════════
  -- Ohne diese Prüfung ließe sich ein Eintrag in die hash-verkettete
  -- Historie einer fremden Firma einhängen.
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_other_book, v_other_company, 'FremdeKasse', 0, v_user);

  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_other_book;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(v_other_book, NULL, 10.00, 10.00, 0,
                                               'Geldentnahme', NULL);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%cash book does not belong to this company%',
    format('erwartet wurde die Barkassen-Firmenprüfung, kam aber: %s', v_err);

  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_other_book;
  ASSERT n_after = n,
    format('abgewiesener Aufruf darf keine Zeile hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 11 bestanden: fremde Barkasse abgewiesen';

END $$;

ROLLBACK;
