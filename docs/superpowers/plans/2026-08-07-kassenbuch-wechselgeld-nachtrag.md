# Kassenbuch Wechselgeld — Nachtrag (Tasks 14–18)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Die vier Punkte schließen, die der Abschluss-Review des Hauptplans als offene Produktentscheidungen zurückgelassen hat und die der Nutzer alle bestätigt hat.

**Vorbedingung:** Der Hauptplan `2026-08-07-kassenbuch-wechselgeld.md` ist vollständig umgesetzt und abgenommen (Commits `95caa95..59bcb9d`).

## Global Constraints

Es gelten sämtliche Constraints des Hauptplans unverändert. Ergänzend:

- **Die drei Migrationen des Hauptplans (`20260807000000`, `…000100`, `…000200`) sind jetzt tabu.** Sie sind angewendet; jede Änderung an ihnen wäre die Divergenz, vor der CLAUDE.md warnt. Alle Änderungen kommen in neue Dateien.
- **Rückwärtskompatibilität ist hier besonders scharf:** alte iOS-Builds im Feld buchen über den direkten Insert und stornieren über einen direkten `reversal`-Insert. Beides muss weiter funktionieren. Neue RPC-Parameter brauchen Defaults; neue Spalten sind nullable.
- Der Hash über `entry_number || type || amount || balance_after || prev_hash` darf sich nicht ändern — neue Spalten fließen nicht ein.

---

### Task 14: RLS-Policy — Barkasse muss zur Firma gehören

Der Abschluss-Review: die INSERT-Policy auf `cash_book_entries` prüft nur `company_id`, nicht ob `cash_book_id` derselben Firma gehört. Eine eingeschleuste Zeile verbraucht eine `entry_number` in der fremden Kette und lässt deren clientseitige Integritätsprüfung **dauerhaft** eine gebrochene Kette melden — eine Integritätsverweigerung auf einem GoBD-Buch.

**Files:**
- Create: `Docker/supabase/tests/cash_book_insert_policy.test.sql`
- Create: `Docker/supabase/migrations/20260807000300_cash_book_entries_insert_policy.sql`

**Interfaces:**
- Consumes: nichts
- Produces: verschärfte Policy `cash_book_entries_insert`; ein Insert mit fremder `cash_book_id` schlägt mit einem RLS-Fehler fehl

- [ ] **Step 1: Test schreiben**

Der Testrunner verbindet als `postgres`, und diese Rolle hat `rolbypassrls = true` — RLS greift dort **nicht**. Der Test muss die Rolle deshalb explizit wechseln.

Create `Docker/supabase/tests/cash_book_insert_policy.test.sql`:

