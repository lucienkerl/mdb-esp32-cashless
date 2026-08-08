-- Tests für p_emptied_machine_ids auf record_cash_book_withdrawal und die
-- dafür erweiterte Anker-Logik in get_theoretical_cash
-- (migration 20260807000900_withdrawal_emptied_machines.sql).
--
-- Eine Entnahme trägt genau EIN machine_id, kann also nicht ausdrücken,
-- dass eine Tour zwei von drei Automaten einer Barkasse geleert hat.
-- p_emptied_machine_ids schließt diese Lücke: bei 2+ Automaten wird die
-- Liste gespeichert (machine_id bleibt NULL), bei genau einem Automaten
-- bleibt die heutige Darstellung (machine_id gesetzt, Liste NULL).
--
-- Läuft in einer zurückgerollten Transaktion. Voraussetzung:
-- `supabase start` + `supabase migration up`.
-- Jedes Szenario bekommt seine eigene Barkasse (+ eigene Automaten, wo
-- nötig), damit Zeilenzahl- und Saldo-Assertions sich nicht gegenseitig
-- verfälschen — Konvention aus cash_book_multi_float.test.sql.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company       uuid := gen_random_uuid();
  v_user          uuid := gen_random_uuid();
  v_other_company uuid := gen_random_uuid();
  v_other_machine uuid := gen_random_uuid();
  v_product       uuid := gen_random_uuid();

  -- Szenario 1: Teil-Tour {A,B} von {A,B,C}
  v_book1     uuid := gen_random_uuid();
  v_machine_a uuid := gen_random_uuid();
  v_machine_b uuid := gen_random_uuid();
  v_machine_c uuid := gen_random_uuid();

  -- Szenario 2: machine_id = NULL, keine Liste — unverändertes Verhalten
  v_book2      uuid := gen_random_uuid();
  v_machine_a2 uuid := gen_random_uuid();
  v_machine_b2 uuid := gen_random_uuid();
  v_machine_c2 uuid := gen_random_uuid();

  -- Szenario 3: Liste mit genau einem Automaten
  v_book3     uuid := gen_random_uuid();
  v_machine_d uuid := gen_random_uuid();

  -- Szenario 4: Liste + p_machine_id gleichzeitig → Ablehnung
  v_book4     uuid := gen_random_uuid();
  v_machine_e uuid := gen_random_uuid();
  v_machine_f uuid := gen_random_uuid();
  v_machine_g uuid := gen_random_uuid();

  -- Szenario 5: fremder Automat (andere Firma) in der Liste
  v_book5     uuid := gen_random_uuid();
  v_machine_h uuid := gen_random_uuid();

  -- Szenario 6: Automat gebunden an eine ANDERE Barkasse in der Liste
  v_book6           uuid := gen_random_uuid();
  v_book6_elsewhere uuid := gen_random_uuid();
  v_machine_i       uuid := gen_random_uuid();
  v_machine_j       uuid := gen_random_uuid();

  -- Szenario 7: Duplikat in der Liste
  v_book7     uuid := gen_random_uuid();
  v_machine_k uuid := gen_random_uuid();

  -- Szenario 8: track_per_machine = false — Liste bleibt wirkungslos
  v_book8     uuid := gen_random_uuid();
  v_machine_l uuid := gen_random_uuid();
  v_machine_m uuid := gen_random_uuid();
  v_machine_n uuid := gen_random_uuid();

  r jsonb; res jsonb; v_err text;
  v_withdrawal_id uuid;
  v_machine_id    uuid;
  v_emptied_ids   uuid[];
  n int; n_after int;
  a float8; b float8; c float8;
