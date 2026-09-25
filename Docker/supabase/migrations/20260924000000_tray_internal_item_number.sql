-- Per-tray "internal tray number": the selection number a machine REPORTS for
-- a tray, when it differs from the number on the tray's label.
--
-- `machine_trays.item_number` is the labelled number — what the customer
-- presses and what the operator sees. Some VMCs report a different, internal
-- number over MDB (and as the PA1 id in their DEX audit), and not always by a
-- constant amount: rows of different widths numbered densely from 1 cannot be
-- described by the per-machine `vendingMachine.item_number_offset`
-- (20260827000000). `internal_item_number` records the reported number of one
-- tray; `mqtt-webhook` books a sale reported as N on the tray whose
-- internal_item_number is N. NULL (the default) means no mapping: the reported
-- number is used as-is, plus the machine offset. An explicit tray mapping wins
-- over the offset.
--
-- Same cut-over model as the offset: there is deliberately NO backfill, and
-- `internal_item_number_since` is stamped server-side whenever a tray's mapping
-- changes, so readers that compare reported numbers across time (Nayax
-- reconciliation, DEX gap maths) can decide per row.

ALTER TABLE public.machine_trays
  ADD COLUMN IF NOT EXISTS internal_item_number integer;

ALTER TABLE public.machine_trays
  ADD COLUMN IF NOT EXISTS internal_item_number_since timestamptz;

COMMENT ON COLUMN public.machine_trays.internal_item_number IS
  'Selection number the machine reports (MDB / DEX) for this tray, when it differs from item_number (the number on the label). NULL = no mapping: the reported number is used as-is (plus vendingMachine.item_number_offset).';
COMMENT ON COLUMN public.machine_trays.internal_item_number_since IS
  'Server-stamped moment the current internal_item_number took effect. NULL when there is no mapping. Data written before this timestamp was not mapped and must not be remapped retroactively.';

-- A selection number is a uint16 on the wire, and 0xFFFF is MDB's "item
-- unknown" sentinel, never a real selection.
ALTER TABLE public.machine_trays
  DROP CONSTRAINT IF EXISTS machine_trays_internal_item_number_range;
ALTER TABLE public.machine_trays
  ADD CONSTRAINT machine_trays_internal_item_number_range
  CHECK (internal_item_number BETWEEN 0 AND 65534);

-- One reported number can only lead to one tray of a machine.
CREATE UNIQUE INDEX IF NOT EXISTS machine_trays_machine_internal_item_number_key
  ON public.machine_trays (machine_id, internal_item_number)
  WHERE internal_item_number IS NOT NULL;

-- The cut-over timestamp is server-owned: whatever a client sends is ignored,
-- and it is restamped on every actual change of the mapping.
CREATE OR REPLACE FUNCTION public.stamp_tray_internal_item_number_since()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.internal_item_number_since :=
      CASE WHEN NEW.internal_item_number IS NOT NULL THEN now() ELSE NULL END;
    RETURN NEW;
  END IF;

  IF NEW.internal_item_number IS DISTINCT FROM OLD.internal_item_number THEN
    NEW.internal_item_number_since :=
      CASE WHEN NEW.internal_item_number IS NOT NULL THEN now() ELSE NULL END;
  ELSE
    -- Unchanged mapping: keep the original stamp regardless of what was sent.
    NEW.internal_item_number_since := OLD.internal_item_number_since;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS stamp_tray_internal_item_number_since ON public.machine_trays;
CREATE TRIGGER stamp_tray_internal_item_number_since
  BEFORE INSERT OR UPDATE ON public.machine_trays
  FOR EACH ROW EXECUTE FUNCTION public.stamp_tray_internal_item_number_since();

-- DEX gap maths: a tray mapping re-keys that tray's slot counter in every
-- snapshot taken after it was set, exactly like the offset does for all keys.
-- Extend the cut-over clamp introduced in 20260827000000 to the latest tray
-- mapping of the machine as well. Everything below the `cutover` CTE is
-- unchanged from that migration.
CREATE OR REPLACE FUNCTION public.dex_reconcile_gaps(
  p_embedded_id uuid,
  p_window_start timestamptz,
  p_window_end timestamptz
)
RETURNS TABLE (
  item_number integer,
  dex_delta   bigint,
  sales_count bigint,
  gap         bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  with cutover as (
    select max(c.since) as since
    from (
      select vm.item_number_offset_since as since
      from public."vendingMachine" vm
      where vm.embedded = p_embedded_id
        and vm.item_number_offset <> 0
      union all
      select mt.internal_item_number_since
      from public.machine_trays mt
      join public."vendingMachine" vm on vm.id = mt.machine_id
      where vm.embedded = p_embedded_id
        and mt.internal_item_number is not null
    ) c
  ),
  bounds as (
    select
      greatest(p_window_start, coalesce((select since from cutover), p_window_start)) as w_start,
      p_window_end as w_end
  ),
  -- Which snapshot serves as the baseline. Normally the latest one at or before
  -- the window start. When the window opens before the cut-over there is no
  -- post-cut-over baseline that early, so fall back to the FIRST snapshot taken
  -- after it — otherwise the guard would silently return nothing at all for
  -- every machine that has an offset.
  eff_start_at as (
    select coalesce(
      (
        select max(d.captured_at)
        from public.dex_snapshots d, bounds b
        where d.embedded_id = p_embedded_id
          and d.captured_at <= b.w_start
          and (
            (select since from cutover) is null
            or d.captured_at >= (select since from cutover)
          )
      ),
      (
        select min(d.captured_at)
        from public.dex_snapshots d
        where d.embedded_id = p_embedded_id
          and (select since from cutover) is not null
          and d.captured_at >= (select since from cutover)
      )
    ) as at
  ),
  start_snap as (
    select d.slot_counters
    from public.dex_snapshots d, eff_start_at e
    where d.embedded_id = p_embedded_id
      and d.captured_at = e.at
    limit 1
  ),
  end_snap as (
    select d.slot_counters
    from public.dex_snapshots d, bounds b
    where d.embedded_id = p_embedded_id
      and d.captured_at <= b.w_end
      and (
        (select since from cutover) is null
        or d.captured_at >= (select since from cutover)
      )
    order by d.captured_at desc
    limit 1
  ),
  slot_deltas as (
    select
      (key)::integer as item_number,
      coalesce(((end_snap.slot_counters -> key) ->> 'vends')::bigint, 0)
        - coalesce(((start_snap.slot_counters -> key) ->> 'vends')::bigint, 0) as dex_delta
    from end_snap
    cross join start_snap
    cross join jsonb_object_keys(end_snap.slot_counters) as key
  ),
  sales_counts as (
    select s.item_number, count(*)::bigint as sales_count
    from public.sales s, bounds b
    where s.embedded_id = p_embedded_id
      and s.created_at >= b.w_start
      and s.created_at <  b.w_end
    group by s.item_number
  )
  select
    d.item_number,
    d.dex_delta,
    coalesce(c.sales_count, 0) as sales_count,
    d.dex_delta - coalesce(c.sales_count, 0) as gap
  from slot_deltas d
  left join sales_counts c on c.item_number = d.item_number
  where d.dex_delta - coalesce(c.sales_count, 0) > 0
  order by gap desc;
$$;

COMMENT ON FUNCTION public.dex_reconcile_gaps(uuid, timestamptz, timestamptz) IS
  'Slots whose DEX vend counters grew by more than the recorded sales in the window. When the machine has an item_number_offset or a tray with an internal_item_number, the window is clamped to the latest cut-over so raw and remapped snapshot keys are never compared.';
