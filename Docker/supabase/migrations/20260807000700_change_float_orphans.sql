-- =========================================================
-- Kassenbuch: vorgestrecktes Wechselgeld eines gelöschten Automaten
--
-- get_machine_change_float (20260807000100) JOINt bislang per INNER JOIN
-- gegen vendingMachine. cash_book_entries.machine_id hängt aber an
-- REFERENCES vendingMachine(id) ON DELETE SET NULL (20260407000000) — wird
-- ein Automat gelöscht, der noch Wechselgeld vorgestreckt führt, setzt
-- Postgres dessen machine_id auf NULL, die Buchungszeile selbst bleibt
-- aber bestehen. Der INNER JOIN wirft diese Zeile danach komplett aus dem
-- Ergebnis: die Bestandskarte zeigt "nichts vorgestreckt", während der
-- PDF-Export (der ohne JOIN direkt über cash_book_entries summiert) den
-- Betrag weiterhin ausweist — Geld, das die Betreiberin über die
-- Oberfläche nicht mehr sieht.
--
-- Fix: LEFT JOIN, damit eine Zeile mit machine_id IS NULL erhalten bleibt
-- und als nicht zuordenbarer Sammelposten (machine_id null, machine_name
-- null) auftaucht. Mehrere gelöschte Automaten derselben Barkasse fallen
-- über GROUP BY e.machine_id, vm.name, e.cash_book_id ohnehin in eine
-- einzige Zeile.
--
-- Der Firmenschutz aus der Ursprungsfassung (vm.company = p_company_id)
-- bleibt inhaltlich erhalten, wandert aber von der reinen ON- zusätzlich in
-- eine WHERE-Bedingung: eine Zeile mit einer NICHT-NULL machine_id, die zu
-- keinem vm-Datensatz dieser Firma passt (fremder Automat, ob durch einen
-- Bug oder mit Absicht gesetzt), wird weiterhin vollständig ausgeschlossen
-- — nur eine echte NULL machine_id (= Automat gelöscht) kommt durch. Ohne
-- dieses zusätzliche Filterkriterium würde eine LEFT-JOIN-Zeile mit einer
-- fremden, aber weiterhin existierenden machine_id ebenfalls als "nicht
-- zuordenbar" auftauchen und dabei deren rohe UUID über 'machine_id' im
-- Ergebnis preisgeben — genau der Leak, den die ursprüngliche
-- vm.company-Prüfung verhindern sollte.
-- =========================================================

CREATE OR REPLACE FUNCTION public.get_machine_change_float(
  p_company_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_user_company uuid;
  v_rows         jsonb;
BEGIN
  -- Aufrufer muss Mitglied der Firma sein
  SELECT om.company_id INTO v_user_company
    FROM public.organization_members om
   WHERE om.user_id = auth.uid()
     AND om.company_id = p_company_id
   LIMIT 1;

  IF v_user_company IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(s.row_json ORDER BY s.machine_name NULLS LAST), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT vm.name AS machine_name,
           jsonb_build_object(
             'machine_id',     e.machine_id,
             'machine_name',   vm.name,
             'cash_book_id',   e.cash_book_id,
             'float_balance',  ROUND((-SUM(e.amount))::numeric, 2),
             'last_change_at', MAX(e.created_at)
           ) AS row_json
      -- LEFT JOIN statt INNER JOIN: eine Zeile mit machine_id IS NULL
      -- (Automat gelöscht) hat keinen vm-Treffer und soll trotzdem
      -- erscheinen, statt lautlos zu verschwinden.
      FROM public.cash_book_entries e
      LEFT JOIN public."vendingMachine" vm ON vm.id = e.machine_id
                                           AND vm.company = p_company_id
     WHERE e.company_id  = p_company_id
       AND e.type        = 'change_float'
       AND e.is_reversed = false
       -- Nur eine echte NULL machine_id darf ohne vm-Treffer durchkommen.
       -- Eine gesetzte, aber nicht matchende machine_id (Automat einer
       -- fremden Firma) wird weiterhin ausgeschlossen — sonst gäbe diese
       -- Zeile die fremde UUID über 'machine_id' preis.
       AND (e.machine_id IS NULL OR vm.id IS NOT NULL)
     GROUP BY e.machine_id, vm.name, e.cash_book_id
    HAVING ROUND((-SUM(e.amount))::numeric, 2) <> 0
  ) s;

  RETURN v_rows;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_machine_change_float(uuid) TO authenticated;
