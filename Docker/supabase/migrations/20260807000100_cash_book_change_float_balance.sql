-- =========================================================
-- Kassenbuch: Bestandsabfrage für vorgestrecktes Wechselgeld
--
-- Liefert je (Automat, Barkasse) den Saldo der nicht-stornierten
-- change_float-Buchungen. Kein gespeicherter Wert — der Bestand ist
-- immer aus der Buchungshistorie abgeleitet und kann daher nicht von
-- ihr abweichen.
--
-- Wechselt ein Automat die Barkasse, entstehen zwei Zeilen. Das ist
-- gewollt: der Float gehört buchhalterisch zu einer bestimmten Barkasse.
-- Die Oberfläche summiert für eine automatenbezogene Anzeige.
--
-- is_reversed = false ist zwingend: die Storno-Gegenbuchung trägt
-- type = 'reversal' und hat keine machine_id, würde den Bestand also
-- nicht zurücknehmen. Der Filter auf die als storniert markierte
-- Originalzeile erledigt das.
--
-- ROUND nur mit ::numeric-Cast — amount ist float8, und
-- ROUND(double precision, integer) existiert in Postgres nicht.
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
      FROM public.cash_book_entries e
      JOIN public."vendingMachine" vm ON vm.id = e.machine_id
     WHERE e.company_id  = p_company_id
       AND e.type        = 'change_float'
       AND e.is_reversed = false
     GROUP BY e.machine_id, vm.name, e.cash_book_id
    HAVING ROUND((-SUM(e.amount))::numeric, 2) <> 0
  ) s;

  RETURN v_rows;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_machine_change_float(uuid) TO authenticated;