```sql
-- Die INSERT-Policy auf cash_book_entries muss verhindern, dass in die
-- Barkasse einer fremden Firma gebucht wird. Ohne das verbraucht eine
-- eingeschleuste Zeile eine entry_number in deren Hash-Kette; die
-- Eigentümerin sieht die Zeile nie (ihr SELECT filtert auf company_id),
-- bekommt aber ab da dauerhaft eine gebrochene Kette gemeldet.
--
-- WICHTIG: der Testrunner verbindet als `postgres` mit rolbypassrls = true.
-- RLS greift für diese Rolle nicht, deshalb wird für die Policy-Prüfung
-- explizit auf `authenticated` gewechselt.

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
END $$;

-- Ab hier als authentifizierter Nutzer, damit RLS überhaupt greift.
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_company uuid;
  v_user    uuid;
  v_book    uuid;
  v_other_book uuid;
  v_err     text;
  n_before  int;
  n_after   int;
BEGIN
  SELECT id INTO v_company FROM public.companies WHERE name = 'PolicyCo';
  SELECT user_id INTO v_user FROM public.organization_members WHERE company_id = v_company;
  SELECT id INTO v_book FROM public.cash_books WHERE company_id = v_company;
  SELECT id INTO v_other_book FROM public.cash_books WHERE name = 'Fremde';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 1: eigene Barkasse geht durch ══════════════════════════════════
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, description, created_by)
    VALUES (v_book, v_company, 'correction', 5, 'ok', v_user);
  RAISE NOTICE 'Test 1 bestanden: eigene Barkasse buchbar';

  -- ═══ Test 2: fremde Barkasse wird abgewiesen ═════════════════════════════
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
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

```bash
Docker/supabase/tests/run-sql-tests.sh
```

Expected: `cash_book_insert_policy.test.sql` schlägt in Test 2 fehl — der Insert geht heute durch, `v_err` bleibt leer.

- [ ] **Step 3: Migration schreiben**

Create `Docker/supabase/migrations/20260807000300_cash_book_entries_insert_policy.sql`:

```sql
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
```

- [ ] **Step 4: Anwenden und Test grün sehen**

```bash
cd Docker/supabase && supabase migration up && ./tests/run-sql-tests.sh
```

Expected: alle Testdateien grün. Besonders `cash_book_change_float_rpc.test.sql` — dessen Tests schreiben als `postgres` (RLS umgangen), dürfen also unberührt bleiben.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/migrations/20260807000300_cash_book_entries_insert_policy.sql Docker/supabase/tests/cash_book_insert_policy.test.sql
git commit -m "fix(db): bind the cash book entry insert policy to the book's company" -- Docker/supabase/migrations/20260807000300_cash_book_entries_insert_policy.sql Docker/supabase/tests/cash_book_insert_policy.test.sql
```

---

### Task 15: Storno-Verkettung — Datenschicht

Entnahme und Wechselgeld-Rücklage entstehen atomar, sind aber nicht verknüpft. Ein Storno der Entnahme lässt die Rücklage verwaist zurück: Kasse zu niedrig, Automat zeigt dauerhaft Wechselgeld vorgestreckt, das längst zurück ist.

**Entwurfsentscheidung:** eine nullable Spalte `paired_entry_id` auf der `change_float`-Zeile, die auf ihre Entnahme zeigt. Nicht `corrects_entry_id` mitbenutzen — das ist per CHECK ausschließlich für `reversal` reserviert. Das Stornieren erledigt eine neue RPC, die beide Gegenbuchungen in einer Transaktion schreibt.

**Files:**
- Create: `Docker/supabase/tests/cash_book_paired_reversal.test.sql`
- Create: `Docker/supabase/migrations/20260807000400_cash_book_paired_reversal.sql`

**Interfaces:**
- Consumes: `record_cash_book_withdrawal` (Hauptplan Task 3)
- Produces:
  - Spalte `public.cash_book_entries.paired_entry_id uuid NULL REFERENCES public.cash_book_entries(id)`
  - `record_cash_book_withdrawal` setzt sie auf der Float-Zeile (Signatur unverändert)
  - `public.reverse_cash_book_entry(p_entry_id uuid) RETURNS jsonb` mit den Schlüsseln `reversal_entry_id` (uuid) und `paired_reversal_entry_id` (uuid|null)

- [ ] **Step 1: Test schreiben**

Create `Docker/supabase/tests/cash_book_paired_reversal.test.sql`:

```sql
-- Storno einer Entnahme muss ihre Wechselgeld-Rücklage mitstornieren.
-- Ohne das bliebe die Rücklage verwaist: Kassenstand zu niedrig, und der
-- Automat führte dauerhaft Wechselgeld, das längst zurückgeholt wurde.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company uuid := gen_random_uuid();
  v_user    uuid := gen_random_uuid();
  v_book    uuid := gen_random_uuid();
  v_machine uuid := gen_random_uuid();
  r jsonb; res jsonb;
  v_withdrawal uuid; v_float uuid;
  v_balance float8; v_float_bal float8; n int; v_err text;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'PairCo');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'pair@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'pair@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book, v_company, 'PairKasse', 0, v_user);
  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine, 'A', v_company, v_book);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- Entnahme 200 mit Rücklage 50 → Saldo 150, Float 50
  r := public.record_cash_book_withdrawal(v_book, v_machine, 200.00, 180.00, 50.00,
                                          'Entnahme', 'Wechselgeld');
  v_withdrawal := (r->>'withdrawal_entry_id')::uuid;
  v_float      := (r->>'change_float_entry_id')::uuid;

  -- ═══ Test 1: die Float-Zeile zeigt auf ihre Entnahme ═════════════════════
  ASSERT (SELECT paired_entry_id FROM public.cash_book_entries WHERE id = v_float) = v_withdrawal,
    'die Wechselgeldzeile muss auf ihre Entnahme zeigen';
  RAISE NOTICE 'Test 1 bestanden: Verkettung gesetzt';

  -- ═══ Test 2: Storno der Entnahme storniert beide ═════════════════════════
  res := public.reverse_cash_book_entry(v_withdrawal);
  ASSERT res->>'reversal_entry_id' IS NOT NULL, 'Gegenbuchung zur Entnahme fehlt';
  ASSERT res->>'paired_reversal_entry_id' IS NOT NULL, 'Gegenbuchung zur Rücklage fehlt';

  ASSERT (SELECT is_reversed FROM public.cash_book_entries WHERE id = v_withdrawal),
    'Entnahme muss als storniert markiert sein';
  ASSERT (SELECT is_reversed FROM public.cash_book_entries WHERE id = v_float),
    'Rücklage muss als storniert markiert sein';
  RAISE NOTICE 'Test 2 bestanden: beide storniert';

  -- ═══ Test 3: Saldo und Float sind wieder auf null ════════════════════════
  SELECT balance_after INTO v_balance FROM public.cash_book_entries
   WHERE cash_book_id = v_book ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 0, format('Kassenstand nach Storno erwartet 0, war %s', v_balance);

  SELECT COALESCE(-SUM(amount), 0) INTO v_float_bal FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float' AND is_reversed = false;
  ASSERT v_float_bal = 0, format('Float nach Storno erwartet 0, war %s', v_float_bal);
  RAISE NOTICE 'Test 3 bestanden: Saldo und Float zurückgesetzt';

  -- ═══ Test 4: Doppel-Storno wird abgewiesen, ohne Teilbuchung ═════════════
  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book;
  v_err := '';
  BEGIN
    PERFORM public.reverse_cash_book_entry(v_withdrawal);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err <> '', 'ein zweites Storno derselben Zeile muss scheitern';
  ASSERT (SELECT count(*) FROM public.cash_book_entries WHERE cash_book_id = v_book) = n,
    'ein abgewiesenes Storno darf keine Zeile hinterlassen';
  RAISE NOTICE 'Test 4 bestanden: Doppel-Storno abgewiesen';

  -- ═══ Test 5: Storno einer Entnahme OHNE Rücklage bleibt einfach ══════════
  r := public.record_cash_book_withdrawal(v_book, v_machine, 30.00, 30.00, 0,
                                          'Entnahme ohne Rücklage', NULL);
  res := public.reverse_cash_book_entry((r->>'withdrawal_entry_id')::uuid);
  ASSERT res->>'paired_reversal_entry_id' IS NULL,
    'ohne Rücklage darf keine zweite Gegenbuchung entstehen';
  RAISE NOTICE 'Test 5 bestanden: einfache Entnahme unverändert';

  -- ═══ Test 6: fremde Zeile wird abgewiesen ════════════════════════════════
  v_err := '';
  BEGIN
    PERFORM public.reverse_cash_book_entry(gen_random_uuid());
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err <> '', 'eine unbekannte Zeile muss abgewiesen werden';
  RAISE NOTICE 'Test 6 bestanden: unbekannte Zeile abgewiesen';

END $$;

ROLLBACK;
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

```bash
Docker/supabase/tests/run-sql-tests.sh
```

Expected: FAIL, `column "paired_entry_id" does not exist`.

- [ ] **Step 3: Migration schreiben**

Create `Docker/supabase/migrations/20260807000400_cash_book_paired_reversal.sql`:

```sql
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
```

- [ ] **Step 4: Anwenden und Tests grün sehen**

```bash
cd Docker/supabase && supabase migration up && ./tests/run-sql-tests.sh
```

Expected: alle Dateien grün, sechs `bestanden`-NOTICEs in der neuen.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/migrations/20260807000400_cash_book_paired_reversal.sql Docker/supabase/tests/cash_book_paired_reversal.test.sql
git commit -m "feat(db): reverse a withdrawal together with its paired change float" -- Docker/supabase/migrations/20260807000400_cash_book_paired_reversal.sql Docker/supabase/tests/cash_book_paired_reversal.test.sql
```

