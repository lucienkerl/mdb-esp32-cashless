-- =========================================================
-- Kassenbuch: Rücklage je Automat auf einer Tour
--
-- Auf einer Tour bucht das Entnahme-Sheet eine Entnahme über alle
-- besuchten Automaten der Barkasse. Für die Rücklage musste der
-- Bediener bislang genau einen Automaten wählen — der gesamte Betrag
-- landete dort. Der Automatenbezug, der der ganze Zweck der
-- change_float-Buchungsart ist, wurde damit still falsch.
--
-- record_cash_book_withdrawal bekommt dafür einen neuen, letzten
-- Parameter p_floats jsonb DEFAULT NULL: ein Array aus
-- {"machine_id": uuid, "amount": number, "description": text?}.
-- p_float_back bleibt unverändert für den Einzelfall erhalten und
-- schließt sich mit p_floats gegenseitig aus.
--
-- WICHTIG zur Funktionsidentität: die Parametertypliste (8 Typen)
-- unterscheidet sich von der bisherigen (7 Typen aus 20260807000400).
-- CREATE OR REPLACE ersetzt eine Funktion nur, wenn Name UND
-- Parametertypliste exakt übereinstimmen — bei einer zusätzlichen
-- Parameterposition legt es stattdessen eine zweite Überladung an.
-- Das klingt zunächst nach "die alte Signatur bleibt bestehen", erzeugt
-- aber eine echte Mehrdeutigkeit: ruft ein Client mit genau 7 (auch
-- benannten) Argumenten auf, hat Postgres zwei gleich gute Kandidaten
-- (die 7-Parameter-Funktion exakt, und die 8-Parameter-Funktion mit
-- einem Default für p_floats) und lehnt mit "is not unique" ab — das
-- hätte in der Praxis JEDEN bestehenden Aufruf aus PWA und iOS
-- gebrochen (beide rufen mit benannten Parametern, nicht positionell,
-- auf; siehe #cash_book_change_float_rpc.test.sql Test 7, das genau
-- diesen Fehler beim ersten Anlauf dieser Migration reproduzierte).
--
-- Die alte 7-Parameter-Funktion wird deshalb zuerst explizit gedroppt;
-- was danach als "alte Signatur bleibt aufrufbar" übrig bleibt, ist ein
-- einziger Funktionskörper mit acht Parametern, bei dem p_floats einen
-- Default von NULL hat — ein Aufruf mit sieben Argumenten (ob
-- positionell oder benannt) trifft ihn eindeutig.
--
-- Der Funktionskörper unten repliziert deshalb bewusst alle sechs Guards
-- aus der 20260807000400-Fassung unverändert (Authentifizierung,
-- Barkassen-Firmenzugehörigkeit, counted >= 0, float >= 0,
-- Rücklage-ohne-Automat, Automaten-Firmenzugehörigkeit) — sie werden nur
-- für den Fall gebraucht, dass ein Client die neue 8-Parameter-Fassung
-- mit p_floats = NULL aufruft (das tun künftige iOS-Clients immer).
--
-- Validierung vor jedem Insert: alle Elemente von p_floats werden in
-- einer eigenen Schleife geprüft, BEVOR irgendeine Zeile geschrieben
-- wird. Ein fremder Automat mittendrin in der Liste darf keine
-- Teilbuchung der vorherigen, gültigen Elemente hinterlassen.
--
-- reverse_cash_book_entry muss dafür mehrere Gegenzeilen verkraften —
-- die Fassung aus 20260807000400 sucht per nicht-STRICT SELECT … INTO
-- nur eine beliebige heraus und ließ bei mehreren Treffern den Rest
-- verwaist. Sie wird hier per CREATE OR REPLACE (unveränderte
-- Signatur, also eine echte Ersetzung) so umgebaut, dass sie über alle
-- verketteten, nicht-stornierten Zeilen schleift, deterministisch
-- geordnet nach entry_number.
-- =========================================================

-- 1. record_cash_book_withdrawal: p_floats als neuer, letzter Parameter.
--    Die alte 7-Parameter-Funktion muss zuerst weg — siehe Begründung
--    oben, sonst entsteht eine mehrdeutige Überladung.
DROP FUNCTION IF EXISTS public.record_cash_book_withdrawal(
  uuid, uuid, float8, float8, float8, text, text
);

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

-- 2. reverse_cash_book_entry: über alle verketteten Zeilen schleifen.
CREATE OR REPLACE FUNCTION public.reverse_cash_book_entry(
  p_entry_id uuid
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
  v_reversal    uuid;
  v_pair_rev    uuid;       -- erste Gegenbuchung, für die alte Rückgabe
  v_pair_revs   uuid[] := '{}';
  v_partner     record;
  v_partner_rev uuid;
BEGIN
  IF v_company IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT cash_book_id, entry_number
    INTO v_book, v_number
    FROM public.cash_book_entries
   WHERE id = p_entry_id AND company_id = v_company;

  IF v_book IS NULL THEN
    RAISE EXCEPTION 'entry not found';
  END IF;

  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, description,
     corrects_entry_id, created_by)
  VALUES
    (v_book, v_company, 'reversal', 0,
     format('Storno von Eintrag #%s', v_number), p_entry_id, v_user)
  RETURNING id INTO v_reversal;

  -- Alle verketteten, nicht-stornierten Gegenzeilen, deterministisch
  -- geordnet. Eine Mehrfach-Float-Entnahme kann mehr als eine
  -- Gegenzeile haben — die vorherige Fassung suchte per nicht-STRICT
  -- SELECT … INTO nur eine beliebige heraus und ließ den Rest verwaist.
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
       format('Storno von Eintrag #%s', v_partner.entry_number),
       v_partner.id, v_user)
    RETURNING id INTO v_partner_rev;

    v_pair_revs := array_append(v_pair_revs, v_partner_rev);
    IF v_pair_rev IS NULL THEN
      v_pair_rev := v_partner_rev;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'reversal_entry_id',         v_reversal,
    'paired_reversal_entry_id',  v_pair_rev,
    'paired_reversal_entry_ids', to_jsonb(v_pair_revs)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.reverse_cash_book_entry(uuid) TO authenticated;
