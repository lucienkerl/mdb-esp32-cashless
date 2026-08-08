-- =========================================================
-- Kassenbuch: Storno-Härtung + Automaten-Kassenbindung
--
-- Vier Befunde aus der abschließenden Review der change-float-Feature-
-- Branch, alle in den beiden RPCs aus 20260807000500:
--
-- 1. reverse_cash_book_entry schrieb die Gegenbuchung der Entnahme (ein
--    negativer Betrag) VOR den Gegenbuchungen ihrer Rücklagen (positive
--    Beträge). Bei einer Kasse auf 0, einer Entnahme von 100 und einer
--    Rücklage von 90 zurück landete die Zwischenzeile bei
--    balance_after = -90 — ein negativer Kassenstand in der unveränder-
--    lichen Kette ist der klassische Kassensturzfähigkeit-Befund einer
--    GoBD-Prüfung. Fix: erst die Gegenbuchungen der Rücklagen (immer
--    positiv, heben den Saldo), danach erst die Gegenbuchung der
--    Entnahme selbst. Die Rückgabe-Bedeutung (reversal_entry_id =
--    eigenes Storno, paired_reversal_entry_id(s) = Partner-Stornos)
--    bleibt dabei unverändert — nur die Insert-Reihenfolge dreht sich um.
--
-- 2. reverse_cash_book_entry prüfte nie den type der Zielzeile. Ein
--    Storno einer bereits stornierten Rücklage (type = 'reversal') war
--    möglich und entsynchronisierte is_reversed vom tatsächlichen
--    Kasseneffekt: eine Rücklagenzeile konnte als storniert markiert
--    sein, während ihr Betrag weiterhin im Saldo steckte. Fix: die
--    Zielzeile ablehnen, wenn ihr type bereits 'reversal' ist.
--
-- 3. Die Storno-Beschreibung war hart auf Deutsch verdrahtet
--    ('Storno von Eintrag #%s') — in einer App mit de/en/fr/nl-i18n
--    liest damit jeder nicht-deutsche Betreiber diesen Text dauerhaft
--    in seiner Belegliste und im PDF. Fix: zwei neue, optionale
--    Parameter p_description / p_paired_description; NULL fällt weiter
--    auf den deutschen Text zurück, damit bestehende Aufrufer
--    unverändert funktionieren.
--
-- WICHTIG zur Funktionsidentität: Punkt 3 fügt reverse_cash_book_entry
-- zwei neue Parameter mit Default hinzu. Ein CREATE OR REPLACE mit einer
-- zusätzlichen Parameterposition ersetzt die bestehende 1-Parameter-
-- Funktion NICHT — es legt eine zweite, überladene Funktion an. Ein
-- Aufruf mit genau einem Argument (der einzige heute existierende
-- Aufruf, siehe management-frontend/app/composables/useCashBook.ts)
-- fände dann zwei gleich gute Kandidaten (die 1-Parameter-Funktion
-- exakt, und die 3-Parameter-Funktion mit zwei Defaults) und schlägt mit
-- "is not unique" fehl — exakt der Fehler, der die Vorgänger-Migration
-- 20260807000500 beim ersten Anlauf schon einmal gebrochen hat (siehe
-- deren Kommentar). Die alte 1-Parameter-Funktion wird deshalb zuerst
-- explizit gedroppt; DROP FUNCTION verwirft dabei alle Grants, weshalb
-- GRANT EXECUTE für die neue Signatur unten erneut ausgeführt wird.
--
-- 4. record_cash_book_withdrawal prüfte jeden Automaten aus p_floats
--    (und den einzelnen p_machine_id) nur gegen die Firma des Aufrufers,
--    nie gegen die Ziel-Barkasse p_cash_book_id. Ein Automat, der einer
--    ANDEREN Barkasse derselben Firma zugeordnet ist, ließ sich damit
--    versehentlich in eine fremde Kasse hinein buchen. Fix: zusätzliche
--    Prüfung, dass vendingMachine.cash_book_id — falls gesetzt — mit
--    p_cash_book_id übereinstimmt. cash_book_id ist nullable und kann
--    umgehängt werden (20260407000000_cash_book.sql, ON DELETE SET
--    NULL); ein Automat OHNE Zuordnung muss weiterhin überall buchbar
--    bleiben, sonst bricht der Alltagsfall (frisch angelegte oder
--    unzugeordnete Automaten). Die Prüfung greift deshalb nur, wenn
--    cash_book_id gesetzt UND abweichend ist.
--
--    record_cash_book_withdrawal wird per CREATE OR REPLACE mit
--    unveränderter Signatur (8 Parameter, exakt wie 20260807000500)
--    ersetzt — keine neue Überladung, kein DROP nötig, Grants bleiben
--    erhalten. Der Funktionskörper reproduziert bewusst ALLE Guards aus
--    20260807000500 unverändert (Authentifizierung, Barkassen-
--    Firmenzugehörigkeit, counted >= 0, float >= 0, p_float_back/
--    p_floats-Exklusivität, Rücklage-ohne-Automat, Automaten-
--    Firmenzugehörigkeit, p_floats-Array-Typprüfung, Vorab-Validierung
--    aller p_floats-Elemente vor dem ersten Insert) und ergänzt nur die
--    neue Kassenbindungs-Prüfung an zwei Stellen: einmal für den
--    einzelnen p_machine_id-Pfad, einmal je Element in der p_floats-
--    Vorabprüfschleife.
-- =========================================================

