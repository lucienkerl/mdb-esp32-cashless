-- =========================================================
-- Cash book: withdrawals can empty a SUBSET of a Barkasse's machines
--
-- Problem
-- -------
-- get_theoretical_cash (20260606000000_cash_book_per_machine_theoretical.sql)
-- anchors each machine at the most recent event that emptied it: the
-- 'initial' entry, or a non-reversed 'withdrawal' whose machine_id is
-- that machine OR IS NULL — where NULL means "emptied every machine of
-- the Barkasse".
--
-- A withdrawal row carries a single machine_id, so a refill tour that
-- empties machines A and B of a three-machine Barkasse {A, B, C} cannot
-- be expressed:
--   * machine_id = NULL would also advance C's anchor, silently
--     dropping C's uncollected cash out of the expected figure — a
--     genuine shortfall at C becomes undetectable.
--   * machine_id = A (naming just one) leaves B's anchor behind, so
--     B's already-collected cash gets counted again next time.
--
-- This is the feature's headline use case (partial tours), so it must
-- become expressible.
--
-- Fix
-- ---
-- 1. New nullable `emptied_machine_ids uuid[]` column on
--    cash_book_entries. NULL on every existing row (no default), so
--    existing rows keep today's exact anchor semantics unchanged. The
--    hash chain (before_insert_cash_book_entry, 20260407000000) only
--    covers entry_number/type/amount/balance_after/prev_hash — a new
--    column does not touch it.
--
-- 2. get_theoretical_cash: in the track_per_machine = true branch, a
--    withdrawal anchors machine M under the new precedence:
--      - non-null, non-empty emptied_machine_ids  → anchors M only if
--        M is IN that list (machine_id IS NULL is NOT also consulted —
--        otherwise the list would be pointless).
--      - NULL/empty emptied_machine_ids            → unchanged: anchors
--        M if machine_id IS NULL or machine_id = M.
--    Existing rows have a null array and therefore always take the
--    second branch, producing byte-identical results to before this
--    migration. The track_per_machine = false branch is untouched.
--
-- 3. record_cash_book_withdrawal gains a 9th parameter,
--    p_emptied_machine_ids uuid[] DEFAULT NULL:
--      - 2+ machines  → stored verbatim in emptied_machine_ids,
--        machine_id left NULL (the list is then authoritative).
--      - exactly 1 machine → today's representation: machine_id is set
--        to it, emptied_machine_ids stays NULL. Keeps the single-
--        machine case byte-identical and avoids two ways of saying the
--        same thing.
--      - NULL/empty → unchanged: machine_id = p_machine_id,
--        emptied_machine_ids NULL.
--    Every machine in the list is validated exactly like the existing
--    p_machine_id / p_floats machines (company ownership, and — unless
--    its cash_book_id is NULL — membership of THIS cash book),
--    duplicates are rejected, and all of this happens before any
--    INSERT. p_emptied_machine_ids together with a non-null
--    p_machine_id is rejected outright (one source of truth).
--
--    Every guard already in the deployed function (20260807000600) is
--    reproduced unchanged: authentication, cash-book company
--    ownership, counted >= 0, float >= 0, float-back-without-machine,
--    p_float_back/p_floats mutual exclusion, p_floats array-type check,
--    per-element p_floats pre-validation, and the p_machine_id
--    company/cash-book checks. The new list only replaces which value
--    ends up in the withdrawal row's own machine_id /
--    emptied_machine_ids columns — it does not touch the p_float_back /
--    p_floats change-float logic, which keeps using p_machine_id
--    exactly as before.
--
--    Signature identity: adding a 9th parameter WITH A DEFAULT to a
--    CREATE OR REPLACE does not replace the existing 8-parameter
--    function — Postgres keeps both, and every existing positional
--    call becomes ambiguous ("function ... is not unique"). This exact
--    trap already broke 20260807000500 once (see its own header) and
--    is why 20260807000600 had to DROP the old reverse_cash_book_entry
--    before recreating it. record_cash_book_withdrawal is therefore
--    dropped by its exact current 8-parameter signature first; DROP
--    FUNCTION discards all grants, so GRANT EXECUTE is re-issued below
--    for the new 9-parameter signature.
-- =========================================================

-- 1. New column. Nullable, no default — every existing row keeps its
--    current NULL, which is exactly the "behave like before" input to
--    both the read side (get_theoretical_cash) and the write side
--    (record_cash_book_withdrawal treats NULL/empty as "no list").
ALTER TABLE public.cash_book_entries
  ADD COLUMN IF NOT EXISTS emptied_machine_ids uuid[];


