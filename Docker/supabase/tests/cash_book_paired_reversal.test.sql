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
  r jsonb; res jsonb;
  v_withdrawal uuid; v_float uuid;
  v_balance float8; v_float_bal float8; n int; v_err text;
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

END $$;

ROLLBACK;