-- 1. record_cash_book_withdrawal: unveränderte Signatur, CREATE OR
--    REPLACE ersetzt die bestehende Funktion direkt — kein DROP nötig.
CREATE OR REPLACE FUNCTION public.record_cash_book_withdrawal(
  p_cash_book_id      uuid,
  p_machine_id        uuid,
  p_counted           float8,
  p_expected          float8,
  p_float_back        float8 DEFAULT 0,
  p_description       text   DEFAULT NULL,
  p_float_description text   DEFAULT NULL,
  p_floats            jsonb  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, extensions
AS $$
DECLARE
  v_company       uuid := public.my_company_id();
  v_user          uuid := auth.uid();
  v_float_back    float8 := COALESCE(p_float_back, 0);
  v_withdrawal_id uuid;
  v_float_id      uuid;
  v_has_floats    boolean := false;
  v_elem          jsonb;
  v_elem_amount   float8;
  v_elem_machine  uuid;
  v_elem_desc     text;
  v_float_ids     uuid[] := '{}';
  v_multi_float_id uuid;
BEGIN
  IF v_company IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- p_floats muss ein JSON-Array sein. jsonb_array_length wirft für einen
  -- Skalar oder ein Objekt einen rohen Low-Level-Fehler; die Prüfung gehört
  -- deshalb hierher und nicht in den DECLARE-Block, wo sie noch vor der
  -- Authentifizierung feuern würde.
  IF p_floats IS NOT NULL AND jsonb_typeof(p_floats) <> 'array' THEN
    RAISE EXCEPTION 'p_floats must be a JSON array';
  END IF;

  v_has_floats := p_floats IS NOT NULL AND jsonb_array_length(p_floats) > 0;

  PERFORM 1 FROM public.cash_books
   WHERE id = p_cash_book_id AND company_id = v_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cash book does not belong to this company';
  END IF;

  IF p_counted IS NULL OR p_counted < 0 THEN
    RAISE EXCEPTION 'counted amount must be >= 0';
  END IF;

  IF v_float_back < 0 THEN
    RAISE EXCEPTION 'float back must be >= 0';
  END IF;

  -- p_float_back und p_floats schließen sich gegenseitig aus. Das hält
  -- den bestehenden Einzelfall unverändert und verhindert, dass ein
  -- Client versehentlich beide Mechanismen gleichzeitig anstößt.
  IF v_has_floats AND v_float_back <> 0 THEN
    RAISE EXCEPTION 'p_float_back and p_floats are mutually exclusive';
  END IF;

  IF v_float_back <> 0 AND p_machine_id IS NULL THEN
    RAISE EXCEPTION 'change float requires a machine';
  END IF;

  IF p_machine_id IS NOT NULL THEN
    PERFORM 1 FROM public."vendingMachine"
     WHERE id = p_machine_id AND company = v_company;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'machine does not belong to this company';
    END IF;

    -- Fix 4: der Automat muss entweder gar keiner Barkasse zugeordnet
    -- sein (cash_book_id IS NULL — frisch angelegt oder bewusst
    -- unzugeordnet) oder genau dieser hier. Eine Zuordnung zu einer
    -- ANDEREN Barkasse derselben Firma wird abgewiesen.
    PERFORM 1 FROM public."vendingMachine"
     WHERE id = p_machine_id
       AND (cash_book_id IS NULL OR cash_book_id = p_cash_book_id);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'machine does not belong to this cash book';
    END IF;
  END IF;

  -- Vorabprüfung ALLER p_floats-Elemente, bevor irgendetwas geschrieben
  -- wird. Ohne diesen separaten Durchlauf würde ein fremder oder
  -- ungültiger Automat mittendrin in der Liste die vorherigen, gültigen
  -- Elemente bereits als Zeilen hinterlassen haben.
  IF v_has_floats THEN
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_floats)
    LOOP
      v_elem_amount := (v_elem->>'amount')::float8;
      IF v_elem_amount IS NULL OR v_elem_amount < 0 THEN
        RAISE EXCEPTION 'float back must be >= 0';
      END IF;

      -- Ein Nullbetrag wird übersprungen statt gebucht — er braucht
      -- daher auch keinen validierten Automatenbezug.
      CONTINUE WHEN v_elem_amount = 0;

      v_elem_machine := NULLIF(v_elem->>'machine_id', '')::uuid;
      IF v_elem_machine IS NULL THEN
        RAISE EXCEPTION 'change float requires a machine';
      END IF;

      PERFORM 1 FROM public."vendingMachine"
       WHERE id = v_elem_machine AND company = v_company;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'machine does not belong to this company';
      END IF;

      -- Fix 4, gleiche Regel wie oben für den Einzelfall.
      PERFORM 1 FROM public."vendingMachine"
       WHERE id = v_elem_machine
         AND (cash_book_id IS NULL OR cash_book_id = p_cash_book_id);
      IF NOT FOUND THEN
        RAISE EXCEPTION 'machine does not belong to this cash book';
      END IF;
    END LOOP;
  END IF;

  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, description,
     machine_id, counted_amount, expected_amount, created_by)
  VALUES
    (p_cash_book_id, v_company, 'withdrawal', p_counted, p_description,
     p_machine_id, p_counted, p_expected, v_user)
  RETURNING id INTO v_withdrawal_id;

  IF v_float_back <> 0 THEN
    INSERT INTO public.cash_book_entries
      (cash_book_id, company_id, type, amount, description,
       machine_id, created_by, paired_entry_id)
    VALUES
      (p_cash_book_id, v_company, 'change_float', -abs(v_float_back),
       p_float_description, p_machine_id, v_user, v_withdrawal_id)
    RETURNING id INTO v_float_id;
  END IF;

  IF v_has_floats THEN
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_floats)
    LOOP
      v_elem_amount := (v_elem->>'amount')::float8;
      CONTINUE WHEN v_elem_amount = 0;

      v_elem_machine := NULLIF(v_elem->>'machine_id', '')::uuid;
      v_elem_desc := COALESCE(v_elem->>'description', p_float_description);

      INSERT INTO public.cash_book_entries
        (cash_book_id, company_id, type, amount, description,
         machine_id, created_by, paired_entry_id)
      VALUES
        (p_cash_book_id, v_company, 'change_float', -abs(v_elem_amount),
         v_elem_desc, v_elem_machine, v_user, v_withdrawal_id)
      RETURNING id INTO v_multi_float_id;

      v_float_ids := array_append(v_float_ids, v_multi_float_id);
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'withdrawal_entry_id',    v_withdrawal_id,
    'change_float_entry_id',  v_float_id,
    'change_float_entry_ids', to_jsonb(v_float_ids)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_cash_book_withdrawal(
  uuid, uuid, float8, float8, float8, text, text, jsonb
) TO authenticated;


