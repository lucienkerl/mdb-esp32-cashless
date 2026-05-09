-- Docker/supabase/migrations/20260509000000_analytics_stockout_events.sql
-- Adds tray_stockout_events table with trigger-managed lifecycle for analytics.
-- Open: machine_trays.current_stock crosses positive → 0 (INSERT event row)
-- Close: machine_trays.current_stock crosses 0 → positive (UPDATE event row,
--        compute lost_units / lost_revenue with a < 5 min duration clamp).
--
-- Helper get_product_velocity_one is internal-only (REVOKE PUBLIC).
-- Trigger named zzz_* so it sorts last alphabetically among future triggers
-- on machine_trays.current_stock.

-- ── Table ─────────────────────────────────────────────────────────────────────
CREATE TABLE public.tray_stockout_events (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tray_id                uuid NOT NULL REFERENCES public.machine_trays(id) ON DELETE CASCADE,
  machine_id             uuid NOT NULL REFERENCES public."vendingMachine"(id) ON DELETE CASCADE,
  item_number            bigint NOT NULL,
  product_id             uuid REFERENCES public.products(id) ON DELETE SET NULL,
  started_at             timestamptz NOT NULL,
  ended_at               timestamptz,
  duration_seconds       int GENERATED ALWAYS AS
    (EXTRACT(EPOCH FROM (ended_at - started_at))::int) STORED,
  lost_units_estimated   numeric,
  lost_revenue_estimated numeric,
  velocity_at_close      numeric,
  company_id             uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  created_at             timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_stockouts_one_open_per_tray
  ON public.tray_stockout_events (tray_id) WHERE ended_at IS NULL;

CREATE INDEX idx_stockouts_company_started
  ON public.tray_stockout_events (company_id, started_at DESC);

ALTER TABLE public.tray_stockout_events ENABLE ROW LEVEL SECURITY;

-- SELECT-only for authenticated users; INSERT/UPDATE/DELETE only via SECURITY DEFINER
-- trigger context (which bypasses RLS as function owner).
CREATE POLICY tray_stockout_events_select ON public.tray_stockout_events
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

GRANT SELECT ON public.tray_stockout_events TO authenticated;
GRANT ALL    ON public.tray_stockout_events TO service_role;

-- ── Helper: per-product daily velocity ───────────────────────────────────────
-- Internal-only: revoked from PUBLIC to prevent cross-company velocity probe
-- via PostgREST. The trigger calls it from its own SECURITY DEFINER context.

CREATE OR REPLACE FUNCTION public.get_product_velocity_one(
  p_company_id uuid, p_product_id uuid, p_days int
) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT COALESCE(COUNT(*) / NULLIF(p_days::numeric, 0), 0)
  FROM public.sales s
  JOIN public."vendingMachine" vm ON vm.id = s.machine_id
  WHERE vm.company = p_company_id
    AND s.product_id = p_product_id
    AND s.created_at >= now() - (p_days || ' days')::interval;
$$;

REVOKE ALL ON FUNCTION public.get_product_velocity_one(uuid, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_product_velocity_one(uuid, uuid, int) TO service_role;

-- ── Trigger function: open / close stockout events with 5-min clamp ──────────
-- < 5 min duration zeros out lost_units/lost_revenue (admin miscount-correction
-- noise — real outages last hours).

CREATE OR REPLACE FUNCTION public.handle_tray_stockout_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_company_id  uuid;
  v_velocity    numeric;
  v_sellprice   numeric;
BEGIN
  SELECT vm.company INTO v_company_id
  FROM public."vendingMachine" vm WHERE vm.id = NEW.machine_id;
  IF v_company_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Open: stock crossed positive → 0
  IF OLD.current_stock > 0 AND NEW.current_stock = 0 THEN
    INSERT INTO public.tray_stockout_events
      (tray_id, machine_id, item_number, product_id, started_at, company_id)
    VALUES
      (NEW.id, NEW.machine_id, NEW.item_number, NEW.product_id, now(), v_company_id)
    ON CONFLICT DO NOTHING;
    RETURN NEW;
  END IF;

  -- Close: stock crossed 0 → positive
  IF OLD.current_stock = 0 AND NEW.current_stock > 0 THEN
    SELECT public.get_product_velocity_one(v_company_id, NEW.product_id, 30)
      INTO v_velocity;
    SELECT sellprice INTO v_sellprice
      FROM public.products WHERE id = NEW.product_id;

    -- Single UPDATE; reads started_at from the row inside the CASE expressions.
    -- Zero rows updated when no open event existed (e.g. stockout at migration
    -- time, data fix) → no-op, fine.
    UPDATE public.tray_stockout_events
    SET ended_at              = now(),
        velocity_at_close     = v_velocity,
        lost_units_estimated  = CASE
          WHEN EXTRACT(EPOCH FROM (now() - started_at)) < 300 THEN 0
          ELSE ROUND(COALESCE(v_velocity, 0)
                     * EXTRACT(EPOCH FROM (now() - started_at)) / 86400.0, 2)
        END,
        lost_revenue_estimated = CASE
          WHEN EXTRACT(EPOCH FROM (now() - started_at)) < 300 THEN 0
          ELSE ROUND(COALESCE(v_velocity, 0)
                     * EXTRACT(EPOCH FROM (now() - started_at)) / 86400.0
                     * COALESCE(v_sellprice, 0), 2)
        END
    WHERE tray_id = NEW.id AND ended_at IS NULL;
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_tray_stockout_event() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.handle_tray_stockout_event() TO service_role;

-- ── Trigger ──────────────────────────────────────────────────────────────────
-- DROP IF EXISTS for idempotency (project convention per CLAUDE.md migration notes).
DROP TRIGGER IF EXISTS zzz_tray_stockout_event ON public.machine_trays;
CREATE TRIGGER zzz_tray_stockout_event
  AFTER UPDATE OF current_stock ON public.machine_trays
  FOR EACH ROW EXECUTE FUNCTION public.handle_tray_stockout_event();
