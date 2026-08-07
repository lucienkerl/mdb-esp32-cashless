-- =========================================================
-- Kassenbuch: Entnahme und Wechselgeld-Rücklage verketten
--
-- record_cash_book_withdrawal schreibt beide Zeilen atomar, aber ohne
-- Bezug zueinander. Ein Storno der Entnahme ließ die Rücklage verwaist
-- zurück: Kassenstand um die Rücklage zu niedrig, und der Automat führte
-- dauerhaft Wechselgeld, das längst zurück war. Beide Clients boten
-- keinen Hinweis, dass ein zweites Storno nötig ist.
--
-- Eigene Spalte statt corrects_entry_id: die ist per CHECK
-- (reversal_requires_reference) ausschließlich für 'reversal' zulässig.
--
-- Der Hash bleibt unberührt — er umfasst nur entry_number, type, amount,
-- balance_after und den Vorgänger-Hash.
--
-- Rückwärtskompatibel: die Spalte ist nullable, Altzeilen bleiben NULL,
-- und alte Clients, die weiter direkt eine 'reversal'-Zeile inserten,
-- funktionieren unverändert — sie stornieren dann eben nur eine Seite,
-- genau wie bisher.
-- =========================================================

-- 1. Verkettungsspalte.
ALTER TABLE public.cash_book_entries
  ADD COLUMN IF NOT EXISTS paired_entry_id uuid REFERENCES public.cash_book_entries(id);

CREATE INDEX IF NOT EXISTS idx_cash_book_entries_paired
  ON public.cash_book_entries (paired_entry_id)
  WHERE paired_entry_id IS NOT NULL;

-- 2. record_cash_book_withdrawal setzt die Verkettung.
--    Basis ist die Fassung aus 20260807000200 inklusive aller Guards.
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

  RETURN jsonb_build_object(
    'withdrawal_entry_id',   v_withdrawal_id,
    'change_float_entry_id', v_float_id
  );
END;
$$;

-- 3. Storno, das die verkettete Gegenzeile mitnimmt.
--
--    Die eigentliche Storno-Mechanik (Betrag negieren, Original als
--    is_reversed markieren, Doppel-Storno verweigern) steckt weiterhin im
--    before_insert-Trigger — diese Funktion inserten nur die ein oder zwei
--    'reversal'-Zeilen, in einer Transaktion.
CREATE OR REPLACE FUNCTION public.reverse_cash_book_entry(
  p_entry_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, extensions
AS $$
DECLARE
  v_company    uuid := public.my_company_id();
  v_user       uuid := auth.uid();
  v_book       uuid;
  v_number     integer;
  v_partner    uuid;
  v_reversal   uuid;
  v_pair_rev   uuid;
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

  -- Die verkettete Gegenzeile, falls vorhanden und noch nicht storniert.
  SELECT id INTO v_partner
    FROM public.cash_book_entries
   WHERE paired_entry_id = p_entry_id
     AND company_id = v_company
     AND is_reversed = false;

  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, description,
     corrects_entry_id, created_by)
  VALUES
    (v_book, v_company, 'reversal', 0,
     format('Storno von Eintrag #%s', v_number), p_entry_id, v_user)
  RETURNING id INTO v_reversal;

  IF v_partner IS NOT NULL THEN
    INSERT INTO public.cash_book_entries
      (cash_book_id, company_id, type, amount, description,
       corrects_entry_id, created_by)
    VALUES
      (v_book, v_company, 'reversal', 0,
       format('Storno von Eintrag #%s',
              (SELECT entry_number FROM public.cash_book_entries WHERE id = v_partner)),
       v_partner, v_user)
    RETURNING id INTO v_pair_rev;
  END IF;

  RETURN jsonb_build_object(
    'reversal_entry_id',        v_reversal,
    'paired_reversal_entry_id', v_pair_rev
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.reverse_cash_book_entry(uuid) TO authenticated;