-- 2. reverse_cash_book_entry: neue Signatur (zwei zusätzliche optionale
--    Parameter) — die alte 1-Parameter-Funktion muss zuerst weg, siehe
--    Begründung oben, sonst entsteht eine mehrdeutige Überladung.
DROP FUNCTION IF EXISTS public.reverse_cash_book_entry(uuid);

CREATE OR REPLACE FUNCTION public.reverse_cash_book_entry(
  p_entry_id            uuid,
  p_description         text DEFAULT NULL,
  p_paired_description  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, extensions
AS $$
DECLARE
  v_company     uuid := public.my_company_id();
  v_user        uuid := auth.uid();
  v_book        uuid;
  v_number      integer;
  v_type        text;
  v_reversal    uuid;
  v_pair_rev    uuid;       -- erste Gegenbuchung, für die alte Rückgabe
  v_pair_revs   uuid[] := '{}';
  v_partner     record;
  v_partner_rev uuid;
BEGIN
  IF v_company IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT cash_book_id, entry_number, type
    INTO v_book, v_number, v_type
    FROM public.cash_book_entries
   WHERE id = p_entry_id AND company_id = v_company;

  IF v_book IS NULL THEN
    RAISE EXCEPTION 'entry not found';
  END IF;

  -- Fix 2: eine Gegenbuchung selbst darf nicht noch einmal storniert
  -- werden. Das ist unabhängig von is_reversed, das nur an der
  -- ursprünglichen (korrigierten) Zeile gesetzt wird — eine 'reversal'-
  -- Zeile trägt is_reversed selbst nie true und würde die bestehende
  -- Doppel-Storno-Prüfung im Trigger sonst nicht auslösen. Ohne diese
  -- Prüfung desynchronisiert ein Storno-eines-Stornos is_reversed vom
  -- tatsächlichen Kasseneffekt.
  IF v_type = 'reversal' THEN
    RAISE EXCEPTION 'cannot reverse a reversal';
  END IF;

  -- Fix 1: erst die Gegenbuchungen aller verketteten, nicht-stornierten
  -- Rücklagenzeilen einfügen — deren Beträge sind immer positiv (sie
  -- heben eine negative change_float-Buchung auf) und heben damit den
  -- Saldo, bevor überhaupt eine negative Zeile entsteht. Erst danach die
  -- Gegenbuchung der Entnahme selbst (negativ) einfügen. Die alte
  -- Reihenfolge schrieb hier zuerst die negative Entnahme-Gegenbuchung
  -- und erzeugte damit für einen Moment einen negativen Kassenstand in
  -- der unveränderlichen Kette — der klassische Kassensturzfähigkeit-
  -- Befund einer GoBD-Prüfung.
  --
  -- Eine Mehrfach-Float-Entnahme kann mehr als eine Gegenzeile haben —
  -- deterministisch geordnet nach entry_number der Original-Rücklagen.
  FOR v_partner IN
    SELECT id, entry_number
      FROM public.cash_book_entries
     WHERE paired_entry_id = p_entry_id
       AND company_id = v_company
       AND is_reversed = false
     ORDER BY entry_number
  LOOP
    INSERT INTO public.cash_book_entries
      (cash_book_id, company_id, type, amount, description,
       corrects_entry_id, created_by)
    VALUES
      (v_book, v_company, 'reversal', 0,
       COALESCE(p_paired_description,
                format('Storno von Eintrag #%s', v_partner.entry_number)),
       v_partner.id, v_user)
    RETURNING id INTO v_partner_rev;

    v_pair_revs := array_append(v_pair_revs, v_partner_rev);
    IF v_pair_rev IS NULL THEN
      v_pair_rev := v_partner_rev;
    END IF;
  END LOOP;

  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, description,
     corrects_entry_id, created_by)
  VALUES
    (v_book, v_company, 'reversal', 0,
     COALESCE(p_description, format('Storno von Eintrag #%s', v_number)),
     p_entry_id, v_user)
  RETURNING id INTO v_reversal;

  RETURN jsonb_build_object(
    'reversal_entry_id',         v_reversal,
    'paired_reversal_entry_id',  v_pair_rev,
    'paired_reversal_entry_ids', to_jsonb(v_pair_revs)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.reverse_cash_book_entry(uuid, text, text)
  TO authenticated;