---

### Task 16: Storno-Verkettung — beide Clients

Beide Clients stornieren heute per direktem Insert einer `reversal`-Zeile. Sie müssen auf `reverse_cash_book_entry` umstellen, sonst greift die Verkettung nie.

**Files:**
- Modify: `management-frontend/app/composables/useCashBook.ts`
- Modify: `management-frontend/app/pages/cash-book/index.vue`
- Modify: `management-frontend/app/components/cash-book/ReversalModal.vue`
- Modify: `management-frontend/i18n/locales/{de,en,fr,nl}.json`
- Modify: `ios/VMflow/ViewModels/CashBookViewModel.swift` (falls dort ein Storno-Pfad existiert — prüfen, nicht annehmen)

**Interfaces:**
- Consumes: `reverse_cash_book_entry(p_entry_id)` (Task 15)
- Produces: `useCashBook().reverseEntry(entryId: string): Promise<{ reversal_entry_id: string; paired_reversal_entry_id: string | null }>`

- [ ] **Step 1: Composable umstellen**

In `useCashBook.ts` eine Funktion neben `recordWithdrawal` ergänzen:

```ts
  /** Storniert einen Eintrag. Hat er eine verkettete Gegenzeile — eine
   *  Wechselgeld-Rücklage zu einer Entnahme —, wird sie in derselben
   *  Transaktion mitstorniert. Ohne das bliebe sie verwaist zurück und der
   *  Automat führte dauerhaft Wechselgeld, das längst zurück ist. */
  async function reverseEntry(entryId: string) {
    const { data, error } = await (supabase as any)
      .rpc('reverse_cash_book_entry', { p_entry_id: entryId })

    if (error) throw error

    const result = data as { reversal_entry_id: string; paired_reversal_entry_id: string | null }

    await logActivity('cash_book_entry_created', result.reversal_entry_id, {
      cash_book_id: selectedCashBook.value?.id,
      type: 'reversal',
      amount: 0,
      description: null,
      category: null,
    })
    if (result.paired_reversal_entry_id) {
      await logActivity('cash_book_entry_created', result.paired_reversal_entry_id, {
        cash_book_id: selectedCashBook.value?.id,
        type: 'reversal',
        amount: 0,
        description: null,
        category: null,
      })
    }

    if (selectedCashBook.value) {
      await fetchEntries(selectedCashBook.value.id)
      await fetchTheoreticalCash(selectedCashBook.value.id)
      await fetchChangeFloat()
    }

    return result
  }
```

`reverseEntry` im Rückgabeobjekt ergänzen.

- [ ] **Step 2: Seite umstellen**

In `index.vue` `submitReversal` so ändern, dass es `reverseEntry(reversalTarget.value.id)` aufruft statt `createEntry` mit `type: 'reversal'`. Fehlerbehandlung und das Schließen des Dialogs bleiben unverändert.

- [ ] **Step 3: Hinweis im Storno-Dialog**

