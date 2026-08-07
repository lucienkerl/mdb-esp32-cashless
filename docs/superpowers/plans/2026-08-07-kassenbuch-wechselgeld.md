# Kassenbuch Wechselgeld (`change_float`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eine eigene Kassenbuch-Buchungsart `change_float`, mit der Bargeld aus der Barkasse in die Münztuben eines Automaten gebucht wird, samt exaktem Bestand „vorgestrecktes Wechselgeld je Automat" auf PWA und iOS.

**Architecture:** Keine neue Tabelle. Der Bestand ist `−SUM(amount)` über nicht-stornierte `change_float`-Zeilen. Der Automatenbezug wird im BEFORE-INSERT-Trigger erzwungen (nicht als CHECK, weil `machine_id` an `ON DELETE SET NULL` hängt). Die verkettete Buchung „Entnahme + Tubenrücklage" läuft über eine neue RPC, damit sie nicht halb passieren kann.

**Tech Stack:** PostgreSQL 15.8 (Supabase self-hosted), Nuxt 4 + TypeScript + Vitest, SwiftUI (iOS), plain-ASSERT SQL-Testharness.

**Spec:** `docs/superpowers/specs/2026-08-07-kassenbuch-wechselgeld-design.md`

## Global Constraints

- **Migrationen sind immutable.** Nie eine bestehende Migrationsdatei editieren. Dieser Plan legt **drei** neue Dateien mit aufsteigenden Zeitstempeln an, weil zwischen den Tasks jeweils `supabase migration up` läuft — eine später editierte Datei würde auf der lokalen DB nicht erneut angewendet.
- **Niemals `supabase db reset`.** Die Dev-DB enthält produktionsnahe Testdaten. Nur `supabase migration up`.
- **Vorzeichenkonvention:** `amount` ist die Wirkung auf die Barkasse. Einlage in den Automaten → **negativ**. Rücknahme → **positiv**. Float je Automat = `−SUM(amount)`.
- **Buchungstyp-Code:** exakt `change_float` (nicht `float`).
- **`ROUND` auf `amount` immer mit `::numeric`-Cast.** `amount` ist `float8`; `ROUND(double precision, integer)` existiert in Postgres nicht.
- **`SECURITY DEFINER`-Funktionen brauchen `SET search_path = public, extensions`**, sonst schlägt `digest()` mit 42883 fehl.
- **Rückwärtskompatibilität:** `get_theoretical_cash` wird nicht angefasst. Der direkte Insert-Pfad auf `cash_book_entries` bleibt funktionsfähig (alte iOS-Builds im Feld nutzen ihn weiter).
- **i18n:** alle vier Sprachdateien pflegen — `de.json`, `en.json`, `fr.json`, `nl.json`.
- **iOS:** neue `.swift`-Dateien brauchen vier Hand-Edits in `ios/VMflow.xcodeproj/project.pbxproj` (PBXBuildFile, PBXFileReference, group children, Sources phase), sonst werden sie nicht kompiliert. Kein xcodegen-Regen.
- **iOS String Catalog:** `Localizable.xcstrings` chirurgisch editieren, nie mit Python neu serialisieren. Nur `de`-Einträge, du-Ton.
- **Commit-Disziplin:** parallele Sessions committen auf denselben Branch. Immer `git add <pfad> && git commit -m … -- <pfad>`, nie `amend`/`reset`/`rebase` auf fremde Commits.

## Abweichung von der Spec (bewusst)

Die Spec nennt die Wechselgeld-Karte „dritte Station". Der Flow hat bereits drei Stationen (In Automaten → In der Kasse → Letzte Bankeinzahlung). Eine vierte Spalte in dieser Kette würde suggerieren, das Wechselgeld liege *hinter* der Bankeinzahlung. Der Float ist aber eine Seitentasche der Kasse, kein Kettenglied. Er wird deshalb als **eigenständige Karte unterhalb der Kette** gerendert (Task 7).

## File Structure

| Datei | Verantwortung |
|---|---|
| `Docker/supabase/migrations/20260807000000_cash_book_change_float.sql` | Typ-Whitelist, Nullbuchungs-CHECK, Trigger-Guard |
| `Docker/supabase/migrations/20260807000100_cash_book_change_float_balance.sql` | RPC `get_machine_change_float` |
| `Docker/supabase/migrations/20260807000200_cash_book_withdrawal_rpc.sql` | RPC `record_cash_book_withdrawal` |
| `Docker/supabase/tests/cash_book_change_float.test.sql` | Schema-, Trigger-, Storno-, Lösch- und Regressionstests |
| `Docker/supabase/tests/cash_book_change_float_rpc.test.sql` | Tests für beide RPCs |
| `management-frontend/app/composables/useCashBook.ts` | Typen, reine Vorzeichen-/Aggregations-Helfer, Datenzugriff |
| `management-frontend/app/composables/__tests__/useCashBook.test.ts` | Unit-Tests der reinen Helfer |
| `management-frontend/app/components/cash-book/ChangeFloatModal.vue` | Dialog Einlage/Rücknahme |
| `management-frontend/app/components/cash-book/StationChangeFloat.vue` | Bestandskarte |
| `ios/VMflow/Views/CashBook/ChangeFloatSheet.swift` | iOS-Dialog |
| `ios/VMflow/ViewModels/CashBookViewModel.swift` | RPC-Aufrufe, Float-Bestand, Aktivitätsprotokoll |
| `ios/VMflow/Views/CashBook/WithdrawalSheet.swift` | Rücklage-Feld, entkoppelter Automaten-Picker |

---

### Task 1: DB-Schema und Trigger-Guard

**Files:**
- Create: `Docker/supabase/tests/cash_book_change_float.test.sql`
- Create: `Docker/supabase/migrations/20260807000000_cash_book_change_float.sql`

**Interfaces:**
- Consumes: nichts
- Produces: Buchungstyp `change_float` auf `public.cash_book_entries`; `machine_id` ist für diesen Typ beim INSERT Pflicht (Exception-Text `change_float requires machine_id`); `amount <> 0` erzwungen durch CHECK `change_float_nonzero`

- [ ] **Step 1: Testdatei schreiben**

Create `Docker/supabase/tests/cash_book_change_float.test.sql`:

```sql
-- Schema-, Trigger-, Storno- und Regressionstests für die Buchungsart
-- change_float (Migration 20260807000000_cash_book_change_float.sql).
--
-- Läuft in einer Transaktion, die am Ende zurückgerollt wird → keine Dev-Daten
-- werden angefasst. Plain ASSERT in einem DO-Block, kein pgTAP.
-- Fake-JWT via set_config('request.jwt.claims', ..., true), damit die
-- SECURITY-DEFINER-Prüfung von get_theoretical_cash greift.
--
-- Voraussetzung: `supabase start` + `supabase migration up`.
-- Ausführung über Docker/supabase/tests/run-sql-tests.sh.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_book      uuid := gen_random_uuid();
  v_machine   uuid := gen_random_uuid();
  v_product   uuid := gen_random_uuid();
  v_float_id  uuid;
  v_raised    boolean;
  v_balance   float8;
  v_before    jsonb;
  v_after     jsonb;
  v_machine_id_after uuid;
  v_rows      int;
BEGIN
  -- ─── Firma, Auth-User, Mitgliedschaft ────────────────────────────────────
  INSERT INTO public.companies (id, name) VALUES (v_company, 'FloatTestCo');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'float@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'float@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  -- ─── Barkasse (Anfangsbestand 500) + ein Automat ─────────────────────────
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book, v_company, 'FloatKasse', 500, v_user, true);

  UPDATE public.cash_book_entries
     SET created_at = '2026-08-01 08:00+00'
   WHERE cash_book_id = v_book AND type = 'initial';

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine, 'Automat 1', v_company, v_book);

  INSERT INTO public.products (id, name, company) VALUES (v_product, 'TestBar', v_company);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine, 1, v_product, 100, 100);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 1: change_float ohne machine_id wird abgewiesen ════════════════
  v_raised := false;
  BEGIN
    INSERT INTO public.cash_book_entries
      (cash_book_id, company_id, type, amount, created_by)
      VALUES (v_book, v_company, 'change_float', -50, v_user);
  EXCEPTION WHEN others THEN
    v_raised := true;
  END;
  ASSERT v_raised, 'change_float ohne machine_id muss abgewiesen werden';
  RAISE NOTICE 'Test 1 bestanden: machine_id ist Pflicht';

  -- ═══ Test 2: change_float mit amount = 0 wird abgewiesen ═════════════════
  v_raised := false;
  BEGIN
    INSERT INTO public.cash_book_entries
      (cash_book_id, company_id, type, amount, machine_id, created_by)
      VALUES (v_book, v_company, 'change_float', 0, v_machine, v_user);
  EXCEPTION WHEN others THEN
    v_raised := true;
  END;
  ASSERT v_raised, 'change_float mit amount = 0 muss abgewiesen werden';
  RAISE NOTICE 'Test 2 bestanden: Nullbuchung gesperrt';

  -- ═══ Test 3: gültige Einlage senkt den Kassenstand ═══════════════════════
  INSERT INTO public.cash_book_entries
    (created_at, cash_book_id, company_id, type, amount, machine_id, created_by)
    VALUES ('2026-08-02 08:00+00', v_book, v_company, 'change_float', -50, v_machine, v_user)
    RETURNING id, balance_after INTO v_float_id, v_balance;

  ASSERT v_balance = 450, format('Kassenstand nach Einlage erwartet 450, war %s', v_balance);
  RAISE NOTICE 'Test 3 bestanden: Einlage senkt den Kassenstand';

  -- ═══ Test 4: Float-Bestand = −SUM(amount) ════════════════════════════════
  SELECT -SUM(amount) INTO v_balance
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float' AND is_reversed = false;
  ASSERT v_balance = 50, format('Float erwartet 50, war %s', v_balance);
  RAISE NOTICE 'Test 4 bestanden: Float-Bestand korrekt';

  -- ═══ Test 5: Storno einer change_float-Buchung ist möglich ═══════════════
  -- Die Gegenbuchung trägt type = 'reversal' und KEINE machine_id — der
  -- Trigger-Guard darf hier nicht greifen.
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, corrects_entry_id, created_by)
    VALUES (v_book, v_company, 'reversal', 0, v_float_id, v_user);

  SELECT is_reversed INTO v_raised
    FROM public.cash_book_entries WHERE id = v_float_id;
  ASSERT v_raised, 'Originalbuchung muss nach dem Storno als reversed markiert sein';

  SELECT COALESCE(-SUM(amount), 0) INTO v_balance
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float' AND is_reversed = false;
  ASSERT v_balance = 0, format('Float nach Storno erwartet 0, war %s', v_balance);
  RAISE NOTICE 'Test 5 bestanden: Storno nimmt den Float zurück';

  -- ═══ Test 6: get_theoretical_cash ist von change_float unberührt ═════════
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine, 1, 3.00, 'cash', '2026-08-03 09:00+00');

  v_before := public.get_theoretical_cash(v_book, v_company);

  INSERT INTO public.cash_book_entries
    (created_at, cash_book_id, company_id, type, amount, machine_id, created_by)
    VALUES ('2026-08-03 10:00+00', v_book, v_company, 'change_float', -20, v_machine, v_user);

  v_after := public.get_theoretical_cash(v_book, v_company);

  ASSERT (v_before->>'cash_sales_since')::float8 = (v_after->>'cash_sales_since')::float8,
    format('change_float darf cash_sales_since nicht verschieben: vorher %s, nachher %s',
           v_before->>'cash_sales_since', v_after->>'cash_sales_since');
  RAISE NOTICE 'Test 6 bestanden: Anker und Erwartungswert unverändert';

  -- ═══ Test 7: Automat löschen trotz offener Float-Buchung ═════════════════
  -- ON DELETE SET NULL darf nicht an einem CHECK scheitern.
  DELETE FROM public.machine_trays WHERE machine_id = v_machine;
  DELETE FROM public.sales WHERE machine_id = v_machine;
  DELETE FROM public."vendingMachine" WHERE id = v_machine;

  SELECT count(*) INTO v_rows
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float';
  ASSERT v_rows = 2, format('Float-Buchungen müssen das Löschen überleben, gefunden %s', v_rows);

  SELECT machine_id INTO v_machine_id_after
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book AND type = 'change_float'
   ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_machine_id_after IS NULL, 'machine_id muss nach dem Löschen NULL sein';
  RAISE NOTICE 'Test 7 bestanden: Automat bleibt löschbar';

END $$;

ROLLBACK;
```