BEGIN
  -- ─── Firmen, Auth-User, Mitgliedschaft ────────────────────────────────
  INSERT INTO public.companies (id, name) VALUES (v_company, 'EmptiedMachinesCo');
  INSERT INTO public.companies (id, name) VALUES (v_other_company, 'FremdeFirmaEM');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'emptied@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'emptied@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  INSERT INTO public.products (id, name, company) VALUES (v_product, 'TestBar', v_company);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══════════════════════════════════════════════════════════════════
  -- Szenario 1: Barkasse {A,B,C}, track_per_machine = true. Eine Tour
  -- leert nur A und B über p_emptied_machine_ids — C bleibt unberührt
  -- und muss weiterhin seinen Umsatz VOR der Entnahme im theoretischen
  -- Bestand tragen.
  -- ═══════════════════════════════════════════════════════════════════
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book1, v_company, 'Buch1 Teil-Tour', 0, v_user, true);

  UPDATE public.cash_book_entries
     SET created_at = '2026-08-01 08:00+00'
   WHERE cash_book_id = v_book1 AND type = 'initial';

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id) VALUES
    (v_machine_a, 'A', v_company, v_book1),
    (v_machine_b, 'B', v_company, v_book1),
    (v_machine_c, 'C', v_company, v_book1);

  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock) VALUES
    (v_machine_a, 1, v_product, 100, 100),
    (v_machine_b, 1, v_product, 100, 100),
    (v_machine_c, 1, v_product, 100, 100);

  -- Umsatz aller drei Automaten VOR der Teil-Tour.
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at) VALUES
    (v_machine_a, 1, 1.00, 'cash', '2026-08-01 09:00+00'),
    (v_machine_b, 1, 2.00, 'cash', '2026-08-01 09:00+00'),
    (v_machine_c, 1, 3.00, 'cash', '2026-08-01 09:00+00');

  -- Entnahme leert NUR A und B — machine_id bleibt NULL, die Liste ist
  -- maßgeblich. counted = A+B-Umsatz = 3.00.
  r := public.record_cash_book_withdrawal(
    v_book1, NULL, 3.00, 3.00, 0, 'Teil-Tour A+B', NULL, NULL,
    ARRAY[v_machine_a, v_machine_b]
  );
  v_withdrawal_id := (r->>'withdrawal_entry_id')::uuid;
  ASSERT v_withdrawal_id IS NOT NULL, 'withdrawal_entry_id fehlt';

  SELECT machine_id, emptied_machine_ids INTO v_machine_id, v_emptied_ids
    FROM public.cash_book_entries WHERE id = v_withdrawal_id;
  ASSERT v_machine_id IS NULL,
    format('bei 2+ Automaten muss machine_id NULL bleiben, war %s', v_machine_id);
  ASSERT v_emptied_ids IS NOT NULL AND array_length(v_emptied_ids, 1) = 2,
    format('emptied_machine_ids muss die 2 Automaten enthalten, war %s', v_emptied_ids);
  ASSERT v_machine_a = ANY(v_emptied_ids) AND v_machine_b = ANY(v_emptied_ids),
    'emptied_machine_ids muss A und B enthalten';

  UPDATE public.cash_book_entries
     SET created_at = '2026-08-02 08:00+00'
   WHERE id = v_withdrawal_id;

  -- Umsatz NACH der Teil-Tour: nur A und B, C bleibt unberührt.
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at) VALUES
    (v_machine_a, 1, 0.30, 'cash', '2026-08-02 09:00+00'),
    (v_machine_b, 1, 0.70, 'cash', '2026-08-02 09:00+00');

  r := public.get_theoretical_cash(v_book1, v_company);
  SELECT (e->>'cash_sales')::float8 INTO a FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_a;
  SELECT (e->>'cash_sales')::float8 INTO b FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_b;
  SELECT (e->>'cash_sales')::float8 INTO c FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_c;

  ASSERT a = 0.30, format('A erwartet 0.30 (Umsatz seit der Teil-Tour), war %s', a);
  ASSERT b = 0.70, format('B erwartet 0.70 (Umsatz seit der Teil-Tour), war %s', b);
  ASSERT c = 3.00,
    format('C darf NICHT von der Teil-Tour verankert werden — erwartet weiterhin 3.00 seit initial, war %s', c);
  ASSERT (r->>'cash_sales_since')::float8 = 4.00,
    format('cash_sales_since erwartet 4.00 (0.30+0.70+3.00), war %s', r->>'cash_sales_since');
  RAISE NOTICE 'Test 1 bestanden: Teil-Tour verankert nur A und B, C bleibt unberührt';

  -- ═══════════════════════════════════════════════════════════════════
  -- Szenario 2: machine_id = NULL und KEINE Liste — unverändertes
  -- Verhalten, alle drei Automaten werden verankert (Legacy-Pfad).
  -- ═══════════════════════════════════════════════════════════════════
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book2, v_company, 'Buch2 Legacy NULL', 0, v_user, true);

  UPDATE public.cash_book_entries
     SET created_at = '2026-08-01 08:00+00'
   WHERE cash_book_id = v_book2 AND type = 'initial';

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id) VALUES
    (v_machine_a2, 'A2', v_company, v_book2),
    (v_machine_b2, 'B2', v_company, v_book2),
    (v_machine_c2, 'C2', v_company, v_book2);

  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock) VALUES
    (v_machine_a2, 1, v_product, 100, 100),
    (v_machine_b2, 1, v_product, 100, 100),
    (v_machine_c2, 1, v_product, 100, 100);

  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at) VALUES
    (v_machine_a2, 1, 1.00, 'cash', '2026-08-01 09:00+00'),
    (v_machine_b2, 1, 2.00, 'cash', '2026-08-01 09:00+00'),
    (v_machine_c2, 1, 3.00, 'cash', '2026-08-01 09:00+00');

  -- p_emptied_machine_ids explizit NULL — muss weiterhin alle Automaten
  -- verankern, genau wie vor dieser Migration.
  r := public.record_cash_book_withdrawal(
    v_book2, NULL, 6.00, 6.00, 0, 'Komplett-Tour', NULL, NULL, NULL
  );
  v_withdrawal_id := (r->>'withdrawal_entry_id')::uuid;
  UPDATE public.cash_book_entries
     SET created_at = '2026-08-02 08:00+00'
   WHERE id = v_withdrawal_id;

  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at) VALUES
    (v_machine_a2, 1, 0.10, 'cash', '2026-08-02 09:00+00'),
    (v_machine_b2, 1, 0.20, 'cash', '2026-08-02 09:00+00'),
    (v_machine_c2, 1, 0.30, 'cash', '2026-08-02 09:00+00');

  r := public.get_theoretical_cash(v_book2, v_company);
  SELECT (e->>'cash_sales')::float8 INTO a FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_a2;
  SELECT (e->>'cash_sales')::float8 INTO b FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_b2;
  SELECT (e->>'cash_sales')::float8 INTO c FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_c2;

  ASSERT a = 0.10, format('A2 erwartet 0.10 (alle Automaten verankert), war %s', a);
  ASSERT b = 0.20, format('B2 erwartet 0.20 (alle Automaten verankert), war %s', b);
  ASSERT c = 0.30, format('C2 erwartet 0.30 (alle Automaten verankert), war %s', c);
  RAISE NOTICE 'Test 2 bestanden: machine_id NULL ohne Liste verankert weiterhin alle Automaten';

  -- ═══════════════════════════════════════════════════════════════════
  -- Szenario 3: Liste mit genau einem Automaten → heutige Darstellung
  -- (machine_id gesetzt, emptied_machine_ids bleibt NULL).
  -- ═══════════════════════════════════════════════════════════════════
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book3, v_company, 'Buch3 Einzel-Liste', 0, v_user, true);
  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine_d, 'D', v_company, v_book3);

  r := public.record_cash_book_withdrawal(
    v_book3, NULL, 25.00, 25.00, 0, 'Einzel-Automat via Liste', NULL, NULL,
    ARRAY[v_machine_d]
  );
  v_withdrawal_id := (r->>'withdrawal_entry_id')::uuid;
  SELECT machine_id, emptied_machine_ids INTO v_machine_id, v_emptied_ids
    FROM public.cash_book_entries WHERE id = v_withdrawal_id;
  ASSERT v_machine_id = v_machine_d,
    format('bei genau einem Automaten muss machine_id gesetzt sein, war %s', v_machine_id);
  ASSERT v_emptied_ids IS NULL,
    format('bei genau einem Automaten muss emptied_machine_ids NULL bleiben, war %s', v_emptied_ids);
  RAISE NOTICE 'Test 3 bestanden: Liste mit einem Automaten wird als machine_id gespeichert';

  -- ═══════════════════════════════════════════════════════════════════
  -- Szenario 4: Liste UND p_machine_id gleichzeitig → Ablehnung, keine Zeile.
  -- ═══════════════════════════════════════════════════════════════════
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book4, v_company, 'Buch4 Liste+machine_id', 0, v_user, true);
  INSERT INTO public."vendingMachine" (id, name, company) VALUES
    (v_machine_e, 'E', v_company),
    (v_machine_f, 'F', v_company),
    (v_machine_g, 'G', v_company);

  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book4;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(
      v_book4, v_machine_e, 10.00, 10.00, 0, 'Widerspruch', NULL, NULL,
      ARRAY[v_machine_f, v_machine_g]
    );
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%mutually exclusive%',
    format('erwartet die Ausschluss-Prüfung, kam aber: %s', v_err);
  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book4;
  ASSERT n_after = n, format('abgewiesener Aufruf darf keine Zeile hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 4 bestanden: p_machine_id und p_emptied_machine_ids schließen sich aus';

  -- ═══════════════════════════════════════════════════════════════════
  -- Szenario 5: Automat einer FREMDEN Firma in der Liste → Ablehnung.
  -- ═══════════════════════════════════════════════════════════════════
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book5, v_company, 'Buch5 fremde Firma', 0, v_user, true);
  INSERT INTO public."vendingMachine" (id, name, company) VALUES (v_machine_h, 'H', v_company);
  INSERT INTO public."vendingMachine" (id, name, company) VALUES (v_other_machine, 'Fremd', v_other_company);

  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book5;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(
      v_book5, NULL, 10.00, 10.00, 0, 'Fremde Firma', NULL, NULL,
      ARRAY[v_machine_h, v_other_machine]
    );
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%machine does not belong to this company%',
    format('erwartet die Firmenprüfung, kam aber: %s', v_err);
  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book5;
  ASSERT n_after = n,
    format('ein fremder Automat mittendrin darf keine Teilbuchung hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 5 bestanden: Automat einer fremden Firma in der Liste abgewiesen';

  -- ═══════════════════════════════════════════════════════════════════
  -- Szenario 6: Automat gebunden an eine ANDERE Barkasse in der Liste
  -- → Ablehnung.
  -- ═══════════════════════════════════════════════════════════════════
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine) VALUES
    (v_book6, v_company, 'Buch6 fremde Kasse', 0, v_user, true),
    (v_book6_elsewhere, v_company, 'Buch6 andere Kasse', 0, v_user, true);
  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id) VALUES
    (v_machine_i, 'I', v_company, v_book6),
    (v_machine_j, 'J', v_company, v_book6_elsewhere);

  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book6;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(
      v_book6, NULL, 10.00, 10.00, 0, 'Andere Kasse', NULL, NULL,
      ARRAY[v_machine_i, v_machine_j]
    );
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%machine does not belong to this cash book%',
    format('erwartet die Barkassen-Zugehörigkeitsprüfung, kam aber: %s', v_err);
  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book6;
  ASSERT n_after = n,
    format('ein Automat aus fremder Kasse in der Liste darf keine Teilbuchung hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 6 bestanden: Automat einer anderen Barkasse in der Liste abgewiesen';

  -- ═══════════════════════════════════════════════════════════════════
  -- Szenario 7: Duplikat in der Liste → Ablehnung.
  -- ═══════════════════════════════════════════════════════════════════
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book7, v_company, 'Buch7 Duplikat', 0, v_user, true);
  INSERT INTO public."vendingMachine" (id, name, company) VALUES (v_machine_k, 'K', v_company);

  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book7;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(
      v_book7, NULL, 10.00, 10.00, 0, 'Duplikat', NULL, NULL,
      ARRAY[v_machine_k, v_machine_k]
    );
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%duplicate%',
    format('erwartet die Duplikat-Prüfung, kam aber: %s', v_err);
  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book7;
  ASSERT n_after = n, format('ein Duplikat darf keine Zeile hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 7 bestanden: Duplikat in der Liste abgewiesen';

  -- ═══════════════════════════════════════════════════════════════════
  -- Szenario 8: track_per_machine = false — die Liste bleibt wirkungslos,
  -- der Anker ist weiterhin Barkassen-weit der letzte Eintrag, für ALLE
  -- Automaten, auch die NICHT in der Liste (N).
  -- ═══════════════════════════════════════════════════════════════════
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book8, v_company, 'Buch8 kein Tracking', 0, v_user, false);

  UPDATE public.cash_book_entries
     SET created_at = '2026-08-01 08:00+00'
   WHERE cash_book_id = v_book8 AND type = 'initial';

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id) VALUES
    (v_machine_l, 'L', v_company, v_book8),
    (v_machine_m, 'M', v_company, v_book8),
    (v_machine_n, 'N', v_company, v_book8);

  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock) VALUES
    (v_machine_l, 1, v_product, 100, 100),
    (v_machine_m, 1, v_product, 100, 100),
    (v_machine_n, 1, v_product, 100, 100);

  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at) VALUES
    (v_machine_l, 1, 1.00, 'cash', '2026-08-01 09:00+00'),
    (v_machine_m, 1, 2.00, 'cash', '2026-08-01 09:00+00'),
    (v_machine_n, 1, 3.00, 'cash', '2026-08-01 09:00+00');

  -- Liste nennt nur L und M — N bewusst ausgelassen, um zu beweisen,
  -- dass die Liste im OFF-Zweig gar nicht erst gelesen wird.
  r := public.record_cash_book_withdrawal(
    v_book8, NULL, 3.00, 3.00, 0, 'Teil-Tour ohne Tracking', NULL, NULL,
    ARRAY[v_machine_l, v_machine_m]
  );
  v_withdrawal_id := (r->>'withdrawal_entry_id')::uuid;
  UPDATE public.cash_book_entries
     SET created_at = '2026-08-02 08:00+00'
   WHERE id = v_withdrawal_id;

  r := public.get_theoretical_cash(v_book8, v_company);
  SELECT (e->>'cash_sales')::float8 INTO a FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_l;
  SELECT (e->>'cash_sales')::float8 INTO b FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_m;
  SELECT (e->>'cash_sales')::float8 INTO c FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_n;

  -- Barkassen-weiter letzter Eintrag ist die Entnahme selbst — alle drei
  -- lesen 0.00, inklusive N, das gar nicht in der Liste stand.
  ASSERT a = 0.00, format('OFF: L erwartet 0.00 (Barkassen-weiter Anker), war %s', a);
  ASSERT b = 0.00, format('OFF: M erwartet 0.00 (Barkassen-weiter Anker), war %s', b);
  ASSERT c = 0.00,
    format('OFF: N (nicht in der Liste) erwartet ebenfalls 0.00 — die Liste darf im OFF-Zweig keine Wirkung haben, war %s', c);
  RAISE NOTICE 'Test 8 bestanden: track_per_machine=false ignoriert die Liste vollständig';

END $$;

ROLLBACK;
