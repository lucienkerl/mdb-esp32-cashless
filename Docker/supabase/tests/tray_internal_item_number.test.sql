-- Per-tray internal_item_number: server-stamped cut-over, range + uniqueness,
-- and the DEX guard extended to tray mappings. Rolled back. Plain ASSERTs.
BEGIN;
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company  uuid := gen_random_uuid();
  v_admin    uuid := gen_random_uuid();
  v_dev      uuid := gen_random_uuid();
  v_dev2     uuid := gen_random_uuid();
  v_machine  uuid;
  v_machine2 uuid;
  v_tray     uuid;
  v_internal int;
  v_since    timestamptz;
  v_since2   timestamptz;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'Tray Map Co');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_admin, '00000000-0000-0000-0000-000000000000', 'traymap@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES (v_admin, v_company, 'traymap@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_admin, 'admin');
  INSERT INTO public.embeddeds (id, company, owner_id, status, status_at)
    VALUES (v_dev, v_company, v_admin, 'online', now()),
           (v_dev2, v_company, v_admin, 'online', now());
  INSERT INTO public."vendingMachine" (name, company, embedded)
    VALUES ('M-Map', v_company, v_dev) RETURNING id INTO v_machine;
  INSERT INTO public."vendingMachine" (name, company, embedded)
    VALUES ('M-Map-2', v_company, v_dev2) RETURNING id INTO v_machine2;

  -- 1. A tray created without a mapping has none, and no cut-over stamp.
  INSERT INTO public.machine_trays (machine_id, item_number)
    VALUES (v_machine, 25) RETURNING id INTO v_tray;
  SELECT internal_item_number, internal_item_number_since
    INTO v_internal, v_since FROM public.machine_trays WHERE id = v_tray;
  ASSERT v_internal IS NULL, 'default internal number must be NULL, got ' || v_internal;
  ASSERT v_since IS NULL, 'default cut-over must be NULL';

  -- 2. Setting a mapping stamps the cut-over server-side, ignoring whatever
  --    the client sent for the timestamp.
  UPDATE public.machine_trays
     SET internal_item_number = 3,
         internal_item_number_since = '1999-01-01T00:00:00Z'
   WHERE id = v_tray;
  SELECT internal_item_number_since INTO v_since
    FROM public.machine_trays WHERE id = v_tray;
  ASSERT v_since IS NOT NULL, 'cut-over must be stamped when a mapping is set';
  ASSERT v_since > now() - interval '1 minute',
    'cut-over must be server now(), got ' || v_since;

  -- 3. An update that leaves the mapping alone must NOT move the cut-over,
  --    not even when the client sends a timestamp.
  UPDATE public.machine_trays
     SET current_stock = 4,
         internal_item_number_since = '1999-01-01T00:00:00Z'
   WHERE id = v_tray;
  SELECT internal_item_number_since INTO v_since2
    FROM public.machine_trays WHERE id = v_tray;
  ASSERT v_since2 = v_since, 'unrelated update must not restamp the cut-over, got ' || v_since2;

  -- 4. Clearing the mapping clears the cut-over.
  UPDATE public.machine_trays SET internal_item_number = NULL WHERE id = v_tray;
  SELECT internal_item_number_since INTO v_since
    FROM public.machine_trays WHERE id = v_tray;
  ASSERT v_since IS NULL, 'clearing the mapping must clear the cut-over';

  -- 5. A tray created WITH a mapping is stamped on insert.
  INSERT INTO public.machine_trays (machine_id, item_number, internal_item_number, internal_item_number_since)
    VALUES (v_machine, 26, 4, '1999-01-01T00:00:00Z');
  SELECT internal_item_number_since INTO v_since
    FROM public.machine_trays WHERE machine_id = v_machine AND item_number = 26;
  ASSERT v_since > now() - interval '1 minute',
    'insert with a mapping must stamp server now(), got ' || v_since;

  -- 6. Out-of-range numbers are rejected; 0xFFFF is MDB's "unknown" sentinel.
  BEGIN
    UPDATE public.machine_trays SET internal_item_number = 65535 WHERE id = v_tray;
    ASSERT false, 'internal number 65535 should have violated the range check';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  BEGIN
    UPDATE public.machine_trays SET internal_item_number = -1 WHERE id = v_tray;
    ASSERT false, 'internal number -1 should have violated the range check';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- 7. One reported number maps to at most one tray per machine ...
  BEGIN
    UPDATE public.machine_trays SET internal_item_number = 4 WHERE id = v_tray;
    ASSERT false, 'two trays of one machine must not share internal number 4';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  -- ... while another machine may reuse it, and unmapped trays never collide.
  INSERT INTO public.machine_trays (machine_id, item_number, internal_item_number)
    VALUES (v_machine2, 26, 4);
  INSERT INTO public.machine_trays (machine_id, item_number)
    VALUES (v_machine, 27), (v_machine, 28);

  RAISE NOTICE 'tray_internal_item_number: column assertions passed';