- [ ] **Step 2: Test laufen lassen und Fehlschlag bestätigen**

Run:

```bash
Docker/supabase/tests/run-sql-tests.sh
```

Expected: `cash_book_change_float.test.sql` schlägt fehl. Erster Fehler ist ein Constraint-Verstoß beim gültigen Insert in Test 3 (`valid_type` kennt `change_float` noch nicht) — Test 1 und 2 „bestehen" vorher zufällig, weil `valid_type` alles ablehnt. Das ist erwartet und wird durch Step 4 aussagekräftig.

- [ ] **Step 3: Migration schreiben**

Create `Docker/supabase/migrations/20260807000000_cash_book_change_float.sql`:

```sql
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
```

- [ ] **Step 4: Migration anwenden und Test grün sehen**

Run:

```bash
cd Docker/supabase && supabase migration up && ./tests/run-sql-tests.sh
```

Expected: `cash_book_change_float.test.sql` läuft durch, sieben `Test N bestanden`-NOTICEs. Alle übrigen Testdateien bleiben grün — insbesondere `get_theoretical_cash_per_machine.test.sql`.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/migrations/20260807000000_cash_book_change_float.sql Docker/supabase/tests/cash_book_change_float.test.sql
git commit -m "feat(db): add change_float cash book entry type" -- Docker/supabase/migrations/20260807000000_cash_book_change_float.sql Docker/supabase/tests/cash_book_change_float.test.sql
```

---

### Task 2: RPC `get_machine_change_float`

**Files:**
- Create: `Docker/supabase/tests/cash_book_change_float_rpc.test.sql`
- Create: `Docker/supabase/migrations/20260807000100_cash_book_change_float_balance.sql`

**Interfaces:**
- Consumes: Buchungstyp `change_float` aus Task 1
- Produces: `public.get_machine_change_float(p_company_id uuid) RETURNS jsonb` — JSON-Array aus Objekten mit den Schlüsseln `machine_id` (uuid), `machine_name` (text|null), `cash_book_id` (uuid), `float_balance` (numeric, zwei Nachkommastellen), `last_change_at` (timestamptz). Gibt `NULL` zurück, wenn der Aufrufer nicht Mitglied der Firma ist, und `[]`, wenn kein Automat einen Saldo ungleich null hat.

- [ ] **Step 1: Testdatei schreiben**

Create `Docker/supabase/tests/cash_book_change_float_rpc.test.sql`:

```sql
-- Tests für get_machine_change_float (20260807000100) und
-- record_cash_book_withdrawal (20260807000200).
--
-- Der zweite Block wird in Task 3 ergänzt; bis dahin deckt die Datei nur
-- die Bestandsabfrage ab.
--
-- Läuft in einer zurückgerollten Transaktion. Voraussetzung:
-- `supabase start` + `supabase migration up`.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_stranger  uuid := gen_random_uuid();
  v_book      uuid := gen_random_uuid();
  v_machine_a uuid := gen_random_uuid();
  v_machine_b uuid := gen_random_uuid();
  v_entry_b   uuid;
  r jsonb; a float8; n int;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'FloatRpcCo');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'floatrpc@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'floatrpc@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book, v_company, 'RpcKasse', 1000, v_user);

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id) VALUES
    (v_machine_a, 'A', v_company, v_book),
    (v_machine_b, 'B', v_company, v_book);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 1: leerer Bestand liefert [] ═══════════════════════════════════
  r := public.get_machine_change_float(v_company);
  ASSERT r = '[]'::jsonb, format('ohne Buchungen erwartet [], war %s', r);
  RAISE NOTICE 'Test 1 bestanden: leerer Bestand';

  -- ═══ Test 2: Einlagen und Rücknahmen saldieren je Automat ════════════════
  -- A: −50 −25 zurück +30  →  Float 45
  -- B: −80                 →  Float 80, danach storniert → fällt raus
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, machine_id, created_by) VALUES
    (v_book, v_company, 'change_float', -50, v_machine_a, v_user),
    (v_book, v_company, 'change_float', -25, v_machine_a, v_user),
    (v_book, v_company, 'change_float',  30, v_machine_a, v_user);

  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, machine_id, created_by)
    VALUES (v_book, v_company, 'change_float', -80, v_machine_b, v_user)
    RETURNING id INTO v_entry_b;

  r := public.get_machine_change_float(v_company);
  RAISE NOTICE 'Bestand: %', r;

  SELECT (e->>'float_balance')::float8 INTO a
    FROM jsonb_array_elements(r) e WHERE (e->>'machine_id')::uuid = v_machine_a;
  ASSERT a = 45, format('A erwartet 45, war %s', a);
  RAISE NOTICE 'Test 2 bestanden: Saldierung je Automat';

  -- ═══ Test 3: Storno entfernt den Automaten aus dem Bestand ═══════════════
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, corrects_entry_id, created_by)
    VALUES (v_book, v_company, 'reversal', 0, v_entry_b, v_user);

  r := public.get_machine_change_float(v_company);
  SELECT count(*) INTO n
    FROM jsonb_array_elements(r) e WHERE (e->>'machine_id')::uuid = v_machine_b;
  ASSERT n = 0, format('B darf nach Storno nicht mehr auftauchen, gefunden %s', n);
  RAISE NOTICE 'Test 3 bestanden: Storno nimmt den Bestand zurück';

  -- ═══ Test 4: Saldo exakt null wird ausgeblendet ══════════════════════════
  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, machine_id, created_by)
    VALUES (v_book, v_company, 'change_float', 45, v_machine_a, v_user);

  r := public.get_machine_change_float(v_company);
  ASSERT r = '[]'::jsonb, format('bei Saldo 0 erwartet [], war %s', r);
  RAISE NOTICE 'Test 4 bestanden: Nullsaldo ausgeblendet';

  -- ═══ Test 5: Fremder Nutzer bekommt NULL ═════════════════════════════════
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_stranger::text, 'role', 'authenticated')::text, true);
  r := public.get_machine_change_float(v_company);
  ASSERT r IS NULL, format('Nicht-Mitglied muss NULL bekommen, war %s', r);
  RAISE NOTICE 'Test 5 bestanden: Firmenfremder abgewiesen';

END $$;

ROLLBACK;
```

- [ ] **Step 2: Test laufen lassen und Fehlschlag bestätigen**

Run:

```bash
Docker/supabase/tests/run-sql-tests.sh
```

Expected: FAIL mit `function public.get_machine_change_float(uuid) does not exist`.

- [ ] **Step 3: Migration schreiben**

Create `Docker/supabase/migrations/20260807000100_cash_book_change_float_balance.sql`:

```sql
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
```

- [ ] **Step 4: Migration anwenden und Test grün sehen**

Run:

```bash
cd Docker/supabase && supabase migration up && ./tests/run-sql-tests.sh
```

Expected: `cash_book_change_float_rpc.test.sql` mit fünf `Test N bestanden`-NOTICEs, alle übrigen Dateien weiterhin grün.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/migrations/20260807000100_cash_book_change_float_balance.sql Docker/supabase/tests/cash_book_change_float_rpc.test.sql
git commit -m "feat(db): add get_machine_change_float balance RPC" -- Docker/supabase/migrations/20260807000100_cash_book_change_float_balance.sql Docker/supabase/tests/cash_book_change_float_rpc.test.sql
```

---

### Task 3: RPC `record_cash_book_withdrawal`

**Files:**
- Modify: `Docker/supabase/tests/cash_book_change_float_rpc.test.sql` (zweiter DO-Block angehängt)
- Create: `Docker/supabase/migrations/20260807000200_cash_book_withdrawal_rpc.sql`

**Interfaces:**
- Consumes: Buchungstyp `change_float` (Task 1); Firmenprüfmuster aus `get_machine_change_float` (Task 2)
- Produces: `public.record_cash_book_withdrawal(p_cash_book_id uuid, p_machine_id uuid, p_counted float8, p_expected float8, p_float_back float8 DEFAULT 0, p_description text DEFAULT NULL, p_float_description text DEFAULT NULL) RETURNS jsonb` mit den Schlüsseln `withdrawal_entry_id` (uuid) und `change_float_entry_id` (uuid|null). Wirft `machine does not belong to this company`, wenn `p_machine_id` einer fremden Firma gehört, und `change float requires a machine`, wenn eine Rücklage ohne Automatenbezug gebucht werden soll.

- [ ] **Step 1: Test anhängen**

Append to `Docker/supabase/tests/cash_book_change_float_rpc.test.sql`, **vor** dem abschließenden `ROLLBACK;`:

```sql
-- ═════════════════════════════════════════════════════════════════════════
-- record_cash_book_withdrawal
-- ═════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_company uuid := gen_random_uuid();
  v_user    uuid := gen_random_uuid();
  v_book    uuid := gen_random_uuid();
  v_machine uuid := gen_random_uuid();
  v_other_company uuid := gen_random_uuid();
  v_other_machine uuid := gen_random_uuid();
  r jsonb; v_raised boolean; v_err text; v_balance float8; n int; n_after int;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'WithdrawRpcCo');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'wdrpc@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'wdrpc@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book, v_company, 'WdKasse', 0, v_user);

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id)
    VALUES (v_machine, 'A', v_company, v_book);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 6: ohne Rücklage entsteht genau eine Zeile ═════════════════════
  r := public.record_cash_book_withdrawal(v_book, v_machine, 100.00, 95.00, 0,
                                          'Geldentnahme', NULL);
  ASSERT r->>'withdrawal_entry_id' IS NOT NULL, 'withdrawal_entry_id fehlt';
  ASSERT r->>'change_float_entry_id' IS NULL,
    format('ohne Rücklage darf keine Float-Zeile entstehen, war %s', r->>'change_float_entry_id');

  SELECT balance_after INTO v_balance
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 100.00, format('Kassenstand erwartet 100.00, war %s', v_balance);
  RAISE NOTICE 'Test 6 bestanden: Entnahme ohne Rücklage';

  -- ═══ Test 7: mit Rücklage entstehen zwei Zeilen in richtiger Reihenfolge ═
  r := public.record_cash_book_withdrawal(v_book, v_machine, 200.00, 180.00, 50.00,
                                          'Geldentnahme', 'Wechselgeld Tuben');
  ASSERT r->>'change_float_entry_id' IS NOT NULL, 'change_float_entry_id fehlt';

  -- Netto: 100 + 200 − 50 = 250
  SELECT balance_after INTO v_balance
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_balance = 250.00, format('Kassenstand erwartet 250.00, war %s', v_balance);

  -- Die Float-Zeile muss die höhere entry_number tragen (Entnahme zuerst).
  SELECT type = 'change_float' INTO v_raised
    FROM public.cash_book_entries
   WHERE cash_book_id = v_book ORDER BY entry_number DESC LIMIT 1;
  ASSERT v_raised, 'die Wechselgeldbuchung muss nach der Entnahme stehen';
  RAISE NOTICE 'Test 7 bestanden: verkettete Doppelbuchung';

  -- ═══ Test 8: Float-Bestand nach der Doppelbuchung ════════════════════════
  r := public.get_machine_change_float(v_company);
  SELECT (e->>'float_balance')::float8 INTO v_balance
    FROM jsonb_array_elements(r) e WHERE (e->>'machine_id')::uuid = v_machine;
  ASSERT v_balance = 50.00, format('Float erwartet 50.00, war %s', v_balance);
  RAISE NOTICE 'Test 8 bestanden: Bestand nach Doppelbuchung';

  -- ═══ Test 9: Rücklage ohne Automat wird abgewiesen, ohne Teilbuchung ═════
  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(v_book, NULL, 10.00, 10.00, 5.00,
                                               'Geldentnahme', NULL);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  -- Auf die konkrete Meldung prüfen, nicht nur "irgendwas schlug fehl" — sonst
  -- bliebe der Test grün, wenn ein anderer Fehler zuerst greift. Gleiches
  -- Muster wie in den übrigen Testdateien dieses Verzeichnisses.
  ASSERT v_err LIKE '%change float requires a machine%',
    format('erwartet wurde die Automaten-Vorabprüfung, kam aber: %s', v_err);

  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book;
  ASSERT n_after = n,
    format('abgewiesener Aufruf darf keine Zeile hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 9 bestanden: keine halbe Buchung';

  -- ═══ Test 10: fremder Automat wird abgewiesen ════════════════════════════
  -- cash_book_entries bindet machine_id nicht an company_id. Ohne die
  -- Prüfung in der RPC ließe sich auf einen fremden Automaten buchen.
  INSERT INTO public.companies (id, name) VALUES (v_other_company, 'FremdeFirma');
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_other_machine, 'Fremd', v_other_company);

  SELECT count(*) INTO n FROM public.cash_book_entries WHERE cash_book_id = v_book;
  v_err := '';
  BEGIN
    PERFORM public.record_cash_book_withdrawal(v_book, v_other_machine, 10.00, 10.00, 0,
                                               'Geldentnahme', NULL);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  ASSERT v_err LIKE '%machine does not belong to this company%',
    format('erwartet wurde die Firmenprüfung, kam aber: %s', v_err);

  SELECT count(*) INTO n_after FROM public.cash_book_entries WHERE cash_book_id = v_book;
  ASSERT n_after = n,
    format('abgewiesener Aufruf darf keine Zeile hinterlassen: vorher %s, nachher %s', n, n_after);
  RAISE NOTICE 'Test 10 bestanden: fremder Automat abgewiesen';

END $$;
```

- [ ] **Step 2: Test laufen lassen und Fehlschlag bestätigen**

Run:

```bash
Docker/supabase/tests/run-sql-tests.sh
```

Expected: FAIL mit `function public.record_cash_book_withdrawal(...) does not exist`.

- [ ] **Step 3: Migration schreiben**

Create `Docker/supabase/migrations/20260807000200_cash_book_withdrawal_rpc.sql`:

```sql
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
```

- [ ] **Step 4: Migration anwenden und Test grün sehen**

Run:

```bash
cd Docker/supabase && supabase migration up && ./tests/run-sql-tests.sh
```

Expected: Tests 6–9 mit `bestanden`-NOTICEs, alle übrigen Dateien grün.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/migrations/20260807000200_cash_book_withdrawal_rpc.sql Docker/supabase/tests/cash_book_change_float_rpc.test.sql
git commit -m "feat(db): add record_cash_book_withdrawal RPC with float back" -- Docker/supabase/migrations/20260807000200_cash_book_withdrawal_rpc.sql Docker/supabase/tests/cash_book_change_float_rpc.test.sql
```

---

### Task 4: PWA-Composable — Typen, reine Helfer, Datenzugriff

**Files:**
- Modify: `management-frontend/app/composables/useCashBook.ts`
- Create: `management-frontend/app/composables/__tests__/useCashBook.test.ts`

**Interfaces:**
- Consumes: RPCs `get_machine_change_float` und `record_cash_book_withdrawal` (Tasks 2, 3)
- Produces:
  - `type ChangeFloatDirection = 'into_machine' | 'back_to_box'`
  - `interface MachineChangeFloat { machine_id: string; machine_name: string | null; cash_book_id: string; float_balance: number; last_change_at: string }`
  - `changeFloatAmount(direction: ChangeFloatDirection, input: number): number` — reine Funktion
  - `floatBalanceForMachine(rows: MachineChangeFloat[], machineId: string): number` — reine Funktion
  - `totalChangeFloat(rows: MachineChangeFloat[]): number` — reine Funktion
  - aus `useCashBook()`: `changeFloat: Ref<MachineChangeFloat[]>`, `fetchChangeFloat(): Promise<void>`, `changeFloatTotal: ComputedRef<number>`, `recordWithdrawal(payload): Promise<void>`
  - `CashBookEntry['type']` enthält zusätzlich `'change_float'`

- [ ] **Step 1: Testdatei schreiben**

Create `management-frontend/app/composables/__tests__/useCashBook.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import {
  changeFloatAmount,
  floatBalanceForMachine,
  totalChangeFloat,
  type MachineChangeFloat,
} from '../useCashBook'

const rows: MachineChangeFloat[] = [
  { machine_id: 'm1', machine_name: 'A', cash_book_id: 'b1', float_balance: 45, last_change_at: '2026-08-01T10:00:00Z' },
  { machine_id: 'm2', machine_name: 'B', cash_book_id: 'b1', float_balance: 80, last_change_at: '2026-08-02T10:00:00Z' },
  { machine_id: 'm1', machine_name: 'A', cash_book_id: 'b2', float_balance: 20, last_change_at: '2026-08-03T10:00:00Z' },
]

describe('changeFloatAmount', () => {
  it('negates the amount when money goes into the machine', () => {
    expect(changeFloatAmount('into_machine', 50)).toBe(-50)
  })

  it('keeps the amount positive when money comes back to the box', () => {
    expect(changeFloatAmount('back_to_box', 50)).toBe(50)
  })

  it('ignores the sign of the input — the direction decides', () => {
    expect(changeFloatAmount('into_machine', -50)).toBe(-50)
    expect(changeFloatAmount('back_to_box', -50)).toBe(50)
  })

  it('maps zero to zero for both directions', () => {
    expect(changeFloatAmount('into_machine', 0)).toBe(0)
    expect(changeFloatAmount('back_to_box', 0)).toBe(0)
  })
})

describe('floatBalanceForMachine', () => {
  it('sums a machine across cash books', () => {
    expect(floatBalanceForMachine(rows, 'm1')).toBe(65)
  })

  it('returns the single balance for a machine in one cash book', () => {
    expect(floatBalanceForMachine(rows, 'm2')).toBe(80)
  })

  it('returns zero for a machine with no float', () => {
    expect(floatBalanceForMachine(rows, 'unknown')).toBe(0)
  })

  it('returns zero for an empty list', () => {
    expect(floatBalanceForMachine([], 'm1')).toBe(0)
  })
})

describe('totalChangeFloat', () => {
  it('sums every row', () => {
    expect(totalChangeFloat(rows)).toBe(145)
  })

  it('returns zero for an empty list', () => {
    expect(totalChangeFloat([])).toBe(0)
  })
})
```

- [ ] **Step 2: Test laufen lassen und Fehlschlag bestätigen**

Run:

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useCashBook.test.ts
```

Expected: FAIL — `changeFloatAmount` ist kein Export von `../useCashBook`.

- [ ] **Step 3: Composable erweitern**

In `management-frontend/app/composables/useCashBook.ts`, den `type`-Eintrag von `CashBookEntry` ersetzen:

```ts
  type: 'initial' | 'withdrawal' | 'correction' | 'payout' | 'expense' | 'change_float' | 'reversal'
```

Nach dem `EXPENSE_CATEGORIES`-Block einfügen:

```ts
// ── Wechselgeld in Automaten (change_float) ─────────────────────────────────

/** Richtung einer Wechselgeldbuchung aus Sicht der Barkasse. */
export type ChangeFloatDirection = 'into_machine' | 'back_to_box'

/** Eine Zeile aus `get_machine_change_float` — vorgestrecktes Wechselgeld
 *  je (Automat, Barkasse). */
export interface MachineChangeFloat {
  machine_id: string
  machine_name: string | null
  cash_book_id: string
  float_balance: number
  last_change_at: string
}

/** Rechnet Richtung + nicht-negative Eingabe in den signierten `amount` um,
 *  der auf dem Eintrag landet. `amount` ist die Wirkung auf die Barkasse:
 *  Einlage in den Automaten senkt sie, Rücknahme hebt sie. Das Vorzeichen
 *  der Eingabe wird bewusst ignoriert — die Richtung entscheidet. */
export function changeFloatAmount(direction: ChangeFloatDirection, input: number): number {
  const abs = Math.abs(input)
  return direction === 'into_machine' ? -abs : abs
}

/** Vorgestrecktes Wechselgeld eines Automaten, summiert über Barkassen.
 *  Ein Automat kann die Barkasse gewechselt haben und dann mehrere Zeilen
 *  tragen. */
export function floatBalanceForMachine(rows: MachineChangeFloat[], machineId: string): number {
  return rows
    .filter(r => r.machine_id === machineId)
    .reduce((sum, r) => sum + r.float_balance, 0)
}

/** Gesamtes vorgestrecktes Wechselgeld über alle Zeilen. */
export function totalChangeFloat(rows: MachineChangeFloat[]): number {
  return rows.reduce((sum, r) => sum + r.float_balance, 0)
}
```

Den `type`-Parameter von `createEntry` erweitern:

```ts
    type: 'withdrawal' | 'correction' | 'payout' | 'expense' | 'change_float' | 'reversal'
```

Innerhalb von `useCashBook()`, neben `theoreticalCash`, den State ergänzen:

```ts
  const changeFloat = ref<MachineChangeFloat[]>([])
```

Nach `fetchTheoreticalCash` einfügen:

```ts
  // ── Wechselgeld-Bestand ──────────────────────────────────────────────────

  async function fetchChangeFloat() {
    const { data, error } = await (supabase as any)
      .rpc('get_machine_change_float', {
        p_company_id: organization.value?.id,
      })

    if (error) throw error
    changeFloat.value = (data ?? []) as MachineChangeFloat[]
  }

  /** Bucht eine Entnahme, optional mit Wechselgeld-Rücklage in die Münztuben.
   *  Beide Zeilen entstehen serverseitig in einer Transaktion. */
  async function recordWithdrawal(payload: {
    cash_book_id: string
    machine_id: string | null
    counted: number
    expected: number
    float_back: number
    description: string
    float_description: string
  }) {
    const { data, error } = await (supabase as any)
      .rpc('record_cash_book_withdrawal', {
        p_cash_book_id: payload.cash_book_id,
        p_machine_id: payload.machine_id,
        p_counted: payload.counted,
        p_expected: payload.expected,
        p_float_back: payload.float_back,
        p_description: payload.description,
        p_float_description: payload.float_description,
      })

    if (error) throw error

    const result = data as { withdrawal_entry_id: string; change_float_entry_id: string | null }

    await logActivity('cash_book_entry_created', result.withdrawal_entry_id, {
      cash_book_id: payload.cash_book_id,
      type: 'withdrawal',
      amount: payload.counted,
      description: payload.description,
      category: null,
    })

    if (result.change_float_entry_id) {
      await logActivity('cash_book_entry_created', result.change_float_entry_id, {
        cash_book_id: payload.cash_book_id,
        type: 'change_float',
        amount: -Math.abs(payload.float_back),
        description: payload.float_description,
        category: null,
      })
    }

    await fetchEntries(payload.cash_book_id)
    await fetchTheoreticalCash(payload.cash_book_id)
    await fetchChangeFloat()

    return result
  }
```

Nach dem `totalExpenses`-Computed einfügen:

```ts
  const changeFloatTotal = computed(() => totalChangeFloat(changeFloat.value))
```

Im `return`-Objekt ergänzen — bei den State-Feldern `changeFloat,`, bei den Entries-Funktionen `recordWithdrawal,`, bei der Theoretical-Gruppe `fetchChangeFloat,`, bei den Computed-KPIs `changeFloatTotal,`.

- [ ] **Step 4: Test laufen lassen und grün sehen**

Run:

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useCashBook.test.ts
```

Expected: PASS, 10 Tests.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/useCashBook.ts management-frontend/app/composables/__tests__/useCashBook.test.ts
git commit -m "feat(frontend): add change_float types, helpers and data access" -- management-frontend/app/composables/useCashBook.ts management-frontend/app/composables/__tests__/useCashBook.test.ts
```

---

### Task 5: PWA — Buchungsart in Liste, PDF und Übersetzungen sichtbar machen

Diese Task macht bereits gebuchte `change_float`-Einträge lesbar, bevor die Dialoge existieren. Danach ist die Liste vollständig, egal woher ein Eintrag stammt (iOS, API, direkter Insert).

**Files:**
- Modify: `management-frontend/app/components/cash-book/EntriesTable.vue:25-47`
- Modify: `management-frontend/app/pages/cash-book/index.vue:309-319` und PDF-Export
- Modify: `management-frontend/i18n/locales/de.json`, `en.json`, `fr.json`, `nl.json`

**Interfaces:**
- Consumes: `CashBookEntry['type']` inkl. `'change_float'` (Task 4)
- Produces: i18n-Schlüssel `cashBook.typeChangeFloat`, `cashBook.changeFloatIn`, `cashBook.changeFloatOut`, `cashBook.totalChangeFloat`, `cashBook.changeFloatStation`, `cashBook.recordChangeFloat`, `cashBook.changeFloatDirection`, `cashBook.changeFloatIntoMachine`, `cashBook.changeFloatBackToBox`, `cashBook.forMachine`, `cashBook.changeFloatHint`, `cashBook.changeFloatNegativeWarning`, `cashBook.floatBack`, `cashBook.floatBackHint`, `cashBook.netToBox`, `cashBook.changeFloatEmpty`

- [ ] **Step 1: Übersetzungen ergänzen**

In `management-frontend/i18n/locales/de.json`, im `cashBook`-Block:

```json
    "typeChangeFloat": "Wechselgeld",
    "changeFloatIn": "Wechselgeld in Automat",
    "changeFloatOut": "Wechselgeld aus Automat",
    "totalChangeFloat": "Wechselgeld vorgestreckt",
    "changeFloatStation": "In Münztuben",
    "recordChangeFloat": "Wechselgeld buchen",
    "changeFloatDirection": "Richtung",
    "changeFloatIntoMachine": "In den Automaten einlegen",
    "changeFloatBackToBox": "Aus dem Automaten zurück in die Kasse",
    "forMachine": "Automat",
    "changeFloatHint": "Geld, das du dem Automaten für Wechselgeld vorstreckst. Es zählt nicht als Ausgabe – es bleibt dein Geld.",
    "changeFloatNegativeWarning": "Du nimmst mehr zurück, als diesem Automaten vorgestreckt wurde. Wenn das kassiertes Geld ist, buche es als Entnahme.",
    "floatBack": "Davon zurück in die Münztuben",
    "floatBackHint": "Münzen, die du direkt wieder in die Tuben gefüllt hast. Die Entnahme wird trotzdem über den vollen gezählten Betrag gebucht.",
    "netToBox": "Netto in die Kasse",
    "changeFloatEmpty": "Kein Wechselgeld vorgestreckt",
```

Dieselben Schlüssel in `en.json`:

```json
    "typeChangeFloat": "Change float",
    "changeFloatIn": "Float into machine",
    "changeFloatOut": "Float back from machine",
    "totalChangeFloat": "Change float advanced",
    "changeFloatStation": "In coin tubes",
    "recordChangeFloat": "Record change float",
    "changeFloatDirection": "Direction",
    "changeFloatIntoMachine": "Into the machine",
    "changeFloatBackToBox": "Back from the machine into the box",
    "forMachine": "Machine",
    "changeFloatHint": "Money you advance to the machine so it can give change. It is not an expense — it stays your money.",
    "changeFloatNegativeWarning": "You are taking back more than was advanced to this machine. If this is collected cash, record it as a withdrawal.",
    "floatBack": "Of which returned to the coin tubes",
    "floatBackHint": "Coins you put straight back into the tubes. The withdrawal is still recorded for the full counted amount.",
    "netToBox": "Net into the box",
    "changeFloatEmpty": "No change float advanced",
```

In `fr.json`:

```json
    "typeChangeFloat": "Fonds de monnaie",
    "changeFloatIn": "Fonds vers le distributeur",
    "changeFloatOut": "Fonds repris du distributeur",
    "totalChangeFloat": "Fonds de monnaie avancé",
    "changeFloatStation": "Dans les tubes",
    "recordChangeFloat": "Enregistrer le fonds de monnaie",
    "changeFloatDirection": "Sens",
    "changeFloatIntoMachine": "Vers le distributeur",
    "changeFloatBackToBox": "Du distributeur vers la caisse",
    "forMachine": "Distributeur",
    "changeFloatHint": "Argent avancé au distributeur pour rendre la monnaie. Ce n'est pas une dépense — il reste votre argent.",
    "changeFloatNegativeWarning": "Vous reprenez plus que ce qui a été avancé à ce distributeur. S'il s'agit d'espèces encaissées, enregistrez un prélèvement.",
    "floatBack": "Dont remis dans les tubes",
    "floatBackHint": "Pièces remises directement dans les tubes. Le prélèvement reste enregistré pour le montant total compté.",
    "netToBox": "Net vers la caisse",
    "changeFloatEmpty": "Aucun fonds de monnaie avancé",
```

In `nl.json`:

```json
    "typeChangeFloat": "Wisselgeld",
    "changeFloatIn": "Wisselgeld naar automaat",
    "changeFloatOut": "Wisselgeld terug uit automaat",
    "totalChangeFloat": "Wisselgeld voorgeschoten",
    "changeFloatStation": "In muntbuizen",
    "recordChangeFloat": "Wisselgeld boeken",
    "changeFloatDirection": "Richting",
    "changeFloatIntoMachine": "In de automaat leggen",
    "changeFloatBackToBox": "Uit de automaat terug in de kas",
    "forMachine": "Automaat",
    "changeFloatHint": "Geld dat je de automaat voorschiet om wisselgeld te kunnen geven. Het is geen uitgave — het blijft jouw geld.",
    "changeFloatNegativeWarning": "Je neemt meer terug dan aan deze automaat is voorgeschoten. Als dit geïnd geld is, boek het dan als opname.",
    "floatBack": "Waarvan terug in de muntbuizen",
    "floatBackHint": "Munten die je direct terug in de buizen hebt gedaan. De opname wordt nog steeds voor het volledige getelde bedrag geboekt.",
    "netToBox": "Netto naar de kas",
    "changeFloatEmpty": "Geen wisselgeld voorgeschoten",
```

- [ ] **Step 2: Badge und Label in der Liste**

In `management-frontend/app/components/cash-book/EntriesTable.vue`, in `typeBadgeClass` vor `default:` einfügen:

```ts
    case 'change_float': return 'bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-400 border-purple-200 dark:border-purple-800'
```

In derselben Datei `typeLabel` ersetzen, damit Wechselgeld die Richtung aus dem Vorzeichen zeigt:

```ts
function typeLabel(type: string, amount?: number): string {
  if (type === 'change_float' && amount !== undefined) {
    return amount < 0 ? t('cashBook.changeFloatIn') : t('cashBook.changeFloatOut')
  }
  const map: Record<string, string> = {
    initial: t('cashBook.typeInitial'),
    withdrawal: t('cashBook.typeWithdrawal'),
    correction: t('cashBook.typeCorrection'),
    payout: t('cashBook.typePayout'),
    expense: t('cashBook.typeExpense'),
    change_float: t('cashBook.typeChangeFloat'),
    reversal: t('cashBook.typeReversal'),
  }
  return map[type] ?? type
}
```

Im Template von `EntriesTable.vue` den Aufruf in Zeile 138 auf `typeLabel(entry.type, entry.amount)` ändern.

- [ ] **Step 3: PDF-Export und Seiten-Label**

In `management-frontend/app/pages/cash-book/index.vue`, in der `typeLabel`-Funktion (Zeile 309-319) den Eintrag ergänzen:

```ts
    change_float: t('cashBook.typeChangeFloat'),
```

In `exportPdf`, direkt nach der `totalW`-Berechnung, die Summenzeile ergänzen:

```ts
  const changeFloats = allEntries.filter((e: any) => e.type === 'change_float' && !e.is_reversed)
  const totalCF = -changeFloats.reduce((s: number, e: any) => s + e.amount, 0)
```

und die Ausgabezeile unterhalb der bestehenden `totalWithdrawals`-Zeile:

```ts
  doc.text(`${t('cashBook.totalChangeFloat')}: ${formatCurrency(totalCF)} (${changeFloats.length})`, 14, y + 10)
```

Die y-Offsets der nachfolgenden Zeilen im Summenblock jeweils um 5 erhöhen.

- [ ] **Step 4: Lint und Tests laufen lassen**

Run:

```bash
cd management-frontend && npx vitest run && npx nuxt typecheck
```

Expected: Vitest PASS; `typecheck` ohne neue Fehler in `EntriesTable.vue` und `cash-book/index.vue`.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/components/cash-book/EntriesTable.vue management-frontend/app/pages/cash-book/index.vue management-frontend/i18n/locales
git commit -m "feat(frontend): render change_float entries in list and PDF" -- management-frontend/app/components/cash-book/EntriesTable.vue management-frontend/app/pages/cash-book/index.vue management-frontend/i18n/locales
```

---

### Task 6: PWA — Wechselgeld-Dialog

**Files:**
- Create: `management-frontend/app/components/cash-book/ChangeFloatModal.vue`
- Modify: `management-frontend/app/components/cash-book/SecondaryToolbar.vue`
- Modify: `management-frontend/app/pages/cash-book/index.vue`

**Interfaces:**
- Consumes: `changeFloatAmount`, `floatBalanceForMachine`, `MachineChangeFloat`, `VendingMachineBasic` (Task 4); i18n-Schlüssel (Task 5)
- Produces: Komponente `CashBookChangeFloatModal` mit Props `open: boolean`, `assignedMachines: VendingMachineBasic[]`, `changeFloat: MachineChangeFloat[]`; Events `update:open` und `submit` mit `{ amount: number; machineId: string; description: string }`, wobei `amount` bereits signiert ist; Toolbar-Event `changeFloat`

- [ ] **Step 1: Dialog anlegen**

Create `management-frontend/app/components/cash-book/ChangeFloatModal.vue`:

```vue
<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'
import {
  changeFloatAmount,
  floatBalanceForMachine,
  type ChangeFloatDirection,
  type MachineChangeFloat,
  type VendingMachineBasic,
} from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  assignedMachines: VendingMachineBasic[]
  changeFloat: MachineChangeFloat[]
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { amount: number; machineId: string; description: string }): void
}>()