-- 2. get_theoretical_cash — same signature, CREATE OR REPLACE. Only the
--    anchor SELECT inside the track_per_machine = true branch changes;
--    everything else (including the whole track_per_machine = false
--    branch) is reproduced byte-for-byte from 20260606000000.
CREATE OR REPLACE FUNCTION public.get_theoretical_cash(
  p_cash_book_id uuid,
  p_company_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_company     uuid;
  v_last_balance     float8;
  v_last_entry_at    timestamptz;
  v_entry_count      integer;
  v_cash_sales       float8 := 0;
  v_machines         jsonb := '[]'::jsonb;
  v_machine          record;
  v_machine_sales    float8;
  v_track_per_machine boolean;
  v_anchor           timestamptz;
BEGIN
  -- Verify caller belongs to the company
  SELECT om.company_id INTO v_user_company
    FROM public.organization_members om
   WHERE om.user_id = auth.uid()
     AND om.company_id = p_company_id
   LIMIT 1;

  IF v_user_company IS NULL THEN
    RETURN NULL;
  END IF;

  -- Verify cash book belongs to company + read its per-machine toggle
  SELECT track_per_machine INTO v_track_per_machine
    FROM public.cash_books
   WHERE id = p_cash_book_id AND company_id = p_company_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Get latest entry (Barkasse-wide — drives the box balance + output fields)
  SELECT balance_after, created_at
    INTO v_last_balance, v_last_entry_at
    FROM public.cash_book_entries
   WHERE cash_book_id = p_cash_book_id
   ORDER BY entry_number DESC
   LIMIT 1;

  IF v_last_balance IS NULL THEN
    RETURN NULL;
  END IF;

  -- Count total entries
  SELECT count(*) INTO v_entry_count
    FROM public.cash_book_entries
   WHERE cash_book_id = p_cash_book_id;

  -- Sum cash sales per assigned machine since that machine's anchor
  FOR v_machine IN
    SELECT vm.id AS machine_id, vm.name AS machine_name
      FROM public."vendingMachine" vm
     WHERE vm.cash_book_id = p_cash_book_id
  LOOP
    IF v_track_per_machine THEN
      -- Most recent event that actually emptied THIS machine.
      --
      -- New precedence (this migration): if a withdrawal's
      -- emptied_machine_ids is non-null AND non-empty, it anchors this
      -- machine ONLY when the machine is IN that list — machine_id IS
      -- NULL is deliberately NOT also checked in that case, or the
      -- list would be meaningless. Existing rows always have a null
      -- array, so they fall into the ELSE branch and reproduce the
      -- pre-existing behaviour exactly (machine_id IS NULL empties
      -- every machine, machine_id = M empties just M).
      SELECT MAX(e.created_at)
        INTO v_anchor
        FROM public.cash_book_entries e
       WHERE e.cash_book_id = p_cash_book_id
         AND (
              e.type = 'initial'
           OR (e.type = 'withdrawal'
               AND e.is_reversed = false
               AND (
                 CASE
                   WHEN e.emptied_machine_ids IS NOT NULL
                        AND array_length(e.emptied_machine_ids, 1) > 0
                     THEN v_machine.machine_id = ANY(e.emptied_machine_ids)
                   ELSE (e.machine_id IS NULL OR e.machine_id = v_machine.machine_id)
                 END
               ))
         );
      -- Defensive: an 'initial' entry always exists, but never trust NULL.
      v_anchor := COALESCE(v_anchor, v_last_entry_at);
    ELSE
      -- Unchanged pre-2026-06-06 behaviour: Barkasse-wide last entry.
      v_anchor := v_last_entry_at;
    END IF;

    SELECT COALESCE(SUM(s.item_price), 0)
      INTO v_machine_sales
      FROM public.sales s
     WHERE s.machine_id = v_machine.machine_id
       AND s.channel = 'cash'
       AND s.created_at > v_anchor;

    v_cash_sales := v_cash_sales + v_machine_sales;

    v_machines := v_machines || jsonb_build_object(
      'machine_id', v_machine.machine_id,
      'machine_name', v_machine.machine_name,
      'cash_sales', v_machine_sales
    );
  END LOOP;

  RETURN jsonb_build_object(
    'theoretical_balance', v_last_balance + v_cash_sales,
    'last_entry_balance', v_last_balance,
    'cash_sales_since', v_cash_sales,
    'last_entry_at', v_last_entry_at,
    'entry_count', v_entry_count,
    'machines', v_machines
  );
END;
$$;


-- 3. record_cash_book_withdrawal — new 9th parameter. Old 8-parameter
--    signature must be dropped first (see header rationale).
DROP FUNCTION IF EXISTS public.record_cash_book_withdrawal(
  uuid, uuid, float8, float8, float8, text, text, jsonb
);

CREATE FUNCTION public.record_cash_book_withdrawal(
  p_cash_book_id         uuid,
  p_machine_id           uuid,
  p_counted              float8,
  p_expected             float8,
  p_float_back           float8 DEFAULT 0,
  p_description          text   DEFAULT NULL,
  p_float_description    text   DEFAULT NULL,
  p_floats               jsonb  DEFAULT NULL,
  p_emptied_machine_ids  uuid[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, extensions
AS $$
DECLARE
  v_company        uuid := public.my_company_id();
  v_user           uuid := auth.uid();
  v_float_back     float8 := COALESCE(p_float_back, 0);
  v_withdrawal_id  uuid;
  v_float_id       uuid;
  v_has_floats     boolean := false;
  v_elem           jsonb;
  v_elem_amount    float8;
  v_elem_machine   uuid;
  v_elem_desc      text;
  v_float_ids      uuid[] := '{}';
  v_multi_float_id uuid;
  -- New for the emptied-machines list. v_final_machine_id defaults to
  -- the existing p_machine_id (the unchanged path when no list is
  -- given) and is only overridden below for a single-machine list.
  v_has_emptied    boolean := false;
  v_final_machine_id  uuid := p_machine_id;
  v_final_emptied_ids uuid[] := NULL;
  v_em             uuid;
  v_seen_emptied   uuid[] := '{}';
  v_emptied_count  integer := 0;
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

  -- array_length() returns NULL (not 0) for an empty array, so this is
  -- wrapped in COALESCE to keep v_has_emptied a deterministic boolean —
  -- an empty p_emptied_machine_ids must behave exactly like NULL.
  v_has_emptied := COALESCE(
    p_emptied_machine_ids IS NOT NULL AND array_length(p_emptied_machine_ids, 1) > 0,
    false
  );

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

  -- p_machine_id und p_emptied_machine_ids schließen sich ebenso
  -- gegenseitig aus — es darf immer nur eine Quelle der Wahrheit dafür
  -- geben, welche(n) Automaten diese Entnahme geleert hat.
  IF v_has_emptied AND p_machine_id IS NOT NULL THEN
    RAISE EXCEPTION 'p_machine_id and p_emptied_machine_ids are mutually exclusive';
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

    -- Der Automat muss entweder gar keiner Barkasse zugeordnet sein
    -- (cash_book_id IS NULL — frisch angelegt oder bewusst
    -- unzugeordnet) oder genau dieser hier. Eine Zuordnung zu einer
    -- ANDEREN Barkasse derselben Firma wird abgewiesen.
    PERFORM 1 FROM public."vendingMachine"
     WHERE id = p_machine_id
       AND (cash_book_id IS NULL OR cash_book_id = p_cash_book_id);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'machine does not belong to this cash book';
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

      PERFORM 1 FROM public."vendingMachine"
       WHERE id = v_elem_machine
         AND (cash_book_id IS NULL OR cash_book_id = p_cash_book_id);
      IF NOT FOUND THEN
        RAISE EXCEPTION 'machine does not belong to this cash book';
      END IF;
    END LOOP;
  END IF;

  -- Vorabprüfung ALLER p_emptied_machine_ids-Elemente, bevor irgendetwas
  -- geschrieben wird — dieselbe Regel wie oben für p_machine_id /
  -- p_floats: Firmenzugehörigkeit, und (falls gesetzt) Bindung an genau
  -- diese Barkasse. Zusätzlich werden Duplikate abgewiesen, da eine
  -- Liste mit demselben Automaten zweimal keinen Sinn ergibt.
  IF v_has_emptied THEN
    FOREACH v_em IN ARRAY p_emptied_machine_ids
    LOOP
      IF v_em IS NULL THEN
        RAISE EXCEPTION 'emptied machine id must not be null';
      END IF;

      IF v_em = ANY(v_seen_emptied) THEN
        RAISE EXCEPTION 'duplicate machine in emptied machine list';
      END IF;
      v_seen_emptied := array_append(v_seen_emptied, v_em);

      PERFORM 1 FROM public."vendingMachine"
       WHERE id = v_em AND company = v_company;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'machine does not belong to this company';
      END IF;

      PERFORM 1 FROM public."vendingMachine"
       WHERE id = v_em
         AND (cash_book_id IS NULL OR cash_book_id = p_cash_book_id);
      IF NOT FOUND THEN
        RAISE EXCEPTION 'machine does not belong to this cash book';
      END IF;
    END LOOP;

    -- Genau ein Automat → heutige Darstellung (machine_id), damit der
    -- Einzelfall byte-identisch bleibt und es nicht zwei Arten gibt,
    -- dasselbe auszudrücken. Zwei oder mehr → die Liste ist maßgeblich,
    -- machine_id bleibt NULL.
    v_emptied_count := array_length(p_emptied_machine_ids, 1);
    IF v_emptied_count = 1 THEN
      v_final_machine_id := p_emptied_machine_ids[1];
    ELSE
      v_final_machine_id := NULL;
      v_final_emptied_ids := p_emptied_machine_ids;
    END IF;
  END IF;

  INSERT INTO public.cash_book_entries
    (cash_book_id, company_id, type, amount, description,
     machine_id, counted_amount, expected_amount, created_by,
     emptied_machine_ids)
  VALUES
    (p_cash_book_id, v_company, 'withdrawal', p_counted, p_description,
     v_final_machine_id, p_counted, p_expected, v_user,
     v_final_emptied_ids)
  RETURNING id INTO v_withdrawal_id;

  -- Change-float logic below is untouched by the emptied-machines list:
  -- it keeps using p_machine_id exactly as before. p_float_back already
  -- requires p_machine_id to be non-null, which the new mutual-
  -- exclusivity guard above guarantees is never true at the same time
  -- as a non-empty p_emptied_machine_ids.
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
  uuid, uuid, float8, float8, float8, text, text, jsonb, uuid[]
) TO authenticated;
