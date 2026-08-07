-- =========================================================
-- Kassenbuch: Entnahme mit optionaler Wechselgeld-Rücklage
--
-- Beim Leeren einer Kassette schiebt der Betreiber häufig Münzen direkt
-- zurück in die Münztuben. Gebucht wird trotzdem der VOLLE gezählte
-- Betrag als Entnahme, die Rücklage separat als change_float. Nur so
-- bleibt der Soll-Ist-Vergleich gegen die Barverkäufe aussagekräftig und
-- die GoBD-Vollständigkeit gewahrt.
--
-- Beide Zeilen entstehen in EINER Transaktion. Eine gebuchte Entnahme
-- ohne die zugehörige Rücklage sähe plausibel aus und würde den
-- Kassenstand still um die Rücklage überhöhen — genau der Zustand, den
-- die Buchungsart verhindern soll.
--
-- SECURITY INVOKER: die bestehenden RLS-Policies auf cash_book_entries
-- greifen unverändert. company_id kommt aus my_company_id(), created_by
-- aus auth.uid().
--
-- p_float_back wird als nicht-negativer Betrag übergeben und intern
-- negiert (Wirkung auf die Barkasse).
-- =========================================================

CREATE OR REPLACE FUNCTION public.record_cash_book_withdrawal(
  p_cash_book_id      uuid,
  p_machine_id        uuid,
  p_counted           float8,
  p_expected          float8,
  p_float_back        float8 DEFAULT 0,
  p_description       text   DEFAULT NULL,
  p_float_description text   DEFAULT NULL
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
BEGIN
  IF v_company IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- Barkasse muss der eigenen Firma gehören. Die INSERT-Policy prüft nur
  -- company_id — und das setzt diese Funktion selbst aus my_company_id().
  -- Ohne diese Prüfung ließe sich ein Eintrag in die hash-verkettete
  -- Historie einer fremden Firma einhängen: für deren Eigentümerin
  -- unsichtbar (ihr SELECT filtert auf company_id), aber Saldo und Kette
  -- dauerhaft verschoben, weil der BEFORE-INSERT-Trigger entry_number und
  -- balance_after aus genau dieser Kette ableitet.
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

  -- Vorabprüfung, bevor irgendetwas geschrieben wird. Ohne sie liefe der
  -- Fall in den generischen Trigger-Fehler, nachdem die Entnahme bereits
  -- geschrieben wurde — die Transaktion rollt zwar korrekt zurück, aber
  -- die Fehlermeldung wäre für die Oberfläche unbrauchbar.
  IF v_float_back <> 0 AND p_machine_id IS NULL THEN
    RAISE EXCEPTION 'change float requires a machine';
  END IF;

  -- Automat muss der eigenen Firma gehören. cash_book_entries hat keinen
  -- Constraint, der machine_id an company_id bindet — ohne diese Prüfung
  -- ließe sich eine Buchung auf einen fremden Automaten schreiben, die dann
  -- in der Bestandsabfrage stillschweigend verschwindet (die filtert seit
  -- 20260807000100 auf vm.company). Hier scheitert sie stattdessen laut.
  -- SECURITY INVOKER: RLS auf vendingMachine greift zusätzlich.
  IF p_machine_id IS NOT NULL THEN
    PERFORM 1 FROM public."vendingMachine"
     WHERE id = p_machine_id AND company = v_company;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'machine does not belong to this company';
    END IF;
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
       machine_id, created_by)
    VALUES
      (p_cash_book_id, v_company, 'change_float', -abs(v_float_back),
       p_float_description, p_machine_id, v_user)
    RETURNING id INTO v_float_id;
  END IF;

  RETURN jsonb_build_object(
    'withdrawal_entry_id',   v_withdrawal_id,
    'change_float_entry_id', v_float_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_cash_book_withdrawal(
  uuid, uuid, float8, float8, float8, text, text
) TO authenticated;
