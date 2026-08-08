-- Storno einer Entnahme muss ihre Wechselgeld-Rücklage mitstornieren.
-- Ohne das bliebe die Rücklage verwaist: Kassenstand zu niedrig, und der
-- Automat führte dauerhaft Wechselgeld, das längst zurückgeholt wurde.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company uuid := gen_random_uuid();
  v_user    uuid := gen_random_uuid();
  v_book    uuid := gen_random_uuid();
  v_machine uuid := gen_random_uuid();
  v_book2     uuid := gen_random_uuid();
  v_machine2  uuid := gen_random_uuid();
  r jsonb; res jsonb;
  v_withdrawal uuid; v_float uuid;
  v_balance float8; v_float_bal float8; n int; v_err text;
  v_reversal_of_withdrawal uuid;
  v_withdrawal2   uuid;
  v_before_number integer;
  v_neg_count     integer;
  v_row_count_before integer;
  v_row_count_after  integer;
  v_withdrawal3 uuid; v_float3 uuid;
  v_withdrawal4 uuid; v_number4 integer;
  v_desc text;
  v_book3    uuid := gen_random_uuid();
  v_machine_x uuid := gen_random_uuid();
  v_machine_y uuid := gen_random_uuid();
  v_withdrawal5 uuid;
  v_float_ids   jsonb;
  v_pair_ids    jsonb;
  v_float_x_id  uuid; v_float_y_id uuid;
  v_float_x_number integer; v_float_y_number integer;
  v_target_number  integer;
  v_float3_number  integer;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'PairCo');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'pair@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'pair@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book, v_company, 'PairKasse', 0, v_user);
  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine, 'A', v_company, v_book);

  -- Zweite Kasse + eigener Automat für den Zwischensaldo-Test (Fix 1) —
  -- damit er nicht vom bereits bewegten Saldo der ersten Kasse abhängt.
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book2, v_company, 'PairKasse2', 0, v_user);
  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine2, 'A2', v_company, v_book2);

  -- Dritte Kasse + zwei Automaten für Test 11 (mehrere Rücklagenzeilen,
  -- jede mit ihrer eigenen entry_number in der Gegenbuchung) — eigener
  -- Kassenstand, damit er nicht von den vorherigen Tests abhängt.
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book3, v_company, 'PairKasse3', 0, v_user);
  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine_x, 'X', v_company, v_book3);
  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine_y, 'Y', v_company, v_book3);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- Entnahme 200 mit Rücklage 50 → Saldo 150, Float 50
  r := public.record_cash_book_withdrawal(v_book, v_machine, 200.00, 180.00, 50.00,
                                          'Entnahme', 'Wechselgeld');
  v_withdrawal := (r->>'withdrawal_entry_id')::uuid;
  v_float      := (r->>'change_float_entry_id')::uuid;

  -- ═══ Test 1: die Float-Zeile zeigt auf ihre Entnahme ═════════════════════
  ASSERT (SELECT paired_entry_id FROM public.cash_book_entries WHERE id = v_float) = v_withdrawal,
    'die Wechselgeldzeile muss auf ihre Entnahme zeigen';
  RAISE NOTICE 'Test 1 bestanden: Verkettung gesetzt';

  -- ═══ Test 2: Storno der Entnahme storniert beide ═════════════════════════
  res := public.reverse_cash_book_entry(v_withdrawal);
  ASSERT res->>'reversal_entry_id' IS NOT NULL, 'Gegenbuchung zur Entnahme fehlt';
  ASSERT res->>'paired_reversal_entry_id' IS NOT NULL, 'Gegenbuchung zur Rücklage fehlt';

  ASSERT (SELECT is_reversed FROM public.cash_book_entries WHERE id = v_withdrawal),
    'Entnahme muss als storniert markiert sein';
  ASSERT (SELECT is_reversed FROM public.cash_book_entries WHERE id = v_float),
    'Rücklage muss als storniert markiert sein';
  -- für Test 8 (Storno eines Stornos) gesichert, bevor `res` von Test 5
  -- überschrieben wird.
  v_reversal_of_withdrawal := (res->>'reversal_entry_id')::uuid;
  RAISE NOTICE 'Test 2 bestanden: beide storniert';

  -- ═══ Test 3: Saldo und Float sind wieder auf null ════════════════════════
  SELECT balance_after INTO v_balance FROM public.cash_book_entries
   WHERE cash_book_id = v_book ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 0, format('Kassenstand nach Storno erwartet 0, war %s', v_balance);

  SELECT COALESCE(-SUM(amount), 0) INTO v_float_bal FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float' AND is_reversed = false;
  ASSERT v_float_bal = 0, format('Float nach Storno erwartet 0, war %s', v_float_bal);
  RAISE NOTICE 'Test 3 bestanden: Saldo und Float zurückgesetzt';

  -- ═══ Test 4: Doppel-Storno wird abgewiesen, ohne Teilbuchung ═════════════
  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book;
  v_err := '';
  BEGIN
    PERFORM public.reverse_cash_book_entry(v_withdrawal);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err <> '', 'ein zweites Storno derselben Zeile muss scheitern';
  ASSERT (SELECT count(*) FROM public.cash_book_entries WHERE cash_book_id = v_book) = n,
    'ein abgewiesenes Storno darf keine Zeile hinterlassen';
  RAISE NOTICE 'Test 4 bestanden: Doppel-Storno abgewiesen';

  -- ═══ Test 5: Storno einer Entnahme OHNE Rücklage bleibt einfach ══════════
  r := public.record_cash_book_withdrawal(v_book, v_machine, 30.00, 30.00, 0,
                                          'Entnahme ohne Rücklage', NULL);
  res := public.reverse_cash_book_entry((r->>'withdrawal_entry_id')::uuid);
  ASSERT res->>'paired_reversal_entry_id' IS NULL,
    'ohne Rücklage darf keine zweite Gegenbuchung entstehen';
  RAISE NOTICE 'Test 5 bestanden: einfache Entnahme unverändert';

  -- ═══ Test 6: fremde Zeile wird abgewiesen ════════════════════════════════
  v_err := '';
  BEGIN
    PERFORM public.reverse_cash_book_entry(gen_random_uuid());
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err <> '', 'eine unbekannte Zeile muss abgewiesen werden';
  RAISE NOTICE 'Test 6 bestanden: unbekannte Zeile abgewiesen';

  -- ═══ Test 7: Zwischensaldo beim Storno wird nie negativ (Fix 1) ═════════
  -- Kasse bei 0, Entnahme 100, Rücklage 90 zurück in den Automaten →
  -- Saldo 10. Storniert man die Entnahme, darf zu keinem Zeitpunkt eine
  -- negative Zwischenzeile in die unveränderliche Kette geschrieben werden
  -- — der klassische Kassensturzfähigkeit-Befund in einer GoBD-Prüfung.
  -- Die alte Reihenfolge (erst die Entnahme-Gegenbuchung, dann die
  -- Rücklagen-Gegenbuchung) erzeugte genau hier balance_after = -90.
  r := public.record_cash_book_withdrawal(v_book2, v_machine2, 100.00, 90.00, 90.00,
                                          'Entnahme', 'Wechselgeld');
  v_withdrawal2 := (r->>'withdrawal_entry_id')::uuid;

  SELECT max(entry_number) INTO v_before_number
    FROM public.cash_book_entries WHERE cash_book_id = v_book2;

  v_row_count_before := (SELECT count(*) FROM public.cash_book_entries WHERE cash_book_id = v_book2);
  res := public.reverse_cash_book_entry(v_withdrawal2);
  v_row_count_after := (SELECT count(*) FROM public.cash_book_entries WHERE cash_book_id = v_book2);

  ASSERT v_row_count_after = v_row_count_before + 2,
    format('Storno mit einer Rücklage muss genau 2 Zeilen anlegen, waren %s',
           v_row_count_after - v_row_count_before);

  SELECT count(*) INTO v_neg_count FROM public.cash_book_entries
   WHERE cash_book_id = v_book2 AND entry_number > v_before_number AND balance_after < 0;
  ASSERT v_neg_count = 0,
    format('während des Stornos dürfen keine negativen Zwischensalden entstehen, gefunden %s',
           v_neg_count);

  SELECT balance_after INTO v_balance FROM public.cash_book_entries
   WHERE cash_book_id = v_book2 ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 0, format('Kassenstand nach Storno erwartet 0, war %s', v_balance);
  RAISE NOTICE 'Test 7 bestanden: kein negativer Zwischensaldo beim Storno';

  -- ═══ Test 8: Storno eines Stornos wird abgewiesen (Fix 2) ═══════════════
  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book;
  v_err := '';
  BEGIN
    PERFORM public.reverse_cash_book_entry(v_reversal_of_withdrawal);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%cannot reverse a reversal%',
    format('erwartet die Storno-eines-Stornos-Ablehnung, kam aber: %s', v_err);
  ASSERT (SELECT count(*) FROM public.cash_book_entries WHERE cash_book_id = v_book) = n,
    'ein abgewiesenes Storno-eines-Stornos darf keine Zeile hinterlassen';
  RAISE NOTICE 'Test 8 bestanden: Storno eines Stornos abgewiesen';

  -- ═══ Test 9: eine übergebene Bezeichnung ergibt '<Bezeichnung> #N' auf
  --             der Gegenbuchung DER ZIELZEILE (20260807000800) ══════════
  -- p_description/p_paired_description sind seit 20260807000800 keine
  -- vollen Beschreibungen mehr, sondern lokalisierte Bezeichnungen, an die
  -- die Funktion selbst " #" + die entry_number der jeweils betroffenen
  -- Zeile anhängt — damit trägt jede Gegenbuchung ihren eigenen
  -- Rückverweis statt eines für alle Zeilen identischen Texts.
  r := public.record_cash_book_withdrawal(v_book, v_machine, 40.00, 40.00, 15.00,
                                          'Entnahme mit Rücklage', 'Rücklage für Storno-Test');
  v_withdrawal3 := (r->>'withdrawal_entry_id')::uuid;
  v_float3      := (r->>'change_float_entry_id')::uuid;

  SELECT entry_number INTO v_target_number FROM public.cash_book_entries WHERE id = v_withdrawal3;
  SELECT entry_number INTO v_float3_number FROM public.cash_book_entries WHERE id = v_float3;

  res := public.reverse_cash_book_entry(v_withdrawal3, 'Reversal of withdrawal', 'Reversal of float');

  SELECT description INTO v_desc FROM public.cash_book_entries
   WHERE id = (res->>'reversal_entry_id')::uuid;
  ASSERT v_desc = format('Reversal of withdrawal #%s', v_target_number),
    format('Bezeichnung + eigene Nummer für die Entnahme-Gegenbuchung erwartet, war %s', v_desc);

  SELECT description INTO v_desc FROM public.cash_book_entries
   WHERE id = (res->>'paired_reversal_entry_id')::uuid;
  ASSERT v_desc = format('Reversal of float #%s', v_float3_number),
    format('Bezeichnung + eigene Nummer für die Rücklagen-Gegenbuchung erwartet, war %s', v_desc);
  RAISE NOTICE 'Test 9 bestanden: übergebene Bezeichnung + eigene Nummer auf der Gegenbuchung';

  -- ═══ Test 10: NULL fällt auf 'Storno von Eintrag #N' zurück, byte-für-
  --              byte identisch zum bisherigen Text (20260807000800) ═════
  r := public.record_cash_book_withdrawal(v_book, v_machine, 25.00, 25.00, 5.00,
                                          'Entnahme ohne Storno-Text', 'Rücklage ohne Storno-Text');
  v_withdrawal4 := (r->>'withdrawal_entry_id')::uuid;

  SELECT entry_number INTO v_number4 FROM public.cash_book_entries WHERE id = v_withdrawal4;

  res := public.reverse_cash_book_entry(v_withdrawal4);

  SELECT description INTO v_desc FROM public.cash_book_entries
   WHERE id = (res->>'reversal_entry_id')::uuid;
  ASSERT v_desc = format('Storno von Eintrag #%s', v_number4),
    format('deutscher Fallback-Text für die Entnahme-Gegenbuchung erwartet, war %s', v_desc);

  SELECT description INTO v_desc FROM public.cash_book_entries
   WHERE id = (res->>'paired_reversal_entry_id')::uuid;
  ASSERT v_desc LIKE 'Storno von Eintrag #%',
    format('deutscher Fallback-Text für die Rücklagen-Gegenbuchung erwartet, war %s', v_desc);
  RAISE NOTICE 'Test 10 bestanden: NULL fällt auf deutschen Standardtext "Storno von Eintrag #N" zurück';

  -- ═══ Test 11: mehrere Rücklagenzeilen → jede Gegenbuchung trägt ihre
  --              EIGENE entry_number, nicht eine gemeinsame (20260807000800) ═══
  -- Ohne den Fix hätte ein einziges p_paired_description wortwörtlich auf
  -- ALLE Gegenbuchungen gepasst — jede hätte denselben Text getragen und
  -- damit ihren individuellen Rückverweis auf die Zeile verloren, die sie
  -- tatsächlich storniert.
  r := public.record_cash_book_withdrawal(
    v_book3, NULL, 100.00, 70.00, 0, 'Tour-Entnahme', 'Rücklage Standard',
    jsonb_build_array(
      jsonb_build_object('machine_id', v_machine_x, 'amount', 15.00),
      jsonb_build_object('machine_id', v_machine_y, 'amount', 15.00)
    )
  );
  v_withdrawal5 := (r->>'withdrawal_entry_id')::uuid;
  v_float_ids   := r->'change_float_entry_ids';
  ASSERT jsonb_array_length(v_float_ids) = 2,
    format('erwartet 2 Rücklagenzeilen, waren %s', jsonb_array_length(v_float_ids));

  v_float_x_id := (v_float_ids->>0)::uuid;
  v_float_y_id := (v_float_ids->>1)::uuid;
  SELECT entry_number INTO v_float_x_number FROM public.cash_book_entries WHERE id = v_float_x_id;
  SELECT entry_number INTO v_float_y_number FROM public.cash_book_entries WHERE id = v_float_y_id;
  ASSERT v_float_x_number <> v_float_y_number,
    'die beiden Rücklagenzeilen müssen unterschiedliche entry_number haben (Testvoraussetzung)';

  res := public.reverse_cash_book_entry(v_withdrawal5, 'Reversal of entry', 'Reversal of entry');
  v_pair_ids := res->'paired_reversal_entry_ids';
  ASSERT jsonb_array_length(v_pair_ids) = 2,
    format('erwartet 2 Rücklagen-Gegenbuchungen, waren %s', jsonb_array_length(v_pair_ids));

  -- Die Gegenbuchung, die die X-Rücklage korrigiert, muss X's eigene Nummer
  -- tragen — nicht Y's, und nicht irgendeine gemeinsame.
  SELECT description INTO v_desc FROM public.cash_book_entries
   WHERE corrects_entry_id = v_float_x_id;
  ASSERT v_desc = format('Reversal of entry #%s', v_float_x_number),
    format('Gegenbuchung von X erwartet eigene Nummer %s, Beschreibung war %s', v_float_x_number, v_desc);

  SELECT description INTO v_desc FROM public.cash_book_entries
   WHERE corrects_entry_id = v_float_y_id;
  ASSERT v_desc = format('Reversal of entry #%s', v_float_y_number),
    format('Gegenbuchung von Y erwartet eigene Nummer %s, Beschreibung war %s', v_float_y_number, v_desc);
  RAISE NOTICE 'Test 11 bestanden: jede Rücklagen-Gegenbuchung trägt ihre eigene entry_number';

END $$;

ROLLBACK;
