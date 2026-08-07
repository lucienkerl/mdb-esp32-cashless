-- =========================================================
-- Kassenbuch: Wechselgeld in Automaten (change_float)
--
-- Neue Buchungsart für Bargeld, das der Betreiber aus der Barkasse
-- in die Münztuben eines Automaten einlegt oder von dort zurückholt.
--
-- amount = Wirkung auf die Barkasse:
--   Einlage in den Automaten → negativ (Kassenstand sinkt)
--   Rücknahme in die Kasse   → positiv (Kassenstand steigt)
-- Vorgestrecktes Wechselgeld je Automat = −SUM(amount).
--
-- Der Tubenfüllstand wird bewusst NICHT modelliert — er ist von außen
-- nicht ermittelbar. Modelliert wird ausschließlich, wie viel eigenes
-- Geld dem Automaten vorgestreckt wurde; das ändert sich nur durch
-- eigene Buchungen.
--
-- Idempotent. No-op auf Bestandsdaten: keine existierende Zeile hat
-- type = 'change_float'.
-- =========================================================

-- 1. Typ-Whitelist erweitern.
ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS valid_type;
ALTER TABLE public.cash_book_entries ADD CONSTRAINT valid_type
  CHECK (type IN ('initial','withdrawal','correction','payout','expense',
                  'change_float','reversal'));

-- 2. Nullbuchung sperren. Unempfindlich gegen ON DELETE SET NULL, weil
--    amount davon nicht berührt wird.
ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS change_float_nonzero;
ALTER TABLE public.cash_book_entries ADD CONSTRAINT change_float_nonzero
  CHECK (type <> 'change_float' OR amount <> 0);

-- 3. Partieller Index für die Bestandsabfrage.
CREATE INDEX IF NOT EXISTS idx_cash_book_entries_change_float
  ON public.cash_book_entries (company_id, machine_id)
  WHERE type = 'change_float' AND is_reversed = false;

-- 4. Automatenbezug erzwingen — im BEFORE-INSERT-Trigger, NICHT als CHECK.
--
--    machine_id hängt an REFERENCES vendingMachine(id) ON DELETE SET NULL
--    (20260407000000_cash_book.sql, Zeile 68). Ein CHECK
--    "type <> 'change_float' OR machine_id IS NOT NULL" würde bei jedem
--    UPDATE erneut ausgewertet — das Löschen eines Automaten löst über
--    ON DELETE SET NULL genau so ein UPDATE aus und würde am Constraint
--    scheitern. Ein BEFORE-INSERT-Trigger feuert dabei nicht.
--
--    Basis ist die aktuelle Fassung aus
--    20260522120000_fix_cash_book_digest_search_path.sql, inklusive
--    SET search_path = public, extensions — ohne das schlägt digest()
--    mit 42883 fehl.
--
--    Die Prüfung greift ausschließlich bei type = 'change_float'. Ein
--    Storno trägt type = 'reversal' und läuft daran vorbei; der Bestand
--    wird trotzdem korrekt zurückgenommen, weil die Bestandsabfrage über
--    is_reversed filtert.
CREATE OR REPLACE FUNCTION public.before_insert_cash_book_entry()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_prev_balance   float8;
  v_prev_hash      text;
  v_prev_number    integer;
  v_ref_amount     float8;
  v_ref_reversed   boolean;
  v_ref_book_id    uuid;
BEGIN
  -- Wechselgeldbuchungen brauchen zwingend einen Automatenbezug.
  IF NEW.type = 'change_float' AND NEW.machine_id IS NULL THEN
    RAISE EXCEPTION 'change_float requires machine_id';
  END IF;

  -- Lock the cash_book row to prevent concurrent inserts
  PERFORM id FROM public.cash_books WHERE id = NEW.cash_book_id FOR UPDATE;

  -- Get previous entry data
  SELECT entry_number, balance_after, hash
    INTO v_prev_number, v_prev_balance, v_prev_hash
    FROM public.cash_book_entries
   WHERE cash_book_id = NEW.cash_book_id
   ORDER BY entry_number DESC
   LIMIT 1;

  -- Calculate entry_number
  IF v_prev_number IS NULL THEN
    NEW.entry_number := 1;
    v_prev_balance := 0;
    v_prev_hash := '';
  ELSE
    NEW.entry_number := v_prev_number + 1;
  END IF;

  -- Handle reversal: validate + auto-set amount
  IF NEW.type = 'reversal' AND NEW.corrects_entry_id IS NOT NULL THEN
    SELECT amount, is_reversed, cash_book_id
      INTO v_ref_amount, v_ref_reversed, v_ref_book_id
      FROM public.cash_book_entries
     WHERE id = NEW.corrects_entry_id;

    IF v_ref_book_id IS NULL THEN
      RAISE EXCEPTION 'Referenced entry not found: %', NEW.corrects_entry_id;
    END IF;

    IF v_ref_book_id != NEW.cash_book_id THEN
      RAISE EXCEPTION 'Referenced entry belongs to a different cash book';
    END IF;

    IF v_ref_reversed THEN
      RAISE EXCEPTION 'Entry already reversed — cannot reverse twice (Doppel-Storno)';
    END IF;

    -- Auto-negate the referenced entry's amount
    NEW.amount := -v_ref_amount;

    -- Mark the original entry as reversed (SECURITY DEFINER bypasses RLS)
    UPDATE public.cash_book_entries
       SET is_reversed = true
     WHERE id = NEW.corrects_entry_id;
  END IF;

  -- Calculate balance_after
  NEW.balance_after := v_prev_balance + NEW.amount;

  -- Calculate SHA256 hash chain
  NEW.hash := encode(
    digest(
      NEW.entry_number::text || NEW.type || NEW.amount::text || NEW.balance_after::text || v_prev_hash,
      'sha256'
    ),
    'hex'
  );

  RETURN NEW;
END;
$$;