const { t } = useI18n()

const form = ref({
  direction: 'into_machine' as ChangeFloatDirection,
  amount: 0,
  machine_id: '' as string,
  description: '',
})
const loading = ref(false)

/** Vorgestrecktes Wechselgeld des gewählten Automaten. */
const currentFloat = computed(() =>
  form.value.machine_id
    ? floatBalanceForMachine(props.changeFloat, form.value.machine_id)
    : 0,
)

/** Warnung, wenn mehr zurückgenommen wird als vorgestreckt wurde. Blockiert
 *  nicht — eine Buchung, die die Realität abbildet, wird nie verweigert. */
const showNegativeWarning = computed(() =>
  form.value.direction === 'back_to_box'
  && form.value.amount > 0
  && form.value.amount > currentFloat.value + 0.001,
)

const canSubmit = computed(() =>
  form.value.amount > 0 && form.value.machine_id !== '',
)

watch(() => props.open, (now) => {
  if (now) {
    form.value = {
      direction: 'into_machine',
      amount: 0,
      // Bei genau einem zugeordneten Automaten vorauswählen.
      machine_id: props.assignedMachines.length === 1 ? props.assignedMachines[0]!.id : '',
      description: '',
    }
  }
})

async function onSubmit() {
  if (!canSubmit.value) return
  loading.value = true
  try {
    emit('submit', {
      amount: changeFloatAmount(form.value.direction, form.value.amount),
      machineId: form.value.machine_id,
      description: form.value.description.trim(),
    })
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.recordChangeFloat')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <p class="text-xs text-muted-foreground">{{ t('cashBook.changeFloatHint') }}</p>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.changeFloatDirection') }}</label>
        <select
          v-model="form.direction"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option value="into_machine">{{ t('cashBook.changeFloatIntoMachine') }}</option>
          <option value="back_to_box">{{ t('cashBook.changeFloatBackToBox') }}</option>
        </select>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.forMachine') }}</label>
        <select
          v-model="form.machine_id"
          required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option value="">—</option>
          <option v-for="m in assignedMachines" :key="m.id" :value="m.id">
            {{ m.name || m.id.slice(0, 8) }}
          </option>
        </select>
        <p v-if="form.machine_id" class="mt-1 text-xs text-muted-foreground">
          {{ t('cashBook.totalChangeFloat') }}: {{ formatCurrency(currentFloat) }}
        </p>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.amount') }} (EUR)</label>
        <input
          v-model.number="form.amount"
          type="number" step="0.01" min="0" required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <p v-if="showNegativeWarning" class="text-sm text-amber-600 dark:text-amber-400">
        {{ t('cashBook.changeFloatNegativeWarning') }}
      </p>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.description') }}</label>
        <input
          v-model="form.description"
          type="text"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div class="flex justify-end gap-2">
        <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
          {{ t('common.cancel') }}
        </button>
        <button type="submit" :disabled="loading || !canSubmit"
                class="h-9 rounded-md bg-purple-600 px-4 text-sm font-medium text-white hover:bg-purple-700 disabled:opacity-50">
          {{ loading ? t('common.loading') : t('cashBook.bookEntry') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
```

- [ ] **Step 2: Toolbar-Button**

In `management-frontend/app/components/cash-book/SecondaryToolbar.vue`, den Import in Zeile 2 auf

```ts
import { IconArrowsExchange, IconCoins, IconDevices, IconDownload, IconDots, IconReceipt, IconSettings, IconTrash } from '@tabler/icons-vue'
```

ändern, im `defineEmits` `(e: 'changeFloat'): void` ergänzen und im Template vor dem Korrektur-Button einfügen:

```vue
    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('changeFloat')"
    >
      <IconCoins class="size-4" />
      {{ t('cashBook.recordChangeFloat') }}
    </button>
```

- [ ] **Step 3: Seite verdrahten**

In `management-frontend/app/pages/cash-book/index.vue`:

State ergänzen (neben `showCorrectionModal`):

```ts
const showChangeFloatModal = ref(false)
```

`changeFloat` und `fetchChangeFloat` aus `useCashBook()` destrukturieren.

In `loadCashBookData()` (bzw. dort, wo `fetchTheoreticalCash` aufgerufen wird) zusätzlich `await fetchChangeFloat()` aufrufen.

Handler ergänzen:

```ts
function openChangeFloat() {
  if (allMachines.value.length === 0) fetchAllMachines()
  showChangeFloatModal.value = true
}

async function onChangeFloatSubmit(payload: { amount: number; machineId: string; description: string }) {
  if (!selectedCashBook.value) return
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'change_float',
      amount: payload.amount,
      description: payload.description || null,
      machine_id: payload.machineId,
    })
    await fetchChangeFloat()
    showChangeFloatModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  }
}
```

Im Template am `CashBookSecondaryToolbar` `@change-float="openChangeFloat"` ergänzen und den Dialog einhängen:

```vue
    <CashBookChangeFloatModal
      v-model:open="showChangeFloatModal"
      :assigned-machines="assignedMachines"
      :change-float="changeFloat"
      @submit="onChangeFloatSubmit"
    />
```

- [ ] **Step 4: Im Browser prüfen**

Run:

```bash
cd management-frontend && npm run dev
```

Dann über die Preview-Tools: `/cash-book` öffnen, „Wechselgeld buchen" klicken, Automat wählen, 50 € als Einlage buchen. Erwartung: Kassenstand sinkt um 50 €, in der Liste erscheint ein violettes Badge „Wechselgeld in Automat" mit Betrag `-50,00 €`. Konsole und Netzwerk-Tab auf Fehler prüfen.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/components/cash-book/ChangeFloatModal.vue management-frontend/app/components/cash-book/SecondaryToolbar.vue management-frontend/app/pages/cash-book/index.vue
git commit -m "feat(frontend): add change float booking dialog" -- management-frontend/app/components/cash-book/ChangeFloatModal.vue management-frontend/app/components/cash-book/SecondaryToolbar.vue management-frontend/app/pages/cash-book/index.vue
```

---

### Task 7: PWA — Bestandskarte im Kassenbuch-Flow

**Files:**
- Create: `management-frontend/app/components/cash-book/StationChangeFloat.vue`
- Modify: `management-frontend/app/components/cash-book/FlowVisualisation.vue`
- Modify: `management-frontend/app/pages/cash-book/index.vue`

**Interfaces:**
- Consumes: `MachineChangeFloat`, `totalChangeFloat` (Task 4); i18n aus Task 5
- Produces: Komponente `CashBookStationChangeFloat` mit Props `changeFloat: MachineChangeFloat[]`; `FlowVisualisation` akzeptiert zusätzlich die Prop `changeFloat: MachineChangeFloat[]`

- [ ] **Step 1: Karte anlegen**

Create `management-frontend/app/components/cash-book/StationChangeFloat.vue`:

```vue
<script setup lang="ts">
import { IconCoins } from '@tabler/icons-vue'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency } from '@/lib/utils'
import { totalChangeFloat, type MachineChangeFloat } from '@/composables/useCashBook'

const props = defineProps<{ changeFloat: MachineChangeFloat[] }>()
const { t } = useI18n()

const total = computed(() => totalChangeFloat(props.changeFloat))

/** Je Automat summiert — ein Automat kann in mehreren Barkassen Zeilen haben. */
const perMachine = computed(() => {
  const byId = new Map<string, { name: string; balance: number }>()
  for (const row of props.changeFloat) {
    const existing = byId.get(row.machine_id)
    if (existing) {
      existing.balance += row.float_balance
    } else {
      byId.set(row.machine_id, {
        name: row.machine_name || row.machine_id.slice(0, 8),
        balance: row.float_balance,
      })
    }
  }
  return [...byId.values()].sort((a, b) => b.balance - a.balance)
})
</script>

<template>
  <Card>
    <CardHeader>
      <CardDescription class="flex items-center gap-1.5">
        <IconCoins class="size-4" />
        {{ t('cashBook.changeFloatStation') }}
      </CardDescription>
      <CardTitle class="text-2xl font-semibold tabular-nums">
        {{ formatCurrency(total) }}
      </CardTitle>
    </CardHeader>
    <div class="px-6 pb-4">
      <div v-if="perMachine.length === 0" class="text-xs text-muted-foreground">
        {{ t('cashBook.changeFloatEmpty') }}
      </div>
      <div v-else class="space-y-0.5">
        <div
          v-for="m in perMachine"
          :key="m.name"
          class="flex items-center justify-between text-xs text-muted-foreground"
        >
          <span>{{ m.name }}</span>
          <span class="tabular-nums">{{ formatCurrency(m.balance) }}</span>
        </div>
      </div>
    </div>
  </Card>
</template>
```

- [ ] **Step 2: In den Flow einhängen**

In `management-frontend/app/components/cash-book/FlowVisualisation.vue` die Props um

```ts
  changeFloat: MachineChangeFloat[]
```

erweitern und den Import in Zeile 3 auf

```ts
import type { CashBookEntry, MachineChangeFloat, TheoreticalCash } from '@/composables/useCashBook'
```

ändern.

Im Template, direkt vor dem schließenden `</div>` des äußeren `flex flex-col gap-4`-Containers (also nach dem Desktop-Button-Grid in Zeile 93), einfügen:

```vue
    <!-- Wechselgeld ist eine Seitentasche der Kasse, kein Kettenglied —
         daher eine eigene Karte unter der Kette statt einer vierten Spalte. -->
    <CashBookStationChangeFloat :change-float="changeFloat" />
```

- [ ] **Step 3: Prop durchreichen**

In `management-frontend/app/pages/cash-book/index.vue` am `CashBookFlowVisualisation` die Prop ergänzen:

```vue
      :change-float="changeFloat"
```

- [ ] **Step 4: Im Browser prüfen**

Dev-Server läuft bereits. `/cash-book` neu laden. Erwartung: unter der Stationskette erscheint die Karte „In Münztuben" mit der Summe aus Task 6 (50,00 €) und einer Zeile für den Automaten. Konsole prüfen.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/components/cash-book/StationChangeFloat.vue management-frontend/app/components/cash-book/FlowVisualisation.vue management-frontend/app/pages/cash-book/index.vue
git commit -m "feat(frontend): show advanced change float per machine" -- management-frontend/app/components/cash-book/StationChangeFloat.vue management-frontend/app/components/cash-book/FlowVisualisation.vue management-frontend/app/pages/cash-book/index.vue
```

---

### Task 8: PWA — Entnahme mit Tubenrücklage

**Files:**
- Modify: `management-frontend/app/components/cash-book/WithdrawalModal.vue`
- Modify: `management-frontend/app/pages/cash-book/index.vue:155-176`

**Interfaces:**
- Consumes: `recordWithdrawal` (Task 4); i18n `floatBack`, `floatBackHint`, `netToBox` (Task 5)
- Produces: `WithdrawalModal` emittiert `submit` künftig mit `{ counted: number; expected: number; machineId: string | null; floatBack: number; description: string }`

- [ ] **Step 1: Dialog erweitern**

In `management-frontend/app/components/cash-book/WithdrawalModal.vue`:

Das Emit-Signature in Zeile 14 ersetzen:

```ts
  (e: 'submit', payload: { counted: number; expected: number; machineId: string | null; floatBack: number; description: string }): void