END $$;

-- 8. DEX guard: once a tray is mapped, its counter lives under a different key.
--    Snapshots from before the mapping must not be compared with snapshots
--    taken after it.
DO $$
DECLARE
  v_company uuid := gen_random_uuid();
  v_admin   uuid := gen_random_uuid();
  v_dev     uuid := gen_random_uuid();
  v_machine uuid;
  v_since   timestamptz;
  v_gap     bigint;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'Tray Dex Co');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_admin, '00000000-0000-0000-0000-000000000000', 'traydex@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES (v_admin, v_company, 'traydex@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_admin, 'admin');
  INSERT INTO public.embeddeds (id, company, owner_id, status, status_at)
    VALUES (v_dev, v_company, v_admin, 'online', now());
  INSERT INTO public."vendingMachine" (name, company, embedded)
    VALUES ('M-Tray-Dex', v_company, v_dev) RETURNING id INTO v_machine;
  INSERT INTO public.machine_trays (machine_id, item_number, internal_item_number)
    VALUES (v_machine, 25, 3);

  SELECT internal_item_number_since INTO v_since
    FROM public.machine_trays WHERE machine_id = v_machine AND item_number = 25;

  -- Before the mapping the machine's own key "3" carried the lifetime counter.
  INSERT INTO public.dex_snapshots (embedded_id, raw, slot_counters, total_vends, total_value, captured_at)
    VALUES (v_dev, '\x00', '{"3": {"vends": 800, "value_cents": 80000}}'::jsonb,
            800, 80000, v_since - interval '2 hours');
  -- After it, the same counter is stored under the label "25", two vends apart.
  INSERT INTO public.dex_snapshots (embedded_id, raw, slot_counters, total_vends, total_value, captured_at)
    VALUES (v_dev, '\x00', '{"25": {"vends": 800, "value_cents": 80000}}'::jsonb,
            800, 80000, v_since + interval '1 minute');
  INSERT INTO public.dex_snapshots (embedded_id, raw, slot_counters, total_vends, total_value, captured_at)
    VALUES (v_dev, '\x00', '{"25": {"vends": 802, "value_cents": 80200}}'::jsonb,
            802, 80200, v_since + interval '2 hours');

  -- The window opens after the pre-mapping snapshot. Without the tray-mapping
  -- cut-over that snapshot would be the baseline, key "25" would be missing
  -- from it, and the whole lifetime counter (802) would come out as the gap.
  SELECT coalesce(max(gap), 0) INTO v_gap
  FROM public.dex_reconcile_gaps(v_dev, v_since - interval '1 hour', v_since + interval '3 hours');

  ASSERT v_gap = 2,
    'gap across the tray-mapping cut-over must be the real delta 2, got ' || v_gap;

  RAISE NOTICE 'tray_internal_item_number: dex guard assertions passed';
END $$;

ROLLBACK;
