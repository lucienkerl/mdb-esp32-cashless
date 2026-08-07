-- Die INSERT-Policy auf cash_book_entries muss verhindern, dass in die
-- Barkasse einer fremden Firma gebucht wird. Ohne das verbraucht eine
-- eingeschleuste Zeile eine entry_number in deren Hash-Kette; die
-- Eigentümerin sieht die Zeile nie (ihr SELECT filtert auf company_id),
-- bekommt aber ab da dauerhaft eine gebrochene Kette gemeldet.
--
-- WICHTIG: der Testrunner verbindet als `postgres` mit rolbypassrls = true.
-- RLS greift für diese Rolle nicht, deshalb wird für die Policy-Prüfung
-- explizit auf `authenticated` gewechselt.
--
-- Zweite Falle: sobald auf `authenticated` gewechselt ist, greift RLS auch
-- für die eigenen Nachschlage-SELECTs. Die fremde cash_book_id lässt sich
-- deshalb NICHT per SELECT ermitteln (cash_books_select filtert exakt auf
-- die eigene Firma — das ist korrekt so und nicht Gegenstand dieses Tests).
-- Die IDs werden daher, solange die Transaktion noch als `postgres` läuft
-- (RLS-Bypass), in Session-GUCs zwischengelagert. Das bildet eine
-- Angreiferin nach, die die fremde cash_book_id bereits kennt (erraten,
-- geleakt, aus einem anderen Endpoint) — genau das Szenario, gegen das die
-- INSERT-Policy schützen muss.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_other     uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_book      uuid := gen_random_uuid();
  v_other_book uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'PolicyCo'), (v_other, 'FremdeCo');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'policy@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'policy@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book, v_company, 'Eigene', 0, v_user),
           (v_other_book, v_other, 'Fremde', 0, v_user);

  -- Noch als postgres (RLS-Bypass) zwischenlagern, siehe Kommentar oben.
  PERFORM set_config('vmflow_test.company', v_company::text, false);
  PERFORM set_config('vmflow_test.user', v_user::text, false);
  PERFORM set_config('vmflow_test.book', v_book::text, false);
  PERFORM set_config('vmflow_test.other_book', v_other_book::text, false);
END $$;

-- Ab hier als authentifizierter Nutzer, damit RLS überhaupt greift.
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_company    uuid := current_setting('vmflow_test.company')::uuid;
  v_user       uuid := current_setting('vmflow_test.user')::uuid;
  v_book       uuid := current_setting('vmflow_test.book')::uuid;
  v_other_book uuid := current_setting('vmflow_test.other_book')::uuid;
  v_err        text;
  n_before     int;
  n_after      int;
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 1: eigene Barkasse geht durch ══════════════════════════════════
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, description, created_by)
    VALUES (v_book, v_company, 'correction', 5, 'ok', v_user);
  RAISE NOTICE 'Test 1 bestanden: eigene Barkasse buchbar';

  -- ═══ Test 2: fremde Barkasse wird abgewiesen ═════════════════════════════
  -- Die eingeschleuste Zeile trüge company_id = v_company (die eigene
  -- Firma des Angreifers), ist also unter cash_book_entries_select für ihn
  -- selbst sichtbar — n_before/n_after belegt deshalb zuverlässig, ob die
  -- Zeile tatsächlich entstanden ist.
  SELECT count(*) INTO n_before FROM public.cash_book_entries WHERE cash_book_id = v_other_book;
  v_err := '';
  BEGIN
    INSERT INTO public.cash_book_entries
      (cash_book_id, company_id, type, amount, description, created_by)
      VALUES (v_other_book, v_company, 'correction', 5, 'einschleusen', v_user);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%row-level security%' OR v_err LIKE '%policy%',
    format('erwartet wurde ein RLS-Verstoß, kam aber: %s', v_err);

  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_other_book;
  ASSERT n_after = n_before,
    format('fremde Kette darf keine Zeile bekommen: vorher %s, nachher %s', n_before, n_after);
  RAISE NOTICE 'Test 2 bestanden: fremde Barkasse abgewiesen';

END $$;

RESET ROLE;

ROLLBACK;