```

Das Formular-Objekt (Zeilen 19-23) ersetzen:

```ts
const form = ref({
  counted_amount: 0,
  float_back: 0,
  description: 'Geldentnahme aus Automat',
  machine_id: null as string | null,
})
```

Nach `difference` einfügen:

```ts
/** Was nach der Tubenrücklage tatsächlich in der Kasse landet. */
const netToBox = computed(() => form.value.counted_amount - form.value.float_back)

/** Sobald eine Rücklage erfasst wird, ist der Automatenbezug zwingend —
 *  unabhängig von `trackPerMachine`, das nur den Erwartungswert verankert. */
const machineRequired = computed(() => form.value.float_back > 0)

const canSubmit = computed(() =>
  form.value.counted_amount > 0
  && (!machineRequired.value || form.value.machine_id !== null),
)
```

Den `watch` (Zeilen 31-35) ersetzen:

```ts
watch(() => props.open, (now) => {
  if (now) {
    form.value = {
      counted_amount: 0,
      float_back: 0,
      description: 'Geldentnahme aus Automat',
      machine_id: props.assignedMachines.length === 1 ? props.assignedMachines[0]!.id : null,
    }
  }
})
```

`onSubmit` ersetzen:

```ts
async function onSubmit() {
  if (!canSubmit.value) return
  loading.value = true
  try {
    emit('submit', {
      counted: form.value.counted_amount,
      expected: props.theoreticalCash?.cash_sales_since ?? 0,
      machineId: form.value.machine_id,
      floatBack: form.value.float_back,
      description: form.value.description,
    })
  } finally {
    loading.value = false
  }
}
```

Im Template nach dem Differenz-Block (Zeile 89) einfügen:

```vue
      <div>
        <label class="text-sm font-medium">{{ t('cashBook.floatBack') }} (EUR)</label>
        <input
          v-model.number="form.float_back"
          type="number" step="0.01" min="0"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.floatBackHint') }}</p>
      </div>

      <div v-if="form.float_back > 0" class="text-sm text-muted-foreground">
        {{ t('cashBook.netToBox') }}: {{ formatCurrency(netToBox) }}
      </div>
```

Die Bedingung des Automaten-Blocks (Zeile 91) ersetzen, damit er auch ohne `trackPerMachine` erscheint, sobald eine Rücklage erfasst wird:

```vue
      <div v-if="(trackPerMachine || machineRequired) && assignedMachines.length > 0">
        <label class="text-sm font-medium">
          {{ t('cashBook.fromMachine') }}
          <span v-if="machineRequired" class="text-red-600">*</span>
        </label>
```

Den Submit-Button (Zeile 117) auf `:disabled="loading || !canSubmit"` ändern.

- [ ] **Step 2: Seite auf die RPC umstellen**

In `management-frontend/app/pages/cash-book/index.vue` `onWithdrawalSubmit` (Zeilen 155-176) ersetzen:

```ts
async function onWithdrawalSubmit(payload: {
  counted: number
  expected: number
  machineId: string | null
  floatBack: number
  description: string
}) {
  if (!selectedCashBook.value) return
  try {
    await recordWithdrawal({
      cash_book_id: selectedCashBook.value.id,
      machine_id: payload.machineId,
      counted: payload.counted,
      expected: payload.expected,
      float_back: payload.floatBack,
      description: payload.description,
      float_description: t('cashBook.changeFloatIn'),
    })
    showWithdrawalModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  }
}
```

`recordWithdrawal` aus `useCashBook()` destrukturieren.

- [ ] **Step 3: Im Browser prüfen**

Dev-Server läuft. `/cash-book` → „Entnahme buchen": gezählt 200, Rücklage 50, Automat wählen. Erwartung: „Netto in die Kasse: 150,00 €"; nach dem Buchen zwei neue Zeilen in der Liste (Entnahme +200,00 €, Wechselgeld -50,00 €), Kassenstand +150, Karte „In Münztuben" steigt um 50. Konsole und Netzwerk prüfen.

Zusätzlich gegenprüfen: Rücklage 0 buchen → nur eine Zeile, Verhalten wie vorher.

- [ ] **Step 4: Tests laufen lassen**

Run:

```bash
cd management-frontend && npx vitest run
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/components/cash-book/WithdrawalModal.vue management-frontend/app/pages/cash-book/index.vue
git commit -m "feat(frontend): record change float back to tubes during withdrawal" -- management-frontend/app/components/cash-book/WithdrawalModal.vue management-frontend/app/pages/cash-book/index.vue
```

---

### Task 9: iOS — Modell und ViewModel

**Files:**
- Modify: `ios/VMflow/Models/CashBook.swift`
- Modify: `ios/VMflow/ViewModels/CashBookViewModel.swift`

**Interfaces:**
- Consumes: RPCs aus Tasks 2 und 3
- Produces:
  - `CashBookEntryType.changeFloat` (Rohwert `"change_float"`)
  - `struct MachineChangeFloat: Codable, Identifiable, Hashable` mit `machineId: UUID`, `machineName: String?`, `cashBookId: UUID`, `floatBalance: Double`, `lastChangeAt: Date`
  - `enum ChangeFloatDirection { case intoMachine, backToBox }` mit `func signedAmount(_ input: Double) -> Double`
  - `CashBookViewModel.changeFloat: [MachineChangeFloat]`
  - `CashBookViewModel.loadChangeFloat() async`
  - `CashBookViewModel.floatBalance(for machineId: UUID) -> Double`
  - `CashBookViewModel.recordChangeFloat(cashBookId:amount:machineId:description:) async throws`
  - `CashBookViewModel.recordWithdrawal(cashBookId:counted:expected:machineId:floatBack:description:floatDescription:) async throws` — **erweiterte Signatur**

- [ ] **Step 1: Prüfskript für die Vorzeichenlogik schreiben**

Es gibt kein iOS-Testtarget. Create `/private/tmp/claude-501/scratch-changefloat.swift` (Wegwerfdatei, nicht committen):

```swift
enum ChangeFloatDirection {
    case intoMachine
    case backToBox

    func signedAmount(_ input: Double) -> Double {
        let magnitude = abs(input)
        return self == .intoMachine ? -magnitude : magnitude
    }
}

func check(_ actual: Double, _ expected: Double, _ label: String) {
    if actual == expected {
        print("ok   \(label)")
    } else {
        print("FAIL \(label): expected \(expected), got \(actual)")
    }
}

check(ChangeFloatDirection.intoMachine.signedAmount(50), -50, "into machine negates")
check(ChangeFloatDirection.backToBox.signedAmount(50), 50, "back to box stays positive")
check(ChangeFloatDirection.intoMachine.signedAmount(-50), -50, "into machine ignores input sign")
check(ChangeFloatDirection.backToBox.signedAmount(-50), 50, "back to box ignores input sign")
check(ChangeFloatDirection.intoMachine.signedAmount(0), 0, "zero stays zero")
```

- [ ] **Step 2: Skript laufen lassen**

Run:

```bash
swift /private/tmp/claude-501/scratch-changefloat.swift
```

Expected: fünf `ok`-Zeilen, kein `FAIL`. Damit ist die Vorzeichenlogik verifiziert, bevor sie ins Projekt wandert.

- [ ] **Step 3: Modell erweitern**

In `ios/VMflow/Models/CashBook.swift` den Enum-Case ergänzen (vor `case reversal`):

```swift
    case changeFloat = "change_float"
```

Am Dateiende anfügen:

```swift
// MARK: - MachineChangeFloat (RPC payload)

/// Vorgestrecktes Wechselgeld je (Automat, Barkasse) aus
/// `get_machine_change_float`. Kein Tubenfüllstand — der ist von außen nicht
/// ermittelbar. Diese Zahl ändert sich ausschließlich durch eigene Buchungen.
struct MachineChangeFloat: Codable, Identifiable, Hashable {
    var id: String { "\(machineId.uuidString)-\(cashBookId.uuidString)" }
    let machineId: UUID
    let machineName: String?
    let cashBookId: UUID
    let floatBalance: Double
    let lastChangeAt: Date

    enum CodingKeys: String, CodingKey {
        case machineId = "machine_id"
        case machineName = "machine_name"
        case cashBookId = "cash_book_id"
        case floatBalance = "float_balance"
        case lastChangeAt = "last_change_at"
    }
}

// MARK: - ChangeFloatDirection

/// Richtung einer Wechselgeldbuchung aus Sicht der Barkasse. Die Oberfläche
/// fragt nie ein rohes Vorzeichen ab — Richtung plus nicht-negativer Betrag,
/// die Umrechnung passiert hier.
enum ChangeFloatDirection {
    case intoMachine
    case backToBox

    /// `amount` ist die Wirkung auf die Barkasse: eine Einlage senkt sie,
    /// eine Rücknahme hebt sie. Das Vorzeichen der Eingabe wird bewusst
    /// ignoriert — die Richtung entscheidet.
    func signedAmount(_ input: Double) -> Double {
        let magnitude = abs(input)
        return self == .intoMachine ? -magnitude : magnitude
    }
}
```

- [ ] **Step 4: ViewModel erweitern**

In `ios/VMflow/ViewModels/CashBookViewModel.swift`:

Published-State ergänzen (neben `theoreticalCash`):

```swift
    @Published private(set) var changeFloat: [MachineChangeFloat] = []
```

`recordWithdrawal` (Zeilen 192-247) vollständig ersetzen:

```swift
    /// Bucht eine Entnahme, optional mit Wechselgeld-Rücklage in die Münztuben.
    /// Beide Zeilen entstehen serverseitig in einer Transaktion — eine gebuchte
    /// Entnahme ohne die zugehörige Rücklage würde den Kassenstand still
    /// überhöhen.
    ///
    /// `floatBack` wird als nicht-negativer Betrag übergeben; die RPC negiert
    /// intern. Ist `floatBack` ungleich null, ist `machineId` zwingend.
    func recordWithdrawal(
        cashBookId: UUID,
        counted: Double,
        expected: Double,
        machineId: UUID?,
        floatBack: Double = 0,
        description: String,
        floatDescription: String? = nil
    ) async throws {
        guard let companyId = cashBooks.first(where: { $0.id == cashBookId })?.companyId,
              client.auth.currentUser?.id != nil else {
            throw CashBookError.notAuthenticated
        }

        struct Params: Encodable {
            let p_cash_book_id: UUID
            let p_machine_id: UUID?
            let p_counted: Double
            let p_expected: Double
            let p_float_back: Double
            let p_description: String?
            let p_float_description: String?
        }

        struct Result: Decodable {
            let withdrawal_entry_id: UUID
            let change_float_entry_id: UUID?
        }

        let result: Result = try await client
            .rpc("record_cash_book_withdrawal", params: Params(
                p_cash_book_id: cashBookId,
                p_machine_id: machineId,
                p_counted: counted,
                p_expected: expected,
                p_float_back: floatBack,
                p_description: description.isEmpty ? nil : description,
                p_float_description: floatDescription
            ))
            .execute()
            .value

        await logCashBookEntryActivity(
            entryId: result.withdrawal_entry_id,
            cashBookId: cashBookId,
            companyId: companyId,
            type: "withdrawal",
            amount: counted,
            category: nil,
            description: description.isEmpty ? nil : description
        )

        if let floatEntryId = result.change_float_entry_id {
            await logCashBookEntryActivity(
                entryId: floatEntryId,
                cashBookId: cashBookId,
                companyId: companyId,
                type: "change_float",
                amount: -abs(floatBack),
                category: nil,
                description: floatDescription
            )
        }

        await loadEntries(for: cashBookId)
        await loadTheoreticalCash(for: cashBookId)
        await loadChangeFloat()
    }
