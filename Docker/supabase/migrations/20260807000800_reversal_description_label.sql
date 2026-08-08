-- =========================================================
-- Kassenbuch: Storno-Beschreibung ist eine lokalisierte Bezeichnung,
-- kein voller Text
--
-- Letzter offener Befund aus der abschließenden Review der change-float-
-- Feature-Branch. 20260807000600 fügte reverse_cash_book_entry zwei
-- optionale Parameter hinzu (p_description / p_paired_description), damit
-- die Storno-Beschreibung nicht mehr hart auf Deutsch verdrahtet ist.
-- Kein Aufrufer übergibt sie jedoch — management-frontend/app/composables/
-- useCashBook.ts::reverseEntry() ruft die Funktion weiterhin nur mit
-- p_entry_id auf. Die Parameter sind damit toter Code: jeder nicht-
-- deutsche Betreiber liest 'Storno von Eintrag #N' dauerhaft in seiner
-- Belegliste und im PDF — der Befund, den 20260807000600 eigentlich
-- schließen sollte, blieb offen.
--
-- Zweites Problem in derselben Funktion: hat eine Entnahme mehrere
-- verkettete Rücklagenzeilen (Mehrfach-Automaten-Tour, 20260807000500),
-- wird ein einziges p_paired_description wortwörtlich auf ALLE
-- Gegenbuchungen angewendet. Jede Gegenbuchung verliert damit ihren
-- eigenen '#N'-Rückverweis auf genau die Zeile, die sie storniert.
--
-- Fix: p_description / p_paired_description bedeuten jetzt eine
-- lokalisierte BEZEICHNUNG, an die die Funktion selbst " #" plus die
-- entry_number DER JEWEILIGEN ZEILE anhängt — nie mehr die volle
-- Beschreibung wortwörtlich. Jede Gegenbuchung bekommt so wieder ihren
-- eigenen Rückverweis, auch bei mehreren Rücklagenzeilen. Ist eine
-- Bezeichnung NULL, fällt die Funktion auf 'Storno von Eintrag' zurück —
-- das ergibt byte-für-byte denselben Text wie bisher ('Storno von
-- Eintrag #N'), ein Aufrufer, der weiterhin nichts übergibt, sieht also
-- keine Änderung.
--
-- Signatur bleibt (uuid, text, text) — reines CREATE OR REPLACE, kein
-- DROP nötig, keine neue Überladung, Grants bleiben erhalten. Alle Guards
-- aus 20260807000600 bleiben unverändert erhalten: Ablehnung eines
-- Stornos einer bereits stornierten Zeile (type = 'reversal'), und die
-- Insert-Reihenfolge, die zuerst alle Rücklagen-Gegenbuchungen (immer
-- positiv, heben den Saldo) und erst danach die Entnahme-Gegenbuchung
-- selbst (negativ) schreibt, damit in der unveränderlichen Kette nie ein
-- negativer Zwischen-Kassenstand entsteht.
-- =========================================================

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

  -- unverändert aus 20260807000600: eine Gegenbuchung selbst darf nicht
  -- noch einmal storniert werden.
  IF v_type = 'reversal' THEN
    RAISE EXCEPTION 'cannot reverse a reversal';
  END IF;

  -- unverändert aus 20260807000600: erst die Gegenbuchungen aller
  -- verketteten, nicht-stornierten Rücklagenzeilen einfügen (immer
  -- positiv, heben den Saldo), danach erst die Gegenbuchung der Entnahme
  -- selbst (negativ) — verhindert einen negativen Zwischen-Kassenstand in
  -- der unveränderlichen Kette.
  --
  -- Neu: die Beschreibung jeder Gegenbuchung ist die Bezeichnung
  -- (p_paired_description, oder deutscher Standard) gefolgt von
  -- " #" + der entry_number DIESER Rücklagenzeile — nicht mehr ein
  -- einziges, für alle Zeilen identisches p_paired_description.
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
       format('%s #%s',
              COALESCE(p_paired_description, 'Storno von Eintrag'),
              v_partner.entry_number),
       v_partner.id, v_user)
    RETURNING id INTO v_partner_rev;

    v_pair_revs := array_append(v_pair_revs, v_partner_rev);
    IF v_pair_rev IS NULL THEN
      v_pair_rev := v_partner_rev;
    END IF;
  END LOOP;

  -- Neu: dieselbe Bezeichnung-plus-eigene-Nummer-Logik für die
  -- Gegenbuchung der Zielzeile selbst.
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, description,
     corrects_entry_id, created_by)
  VALUES
    (v_book, v_company, 'reversal', 0,
     format('%s #%s',
            COALESCE(p_description, 'Storno von Eintrag'),
            v_number),
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