`ReversalModal.vue` muss dem Nutzer sagen, dass zwei Buchungen storniert werden, wenn die Zeile eine verkettete Gegenzeile hat. Die Information liegt im Eintrag: ein `withdrawal`, zu dem in `entries` eine nicht-stornierte `change_float`-Zeile mit `paired_entry_id === entry.id` existiert.

Ergänze im Modal eine Prop `entries: CashBookEntry[]`, ein Computed, das diese Gegenzeile sucht, und einen Hinweistext, wenn sie existiert. Neuer i18n-Schlüssel `cashBook.reversalIncludesPaired` in allen vier Sprachdateien, deutscher Wert: „Die zugehörige Wechselgeldbuchung wird mitstorniert."

Ergänze `paired_entry_id: string | null` im `CashBookEntry`-Interface in `useCashBook.ts`.

- [ ] **Step 4: iOS prüfen und ggf. umstellen**

```bash
grep -rn "reversal" ios/VMflow/ --include="*.swift"
```

Existiert ein Storno-Pfad, auf die RPC umstellen — Muster wie `recordWithdrawal`. Existiert keiner (Storno nur im Web), im Bericht festhalten und nichts ändern.

- [ ] **Step 5: Verifizieren und committen**

```bash
cd management-frontend && npx vitest run
```

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

```bash
git commit -m "feat: reverse a withdrawal together with its change float in both clients" -- <geänderte Pfade>
```

---

### Task 17: Rücklage je Automat auf einer Tour

Auf einer Tour bucht das Entnahme-Sheet eine Entnahme über alle besuchten Automaten der Barkasse. Für die Rücklage muss der Bediener heute genau einen Automaten wählen — der gesamte Betrag landet dort. Der Automatenbezug, der der ganze Zweck des Features ist, wird damit still falsch.

**Files:**
- Create: `Docker/supabase/tests/cash_book_multi_float.test.sql`
- Create: `Docker/supabase/migrations/20260807000500_cash_book_multi_float.sql`
- Modify: `ios/VMflow/Views/CashBook/WithdrawalSheet.swift`
- Modify: `ios/VMflow/ViewModels/CashBookViewModel.swift`
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `record_cash_book_withdrawal` (Task 15)
- Produces: neuer Parameter `p_floats jsonb DEFAULT NULL` — Array aus `{"machine_id": uuid, "amount": number}`; der Rückgabeschlüssel `change_float_entry_ids` (uuid-Array) tritt neben das bestehende `change_float_entry_id`

**Vorgaben, die der Umsetzende einhalten muss:**

- `p_float_back` und `p_floats` schließen einander aus — sind beide gesetzt, `RAISE EXCEPTION`. Das hält den bestehenden Einzelfall unverändert.
- Jeder Eintrag in `p_floats` durchläuft dieselben Prüfungen wie der Einzelfall: Betrag ≥ 0, Automat gehört zur Firma, Betrag ≠ 0 wird gebucht, Betrag = 0 wird übersprungen.
- Jede erzeugte `change_float`-Zeile bekommt `paired_entry_id` der Entnahme, damit Task 15s Storno auch hier greift. **`reverse_cash_book_entry` muss dafür mehrere Gegenzeilen verkraften** — die Fassung aus Task 15 sucht nur eine. Passe sie in derselben neuen Migration per `CREATE OR REPLACE` an, sodass sie über alle verketteten, nicht-stornierten Zeilen schleift, und erweitere `paired_reversal_entry_id` zu einem Array `paired_reversal_entry_ids`. Ältere Clients lesen den alten Schlüssel — behalte ihn zusätzlich, gefüllt mit der ersten ID oder NULL.
- `record_cash_book_withdrawal` behält die alte Signatur als aufrufbare Variante; der neue Parameter kommt ans Ende mit Default `NULL`.
- Der Test muss abdecken: mehrere Automaten mit Beträgen, ein Nullbetrag dazwischen, beide Parameter gleichzeitig gesetzt (Ablehnung), ein fremder Automat in der Liste (Ablehnung, keine Teilbuchung), und ein Storno, das alle erzeugten Zeilen mitnimmt.