```

Nach `recordExpense` einfügen:

```swift
    // MARK: - Wechselgeld (change_float)

    /// Lädt den vorgestreckten Wechselgeldbestand je Automat für die Firma.
    func loadChangeFloat() async {
        guard let companyId = cashBooks.first?.companyId else {
            changeFloat = []
            return
        }
        struct Params: Encodable { let p_company_id: UUID }
        do {
            let rows: [MachineChangeFloat] = try await client
                .rpc("get_machine_change_float", params: Params(p_company_id: companyId))
                .execute()
                .value
            changeFloat = rows
        } catch {
            changeFloat = []
        }
    }

    /// Vorgestrecktes Wechselgeld eines Automaten, summiert über Barkassen —
    /// ein Automat kann die Barkasse gewechselt haben.
    func floatBalance(for machineId: UUID) -> Double {
        changeFloat
            .filter { $0.machineId == machineId }
            .reduce(0) { $0 + $1.floatBalance }
    }

    /// Bucht eine eigenständige Wechselgeldbewegung. `amount` ist bereits
    /// signiert (siehe `ChangeFloatDirection.signedAmount`).
    func recordChangeFloat(
        cashBookId: UUID,
        amount: Double,
        machineId: UUID,
        description: String
    ) async throws {
        guard let companyId = cashBooks.first(where: { $0.id == cashBookId })?.companyId,
              let userId = client.auth.currentUser?.id else {
            throw CashBookError.notAuthenticated
        }

        struct Insert: Encodable {
            let cash_book_id: UUID
            let company_id: UUID
            let type: String
            let amount: Double
            let description: String?
            let machine_id: UUID
            let created_by: UUID
        }

        let row = Insert(
            cash_book_id: cashBookId,
            company_id: companyId,
            type: "change_float",
            amount: amount,
            description: description.isEmpty ? nil : description,
            machine_id: machineId,
            created_by: userId
        )

        let inserted: InsertedEntryId = try await client
            .from("cash_book_entries")
            .insert(row)
            .select("id")
            .single()
            .execute()
            .value

        await logCashBookEntryActivity(
            entryId: inserted.id,
            cashBookId: cashBookId,
            companyId: companyId,
            type: "change_float",
            amount: amount,
            category: nil,
            description: description.isEmpty ? nil : description
        )

        await loadEntries(for: cashBookId)
        await loadTheoreticalCash(for: cashBookId)
        await loadChangeFloat()
    }
```

In `refresh()` nach dem Laden der Barkassen `await loadChangeFloat()` ergänzen.

- [ ] **Step 5: Build und Commit**

Run:

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`. Die bestehende `WithdrawalSheet.swift` ruft `recordWithdrawal` weiterhin ohne die neuen Parameter auf — das kompiliert wegen der Default-Werte.

```bash
git add ios/VMflow/Models/CashBook.swift ios/VMflow/ViewModels/CashBookViewModel.swift
git commit -m "feat(ios): add change float model and view model support" -- ios/VMflow/Models/CashBook.swift ios/VMflow/ViewModels/CashBookViewModel.swift
```

---

### Task 10: iOS — Wechselgeld-Dialog

**Files:**
- Create: `ios/VMflow/Views/CashBook/ChangeFloatSheet.swift`
- Modify: `ios/VMflow.xcodeproj/project.pbxproj`
- Modify: `ios/VMflow/Views/CashBook/CashBookView.swift`
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ChangeFloatDirection`, `recordChangeFloat`, `floatBalance(for:)` (Task 9)
- Produces: `struct ChangeFloatSheet: View` mit `let cashBook: CashBook`

- [ ] **Step 1: Sheet anlegen**

Create `ios/VMflow/Views/CashBook/ChangeFloatSheet.swift`:

```swift
import SwiftUI

