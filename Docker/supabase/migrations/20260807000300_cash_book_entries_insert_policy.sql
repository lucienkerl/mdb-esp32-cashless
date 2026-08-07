-- =========================================================
-- Kassenbuch: INSERT-Policy an die Barkassen-Firma binden
--
-- Die Policy aus 20260407000000 prüft nur company_id — und das setzt
-- der schreibende Client selbst. cash_book_entries hat keinen
-- Constraint, der cash_book_id an company_id bindet, also ließ sich
-- eine Zeile in die Barkasse einer fremden Firma schreiben.
--
-- Folge: die Zeile ist für die Eigentümerin unsichtbar (ihr SELECT
-- filtert auf company_id), verbraucht aber eine entry_number in ihrer
-- Hash-Kette und verschiebt jedes folgende balance_after. Ihre
-- clientseitige Integritätsprüfung rekonstruiert die Kette nur aus den
-- sichtbaren Zeilen und meldet ab da dauerhaft einen Bruch.
--
-- record_cash_book_withdrawal (20260807000200) prüft das bereits selbst;
-- diese Policy schließt den direkten Insert-Pfad, den PWA und iOS für
-- alle übrigen Buchungsarten weiter nutzen.
--
-- Rückwärtskompatibel: bestehende Clients buchen ohnehin nur in
-- Barkassen der eigenen Firma, also ändert sich für sie nichts.
-- =========================================================

DROP POLICY IF EXISTS "cash_book_entries_insert" ON public.cash_book_entries;

CREATE POLICY "cash_book_entries_insert" ON public.cash_book_entries
  FOR INSERT TO authenticated
  WITH CHECK (
    company_id = public.my_company_id()
    AND EXISTS (
      SELECT 1 FROM public.cash_books cb
       WHERE cb.id = cash_book_entries.cash_book_id
         AND cb.company_id = public.my_company_id()
    )
  );