**iOS-Vorgaben:**

- Im Entnahme-Sheet greift die Mehrfach-Erfassung, wenn `tourMachineIds` mehr als einen Automaten enthält. Dann statt eines einzelnen Rücklage-Felds eine Zeile je besuchtem Automaten, jede mit `.decimalPad`, jede mit derselben Trimm- und Komma-Behandlung wie das bestehende Feld (`trimmingCharacters(in: .whitespaces)`, `,` → `.`, `max(0, …)`).
- Die Netto-Vorschau summiert alle Beträge.
- Bei genau einem besuchten Automaten und bei manueller Entnahme bleibt alles wie bisher.
- `recordWithdrawal` im ViewModel bekommt einen zusätzlichen Parameter `floats: [UUID: Double] = [:]`, der als `p_floats` serialisiert wird; die bestehenden Aufrufe müssen unverändert kompilieren.
- Neue String-Catalog-Schlüssel brauchen **de, en, fr und nl** — `sourceLanguage` ist `en`, ein fehlender englischer Eintrag zeigt den rohen Schlüsselnamen. Wortlaut mit `management-frontend/i18n/locales/*.json` abgleichen, wo es eine Entsprechung gibt.

- [ ] **Step 1: SQL-Test schreiben, laufen lassen, Fehlschlag bestätigen**
- [ ] **Step 2: Migration schreiben, anwenden, Tests grün sehen, committen**
- [ ] **Step 3: iOS umstellen, bauen, committen**

---

### Task 18: Zwei Bedienungslücken schließen

**Files:**
- Modify: `management-frontend/app/components/cash-book/{WithdrawalModal,ChangeFloatModal}.vue`
- Modify: `ios/VMflow/Views/CashBook/{WithdrawalSheet,ChangeFloatSheet}.swift`
- Modify: die Stelle, an der ein Automat gelöscht wird (suchen, nicht annehmen)
- Modify: `management-frontend/i18n/locales/{de,en,fr,nl}.json`, `ios/VMflow/Resources/Localizable.xcstrings`

**a) Leerer Automatenbestand.** Hat die Barkasse keine zugeordneten Automaten, ist in vier Dialogen der Absenden-Knopf dauerhaft deaktiviert, ohne dass irgendwo steht warum. Zeige in allen vier eine kurze Erklärung, sobald `assignedMachines` leer ist und ein Automat gebraucht würde. Ein gemeinsamer i18n-Schlüssel, deutscher Wert: „Dieser Barkasse ist kein Automat zugeordnet. Ordne zuerst einen zu."

**b) Automat mit offenem Wechselgeld löschen.** Der Eintrag bleibt erhalten, aber `machine_id` wird auf NULL gesetzt und der Betrag verschwindet aus der Bestandsübersicht — Geld, von dem der Betreiber dann nicht mehr sieht, dass es ihm zusteht. Finde die Löschstelle, prüfe vorher `get_machine_change_float` bzw. den bereits geladenen Bestand, und warne mit Betrag, bevor gelöscht wird. Nicht blockierend. Deutscher Wert: „Diesem Automaten sind noch {amount} Wechselgeld vorgestreckt. Nach dem Löschen ist der Betrag nicht mehr zuzuordnen."

- [ ] **Step 1: Löschstelle finden und Bestand dort verfügbar machen**
- [ ] **Step 2: Beide Meldungen in PWA und iOS ergänzen, alle Sprachen**
- [ ] **Step 3: Tests, Build, Commit**

---

## Abschluss

```bash
Docker/supabase/tests/run-sql-tests.sh
cd management-frontend && npx vitest run
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Danach ein erneuter Gesamt-Review über `95caa95..HEAD`.