/// Bucht Wechselgeld, das der Barkasse entnommen und in die Münztuben eines
/// Automaten gelegt wird — oder von dort zurückgeholt wird.
///
/// Der Automatenbezug ist immer Pflicht, unabhängig von `trackPerMachine`:
/// diese Einstellung verankert den Erwartungswert, sagt aber nichts darüber
/// aus, wo das vorgestreckte Geld liegt.
struct ChangeFloatSheet: View {
    let cashBook: CashBook

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    @State private var direction: ChangeFloatDirection = .intoMachine
    @State private var amountText: String = ""
    @State private var selectedMachineId: UUID?
    @State private var description: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var amount: Double {
        Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var assignedMachines: [CashBookMachineRef] {
        cashBookVM.assignedMachines(for: cashBook.id)
    }

    private var currentFloat: Double {
        guard let id = selectedMachineId else { return 0 }
        return cashBookVM.floatBalance(for: id)
    }

    /// Warnt, wenn mehr zurückgenommen wird als vorgestreckt wurde. Blockiert
    /// nicht — eine Buchung, die die Realität abbildet, wird nie verweigert.
    private var showsNegativeWarning: Bool {
        direction == .backToBox && amount > 0 && amount > currentFloat + 0.001
    }

    private var canSubmit: Bool {
        amount > 0 && selectedMachineId != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("cash_book_change_float_direction", selection: $direction) {
                        Text("cash_book_change_float_into_machine").tag(ChangeFloatDirection.intoMachine)
                        Text("cash_book_change_float_back_to_box").tag(ChangeFloatDirection.backToBox)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text("cash_book_change_float_hint")
                }

                Section("cash_book_for_machine") {
                    Picker("cash_book_for_machine", selection: $selectedMachineId) {
                        Text("—").tag(UUID?.none)
                        ForEach(assignedMachines) { m in
                            Text(m.name ?? String(m.id.uuidString.prefix(8)))
                                .tag(UUID?.some(m.id))
                        }
                    }
                    .labelsHidden()

                    if selectedMachineId != nil {
                        LabeledContent {
                            Text(currentFloat, format: .currency(code: "EUR"))
                                .monospacedDigit()
                        } label: {
                            Text("cash_book_total_change_float")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("cash_book_amount") {
                    TextField("0,00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                }

                if showsNegativeWarning {
                    Section {
                        Text("cash_book_change_float_negative_warning")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("cash_book_description") {
                    TextField(text: $description) { Text(verbatim: "") }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("cash_book_record_change_float")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cash_book_cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("cash_book_book_entry") }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
            .task {
                // Bei genau einem zugeordneten Automaten vorauswählen.
                if selectedMachineId == nil, assignedMachines.count == 1 {
                    selectedMachineId = assignedMachines.first?.id
                }
            }
        }
    }

    private func submit() async {
        guard canSubmit, let machineId = selectedMachineId else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await cashBookVM.recordChangeFloat(
                cashBookId: cashBook.id,
                amount: direction.signedAmount(amount),
                machineId: machineId,
                description: description.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Datei im Xcode-Projekt registrieren**

`ios/VMflow.xcodeproj/project.pbxproj` an vier Stellen editieren. Als Vorlage dient jeweils die Zeile von `ExpenseSheet.swift` — dieselbe Gruppe, dieselbe Build-Phase.

1. **PBXBuildFile-Sektion** — neben dem `ExpenseSheet.swift`-Eintrag eine Zeile mit neuer, im Projekt noch nicht vergebener 24-stelliger Hex-ID ergänzen:

```
		A1CF0001000000000000CF01 /* ChangeFloatSheet.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1CF0002000000000000CF02 /* ChangeFloatSheet.swift */; };
```

2. **PBXFileReference-Sektion**:

```
		A1CF0002000000000000CF02 /* ChangeFloatSheet.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ChangeFloatSheet.swift; sourceTree = "<group>"; };
```

3. **children der CashBook-Gruppe** — neben `ExpenseSheet.swift`:

```
				A1CF0002000000000000CF02 /* ChangeFloatSheet.swift */,
```

4. **Sources-Build-Phase** — neben dem `ExpenseSheet.swift in Sources`-Eintrag:

```
				A1CF0001000000000000CF01 /* ChangeFloatSheet.swift in Sources */,
```

Vor dem Editieren prüfen, dass beide IDs frei sind:

```bash
grep -c "A1CF0001000000000000CF01\|A1CF0002000000000000CF02" ios/VMflow.xcodeproj/project.pbxproj
```

Expected: `0`. Falls nicht null, andere IDs wählen.

- [ ] **Step 3: Übersetzungen und Einbindung**

In `ios/VMflow/Resources/Localizable.xcstrings` acht Einträge chirurgisch einfügen (nur `de`, du-Ton, alphabetisch an der jeweils passenden Stelle im `strings`-Objekt). Schlüssel und deutsche Werte:

| Schlüssel | Wert |
|---|---|
| `cash_book_record_change_float` | Wechselgeld buchen |
| `cash_book_change_float_direction` | Richtung |
| `cash_book_change_float_into_machine` | In den Automaten einlegen |
| `cash_book_change_float_back_to_box` | Aus dem Automaten zurück in die Kasse |
| `cash_book_change_float_hint` | Geld, das du dem Automaten für Wechselgeld vorstreckst. Es zählt nicht als Ausgabe – es bleibt dein Geld. |
| `cash_book_change_float_negative_warning` | Du nimmst mehr zurück, als diesem Automaten vorgestreckt wurde. Wenn das kassiertes Geld ist, buche es als Entnahme. |
| `cash_book_for_machine` | Automat |
| `cash_book_total_change_float` | Wechselgeld vorgestreckt |

Format je Eintrag (analog zu den bestehenden):

```json
    "cash_book_record_change_float" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Wechselgeld buchen"
          }
        }
      }
    },
```

In `ios/VMflow/Views/CashBook/CashBookView.swift`:

State ergänzen:

```swift
    @State private var showChangeFloat = false
```

Neben dem bestehenden Ausgaben-Sheet einhängen:

```swift
        .sheet(isPresented: $showChangeFloat) {
            ChangeFloatSheet(cashBook: book)
        }
```

Im Menü, in dem `showExpense` gesetzt wird, einen Eintrag ergänzen:

```swift
            Button {
                showChangeFloat = true
            } label: {
                Label("cash_book_record_change_float", systemImage: "circle.grid.2x2")
            }
```

- [ ] **Step 4: Build und Simulator-Prüfung**

Run:

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`. Der Build führt `xcstringstool` aus — Syntaxfehler im String Catalog fallen hier auf.

Danach im Simulator: Kassenbuch öffnen, „Wechselgeld buchen", Automat wählen, 25 € einlegen. Erwartung: Kassenstand sinkt um 25 €, Eintrag erscheint in der Liste.

- [ ] **Step 5: Commit**

```bash
git add ios/VMflow/Views/CashBook/ChangeFloatSheet.swift ios/VMflow.xcodeproj/project.pbxproj ios/VMflow/Views/CashBook/CashBookView.swift ios/VMflow/Resources/Localizable.xcstrings
git commit -m "feat(ios): add change float booking sheet" -- ios/VMflow/Views/CashBook/ChangeFloatSheet.swift ios/VMflow.xcodeproj/project.pbxproj ios/VMflow/Views/CashBook/CashBookView.swift ios/VMflow/Resources/Localizable.xcstrings
```

---

### Task 11: iOS — Entnahme mit Tubenrücklage

**Files:**
- Modify: `ios/VMflow/Views/CashBook/WithdrawalSheet.swift`
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `recordWithdrawal(cashBookId:counted:expected:machineId:floatBack:description:floatDescription:)` (Task 9)
- Produces: keine neuen öffentlichen Symbole

- [ ] **Step 1: Übersetzungen ergänzen**

In `ios/VMflow/Resources/Localizable.xcstrings` drei weitere `de`-Einträge im selben Format wie in Task 10:

| Schlüssel | Wert |
|---|---|
| `cash_book_float_back` | Davon zurück in die Münztuben |
| `cash_book_float_back_hint` | Münzen, die du direkt wieder in die Tuben gefüllt hast. Die Entnahme wird trotzdem über den vollen gezählten Betrag gebucht. |
| `cash_book_net_to_box` | Netto in die Kasse |

- [ ] **Step 2: Sheet erweitern**

In `ios/VMflow/Views/CashBook/WithdrawalSheet.swift`:

State ergänzen (neben `countedText`):

```swift
    @State private var floatBackText: String = ""
```

Nach `difference` einfügen:

```swift
    /// Rücklage in die Münztuben (nicht-negativ; die RPC negiert intern).
    private var floatBack: Double {
        max(0, Double(floatBackText.replacingOccurrences(of: ",", with: ".")) ?? 0)
    }

    /// Was nach der Rücklage tatsächlich in der Kasse landet.
    private var netToBox: Double {
        counted - floatBack
    }

    /// Sobald eine Rücklage erfasst wird, ist der Automatenbezug zwingend —
    /// unabhängig von `trackPerMachine`, das nur den Erwartungswert verankert.
    private var machineRequired: Bool {
        floatBack > 0
    }

    private var canSubmit: Bool {
        counted > 0 && (!machineRequired || selectedMachineId != nil)
    }
```

Im `body` nach `countedSection` einfügen:

```swift
                floatBackSection
```

Die Bedingung des Automaten-Blocks (Zeile 76) ersetzen:

```swift
                if (cashBook.trackPerMachine || machineRequired) && !assignedMachines.isEmpty {
```

Den Submit-Button auf `.disabled(isSubmitting || !canSubmit)` ändern.

Nach `countedSection` als neue Section einfügen:

```swift
    @ViewBuilder
    private var floatBackSection: some View {
        Section {
            TextField("0,00", text: $floatBackText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())

            if floatBack > 0 {
                LabeledContent {
                    Text(netToBox, format: .currency(code: "EUR"))
                        .monospacedDigit()
                } label: {
                    Text("cash_book_net_to_box")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("cash_book_float_back")
        } footer: {
            Text("cash_book_float_back_hint")
        }
    }
```

`submit()` anpassen:

```swift
            try await cashBookVM.recordWithdrawal(
                cashBookId: cashBook.id,
                counted: evaluated,
                expected: expected,
                machineId: selectedMachineId,
                floatBack: floatBack,
                description: description,
                floatDescription: floatBack > 0
                    ? NSLocalizedString("cash_book_change_float_in", comment: "")
                    : nil
            )
```

Dafür einen weiteren `de`-Eintrag `cash_book_change_float_in` mit dem Wert `Wechselgeld in Automat` ergänzen.

Die Vorauswahl in `loadTheoretical()` (Zeile 291) entkoppeln, damit sie auch ohne `trackPerMachine` greift:

```swift
        if let tourMachineIds, selectedMachineId == nil {
```

- [ ] **Step 3: Build**

Run:

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Im Simulator prüfen**

Kassenbuch → Entnahme: gezählt 200, Rücklage 50, Automat wählen. Erwartung: „Netto in die Kasse 150,00 €"; nach dem Buchen zwei Einträge in der Liste, Kassenstand +150.

Gegenprobe: Rücklage leer lassen → eine Zeile, Verhalten wie vorher, Automatenwahl bleibt bei ausgeschaltetem `trackPerMachine` verborgen.

- [ ] **Step 5: Commit**

```bash
git add ios/VMflow/Views/CashBook/WithdrawalSheet.swift ios/VMflow/Resources/Localizable.xcstrings
git commit -m "feat(ios): record change float back to tubes during withdrawal" -- ios/VMflow/Views/CashBook/WithdrawalSheet.swift ios/VMflow/Resources/Localizable.xcstrings
```

---

### Task 12: iOS — Anzeige in Liste und Übersicht

**Files:**
- Modify: `ios/VMflow/Views/CashBook/EntriesListSection.swift`
- Modify: `ios/VMflow/Views/CashBook/FlowVisualisationCard.swift`
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `CashBookEntryType.changeFloat`, `cashBookVM.changeFloat` (Task 9)
- Produces: keine neuen öffentlichen Symbole

- [ ] **Step 1: Übersetzungen ergänzen**

Weitere `de`-Einträge in `Localizable.xcstrings`:

| Schlüssel | Wert |
|---|---|
| `cash_book_type_change_float` | Wechselgeld |
| `cash_book_change_float_station` | In Münztuben |
| `cash_book_change_float_empty` | Kein Wechselgeld vorgestreckt |

- [ ] **Step 2: Badge ergänzen**

In `ios/VMflow/Views/CashBook/EntriesListSection.swift` in `badgeStyle(for:)` vor `case .reversal:` einfügen:

```swift
        case .changeFloat: return ("cash_book_type_change_float", .purple)
```

- [ ] **Step 3: Bestandskarte ergänzen**

In `ios/VMflow/Views/CashBook/FlowVisualisationCard.swift` am Ende des `body`-Stacks — nach der letzten bestehenden Station — einfügen:

```swift
            // Wechselgeld ist eine Seitentasche der Kasse, kein Kettenglied.
            changeFloatSection
```

und als neue Computed Property in derselben Struct:

```swift
    @ViewBuilder
    private var changeFloatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("cash_book_change_float_station", systemImage: "circle.grid.2x2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(cashBookVM.changeFloat.reduce(0) { $0 + $1.floatBalance },
                     format: .currency(code: "EUR"))
                    .font(.headline.monospacedDigit())
            }

            if cashBookVM.changeFloat.isEmpty {
                Text("cash_book_change_float_empty")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(cashBookVM.changeFloat) { row in
                    HStack {
                        Text(row.machineName ?? "—")
                        Spacer()
                        Text(row.floatBalance, format: .currency(code: "EUR"))
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 8)
    }
```

Falls `FlowVisualisationCard` das ViewModel noch nicht hält, `@EnvironmentObject var cashBookVM: CashBookViewModel` ergänzen.

- [ ] **Step 4: Build und Simulator-Prüfung**

Run:

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

Im Simulator: Kassenbuch öffnen. Erwartung: violettes Badge „Wechselgeld" an den Einträgen aus Task 10/11, darunter der Block „In Münztuben" mit der Summe und einer Zeile je Automat.

- [ ] **Step 5: Commit**

```bash
git add ios/VMflow/Views/CashBook/EntriesListSection.swift ios/VMflow/Views/CashBook/FlowVisualisationCard.swift ios/VMflow/Resources/Localizable.xcstrings
git commit -m "feat(ios): show change float badge and per-machine balance" -- ios/VMflow/Views/CashBook/EntriesListSection.swift ios/VMflow/Views/CashBook/FlowVisualisationCard.swift ios/VMflow/Resources/Localizable.xcstrings
```

---

### Task 13: iOS — Rücklage im Refill-Assistenten verifizieren

**Reine Verifikations-Task, ohne erwartete Codeänderung.** Der Refill-Assistent
präsentiert `WithdrawalSheet` in `RefillSummaryView.swift:132` bereits mit
`fromTour: true` und `tourMachineIds: viewModel.visitedMachineIds`. Das
Rücklage-Feld und die entkoppelte Automaten-Vorauswahl aus Task 11 wirken
dadurch automatisch mit. Diese Task stellt sicher, dass das auch am laufenden
Gerät stimmt — die Tour ist der wichtigste Pfad für dieses Feature, und ein
stiller Regress dort würde erst im Feld auffallen.

**Files:**
- Verify (nicht ändern): `ios/VMflow/Views/Refill/RefillSummaryView.swift:131-138`

**Interfaces:**
- Consumes: `WithdrawalSheet` mit Rücklage-Feld (Task 11)
- Produces: keine neuen Symbole

- [ ] **Step 1: Aufrufstelle prüfen**

Run:

```bash
sed -n '131,138p' ios/VMflow/Views/Refill/RefillSummaryView.swift
```

Expected: der Aufruf enthält `fromTour: true` und `tourMachineIds: viewModel.visitedMachineIds`. Trifft das zu, ist keine Codeänderung nötig — weiter mit Step 2.

Trifft es **nicht** zu (weil eine parallele Session die Stelle verändert hat), beide Argumente ergänzen:

```swift
            WithdrawalSheet(
                cashBook: barkasse,
                fromTour: true,
                tourMachineIds: viewModel.visitedMachineIds
            )
            .environmentObject(cashBookVM)
```

- [ ] **Step 2: Tour im Simulator durchspielen**

App starten, eine Refill-Tour über genau einen Automaten einer Barkasse mit Barverkäufen abschließen, bis das Entnahme-Sheet automatisch erscheint.

Erwartung:
- Das Sheet zeigt den Abschnitt „Davon zurück in die Münztuben".
- Der besuchte Automat ist im Automaten-Picker vorausgewählt, **auch wenn die Barkasse `trackPerMachine = false` hat** — sobald eine Rücklage eingetragen wird, erscheint der Picker.
- Gezählt 120, Rücklage 30 eingeben → „Netto in die Kasse 90,00 €".
- Nach dem Buchen: zwei Kassenbucheinträge, Kassenstand +90, Block „In Münztuben" um 30 € höher.

- [ ] **Step 3: Gegenprobe ohne Rücklage**

Zweite Tour, Rücklage leer lassen. Erwartung: genau ein Eintrag, Kassenstand steigt um den vollen gezählten Betrag, „In Münztuben" unverändert. Damit ist belegt, dass der bestehende Tourpfad nicht regressiert ist.

- [ ] **Step 4: Ergebnis festhalten**

Ohne Codeänderung entfällt der Commit. Falls Step 1 doch eine Anpassung nötig machte:

```bash
git add ios/VMflow/Views/Refill/RefillSummaryView.swift
git commit -m "fix(ios): pass tour context to withdrawal sheet in refill summary" -- ios/VMflow/Views/Refill/RefillSummaryView.swift
```

---

## Abschlussprüfung

Nach Task 13 einmal die volle Kette laufen lassen:

```bash
Docker/supabase/tests/run-sql-tests.sh
```

```bash
cd management-frontend && npx vitest run
```

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Erwartung: alle SQL-Testdateien grün (insbesondere `get_theoretical_cash_per_machine.test.sql` — der Beweis, dass die bestehenden Zahlen unverschoben sind), Vitest grün, iOS-Build erfolgreich.
