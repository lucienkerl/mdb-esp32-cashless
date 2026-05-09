-- Docker/supabase/migrations/20260509000100_analytics_rpcs.sql
-- Six analytics RPCs serving Web + iOS analytics. Shared filter signature,
-- jsonb response with version: 1. SECURITY DEFINER, statement_timeout 10s.
-- Internal helper _analytics_filtered_sales applies the WHERE clause.

-- ── Helper: filtered sales subquery ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._analytics_filtered_sales(p_filters jsonb)
RETURNS SETOF public.sales
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT s.*
  FROM public.sales s
  JOIN public."vendingMachine" vm ON vm.id = s.machine_id
  LEFT JOIN public.products p ON p.id = s.product_id
  WHERE vm.company = (p_filters->>'company_id')::uuid
    AND s.created_at >= (p_filters->>'from')::timestamptz
    AND s.created_at < (p_filters->>'to')::timestamptz
    AND (
      (p_filters->'machine_ids') IS NULL
      OR jsonb_array_length(p_filters->'machine_ids') = 0
      OR s.machine_id = ANY (
        SELECT (jsonb_array_elements_text(p_filters->'machine_ids'))::uuid
      )
    )
    AND (
      (p_filters->'channels') IS NULL
      OR jsonb_array_length(p_filters->'channels') = 0
      OR s.channel = ANY (
        SELECT jsonb_array_elements_text(p_filters->'channels')
      )
    )
    AND (
      (p_filters->'category_ids') IS NULL
      OR jsonb_array_length(p_filters->'category_ids') = 0
      OR p.category = ANY (
        SELECT (jsonb_array_elements_text(p_filters->'category_ids'))::uuid
      )
    )
    AND (
      (p_filters->'vat_rates') IS NULL
      OR jsonb_array_length(p_filters->'vat_rates') = 0
      OR (s.tax_rate_snapshot IS NOT NULL
          AND s.tax_rate_snapshot = ANY (
            SELECT (jsonb_array_elements_text(p_filters->'vat_rates'))::numeric
          ))
    );
$$;

REVOKE ALL ON FUNCTION public._analytics_filtered_sales(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._analytics_filtered_sales(jsonb) TO service_role;

-- Internal helper to build the filter jsonb consistently from the public-RPC
-- parameter list. Keeps every RPC's filter-construction call site identical.
CREATE OR REPLACE FUNCTION public._analytics_build_filters(
  p_company_id uuid, p_from timestamptz, p_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'company_id', p_company_id,
    'from',       p_from,
    'to',         p_to,
    'machine_ids', COALESCE(to_jsonb(p_machine_ids),  '[]'::jsonb),
    'channels',    COALESCE(to_jsonb(p_channels),     '[]'::jsonb),
    'category_ids',COALESCE(to_jsonb(p_category_ids), '[]'::jsonb),
    'vat_rates',   COALESCE(to_jsonb(p_vat_rates),    '[]'::jsonb)
  );
$$;

-- ── Common entry-guard ───────────────────────────────────────────────────────
-- Each RPC validates p_company_id matches the caller's company; raises on
-- mismatch with a deterministic SQLSTATE so cross-company tests can detect it.

-- ── analytics_overview ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_overview(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters       jsonb;
  v_filters_cmp   jsonb;
  v_kpis          jsonb;
  v_kpis_cmp      jsonb;
  v_daily_series  jsonb;
  v_top_products  jsonb;
  v_top_machines  jsonb;
  v_pax_count     bigint;
  v_pax_count_cmp bigint;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch or no company';
  END IF;

  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to,
    p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  -- Pax counts mirror the same machine/time filter (channels/categories don't apply)
  SELECT COALESCE(SUM(p.count), 0) INTO v_pax_count
  FROM public.paxcounter p
  JOIN public."vendingMachine" vm ON vm.id = p.machine_id
  WHERE vm.company = p_company_id
    AND p.created_at >= p_from AND p.created_at < p_to
    AND (
      cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0
      OR p.machine_id = ANY (p_machine_ids)
    );

  -- KPIs current period
  SELECT jsonb_build_object(
    'revenue',        ROUND(COALESCE(SUM(item_price), 0)::numeric, 2),
    'units',          COUNT(*),
    'avg_basket',     ROUND(COALESCE(SUM(item_price) / NULLIF(COUNT(*), 0), 0)::numeric, 2),
    'conversion_pct', ROUND((COUNT(*) * 100.0 / NULLIF(v_pax_count, 0))::numeric, 2)
  )
  INTO v_kpis
  FROM public._analytics_filtered_sales(v_filters);

  -- KPIs comparison period (if provided)
  IF p_compare_from IS NOT NULL AND p_compare_to IS NOT NULL THEN
    v_filters_cmp := public._analytics_build_filters(
      p_company_id, p_compare_from, p_compare_to,
      p_machine_ids, p_channels, p_category_ids, p_vat_rates
    );

    SELECT COALESCE(SUM(p.count), 0) INTO v_pax_count_cmp
    FROM public.paxcounter p
    JOIN public."vendingMachine" vm ON vm.id = p.machine_id
    WHERE vm.company = p_company_id
      AND p.created_at >= p_compare_from AND p.created_at < p_compare_to;

    SELECT jsonb_build_object(
      'revenue',        ROUND(COALESCE(SUM(item_price), 0)::numeric, 2),
      'units',          COUNT(*),
      'avg_basket',     ROUND(COALESCE(SUM(item_price) / NULLIF(COUNT(*), 0), 0)::numeric, 2),
      'conversion_pct', ROUND((COUNT(*) * 100.0 / NULLIF(v_pax_count_cmp, 0))::numeric, 2)
    )
    INTO v_kpis_cmp
    FROM public._analytics_filtered_sales(v_filters_cmp);
  ELSE
    v_kpis_cmp := NULL;
  END IF;

  -- Daily series
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date',    d.date,
    'revenue', d.rev,
    'units',   d.cnt
  ) ORDER BY d.date), '[]'::jsonb)
  INTO v_daily_series
  FROM (
    SELECT date_trunc('day', created_at)::date AS date,
           ROUND(SUM(item_price)::numeric, 2)  AS rev,
           COUNT(*)                            AS cnt
    FROM public._analytics_filtered_sales(v_filters)
    GROUP BY 1
  ) d;

  -- Top 5 products
  SELECT COALESCE(jsonb_agg(row ORDER BY (row->>'revenue')::numeric DESC), '[]'::jsonb)
  INTO v_top_products
  FROM (
    SELECT jsonb_build_object(
      'product_id', p.id,
      'name',       p.name,
      'image_path', p.image_path,
      'units',      COUNT(*),
      'revenue',    ROUND(SUM(s.item_price)::numeric, 2),
      'mix_pct',    ROUND((SUM(s.item_price) * 100.0 / NULLIF(
                      (SELECT SUM(item_price) FROM public._analytics_filtered_sales(v_filters)),
                      0))::numeric, 2)
    ) AS row
    FROM public._analytics_filtered_sales(v_filters) s
    JOIN public.products p ON p.id = s.product_id
    GROUP BY p.id, p.name, p.image_path
    ORDER BY SUM(s.item_price) DESC
    LIMIT 5
  ) sub;

  -- Top 5 machines
  SELECT COALESCE(jsonb_agg(row ORDER BY (row->>'revenue')::numeric DESC), '[]'::jsonb)
  INTO v_top_machines
  FROM (
    SELECT jsonb_build_object(
      'machine_id',     vm.id,
      'name',           vm.name,
      'status',         e.status,
      'revenue',        ROUND(SUM(s.item_price)::numeric, 2),
      'conversion_pct', NULL  -- per-machine pax→sales lives in analytics_machines/conversion
    ) AS row
    FROM public._analytics_filtered_sales(v_filters) s
    JOIN public."vendingMachine" vm ON vm.id = s.machine_id
    LEFT JOIN public.embeddeds e ON e.id = vm.embedded
    GROUP BY vm.id, vm.name, e.status
    ORDER BY SUM(s.item_price) DESC
    LIMIT 5
  ) sub;

  RETURN jsonb_build_object(
    'version',       1,
    'kpis',          v_kpis,
    'kpis_compare',  v_kpis_cmp,
    'daily_series',  v_daily_series,
    'top_products',  v_top_products,
    'top_machines',  v_top_machines
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_overview(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_overview(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;

-- ── analytics_sales_breakdown ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_sales_breakdown(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[],
  p_dimension text
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters jsonb;
  v_total_revenue numeric;
  v_total_units bigint;
  v_rows jsonb;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;
  IF p_dimension NOT IN ('machine','product','category','channel','vat','hour','dow') THEN
    RAISE EXCEPTION 'analytics_sales_breakdown: invalid dimension %', p_dimension;
  END IF;

  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to,
    p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  -- Filtered totals (denominator for share_*_pct)
  SELECT COALESCE(SUM(item_price), 0), COUNT(*)
  INTO v_total_revenue, v_total_units
  FROM public._analytics_filtered_sales(v_filters);

  -- Build rows depending on dimension. Each branch wraps the per-group
  -- aggregation in a subquery so jsonb_agg sees plain rows (Postgres rejects
  -- "aggregate function calls cannot be nested" when SUM/COUNT live inside
  -- jsonb_agg's argument with a same-level GROUP BY).
  IF p_dimension = 'machine' THEN
    SELECT COALESCE(jsonb_agg(row), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'key',                vm.id,
        'label',              vm.name,
        'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
        'units',              COUNT(*),
        'avg_basket',         ROUND((SUM(s.item_price) / NULLIF(COUNT(*), 0))::numeric, 2),
        'count',              COUNT(*),
        'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
        'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
      ) AS row
      FROM public._analytics_filtered_sales(v_filters) s
      JOIN public."vendingMachine" vm ON vm.id = s.machine_id
      GROUP BY vm.id, vm.name
      ORDER BY SUM(s.item_price) DESC
    ) sub;
  ELSIF p_dimension = 'product' THEN
    SELECT COALESCE(jsonb_agg(row), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'key',                p.id,
        'label',              p.name,
        'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
        'units',              COUNT(*),
        'avg_basket',         ROUND((SUM(s.item_price) / NULLIF(COUNT(*), 0))::numeric, 2),
        'count',              COUNT(*),
        'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
        'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
      ) AS row
      FROM public._analytics_filtered_sales(v_filters) s
      LEFT JOIN public.products p ON p.id = s.product_id
      GROUP BY p.id, p.name
      ORDER BY SUM(s.item_price) DESC
    ) sub;
  ELSIF p_dimension = 'category' THEN
    SELECT COALESCE(jsonb_agg(row), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'key',                c.id,
        'label',              c.name,
        'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
        'units',              COUNT(*),
        'avg_basket',         ROUND((SUM(s.item_price) / NULLIF(COUNT(*), 0))::numeric, 2),
        'count',              COUNT(*),
        'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
        'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
      ) AS row
      FROM public._analytics_filtered_sales(v_filters) s
      LEFT JOIN public.products p ON p.id = s.product_id
      LEFT JOIN public.product_category c ON c.id = p.category
      GROUP BY c.id, c.name
      ORDER BY SUM(s.item_price) DESC
    ) sub;
  ELSIF p_dimension = 'channel' THEN
    SELECT COALESCE(jsonb_agg(row), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'key',                s.channel,
        'label',              s.channel,
        'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
        'units',              COUNT(*),
        'avg_basket',         ROUND((SUM(s.item_price) / NULLIF(COUNT(*), 0))::numeric, 2),
        'count',              COUNT(*),
        'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
        'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
      ) AS row
      FROM public._analytics_filtered_sales(v_filters) s
      GROUP BY s.channel
      ORDER BY SUM(s.item_price) DESC
    ) sub;
  ELSIF p_dimension = 'vat' THEN
    SELECT COALESCE(jsonb_agg(row), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'key',                s.tax_rate_snapshot::text,
        'label',              ROUND(s.tax_rate_snapshot * 100, 2)::text || '%',
        'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
        'units',              COUNT(*),
        'avg_basket',         ROUND((SUM(s.item_price) / NULLIF(COUNT(*), 0))::numeric, 2),
        'count',              COUNT(*),
        'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
        'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
      ) AS row
      FROM public._analytics_filtered_sales(v_filters) s
      WHERE s.tax_rate_snapshot IS NOT NULL
      GROUP BY s.tax_rate_snapshot
      ORDER BY s.tax_rate_snapshot
    ) sub;
  ELSIF p_dimension = 'hour' THEN
    SELECT COALESCE(jsonb_agg(row), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'key',                EXTRACT(HOUR FROM s.created_at)::int,
        'label',              LPAD(EXTRACT(HOUR FROM s.created_at)::text, 2, '0') || ':00',
        'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
        'units',              COUNT(*),
        'avg_basket',         ROUND((SUM(s.item_price) / NULLIF(COUNT(*), 0))::numeric, 2),
        'count',              COUNT(*),
        'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
        'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
      ) AS row
      FROM public._analytics_filtered_sales(v_filters) s
      GROUP BY EXTRACT(HOUR FROM s.created_at)
      ORDER BY EXTRACT(HOUR FROM s.created_at)
    ) sub;
  ELSIF p_dimension = 'dow' THEN
    SELECT COALESCE(jsonb_agg(row), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'key',                EXTRACT(ISODOW FROM s.created_at)::int,
        'label',              to_char(MIN(s.created_at), 'Dy'),
        'revenue',            ROUND(SUM(s.item_price)::numeric, 2),
        'units',              COUNT(*),
        'avg_basket',         ROUND((SUM(s.item_price) / NULLIF(COUNT(*), 0))::numeric, 2),
        'count',              COUNT(*),
        'share_revenue_pct',  ROUND((SUM(s.item_price) * 100.0 / NULLIF(v_total_revenue, 0))::numeric, 2),
        'share_units_pct',    ROUND((COUNT(*) * 100.0 / NULLIF(v_total_units, 0))::numeric, 2)
      ) AS row
      FROM public._analytics_filtered_sales(v_filters) s
      GROUP BY EXTRACT(ISODOW FROM s.created_at)
      ORDER BY EXTRACT(ISODOW FROM s.created_at)
    ) sub;
  END IF;

  RETURN jsonb_build_object(
    'version',   1,
    'dimension', p_dimension,
    'rows',      v_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_sales_breakdown(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_sales_breakdown(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[], text) TO authenticated;

-- ── analytics_products ───────────────────────────────────────────────────────
-- Returns per-product velocity, revenue, mix-share, status (active/slow/dead/discontinued).
-- Uses get_product_sales_velocity (existing) for batch velocity, computes per-product
-- "last sold at" timestamp for slow-mover classification (no sale in 30 days = slow).

CREATE OR REPLACE FUNCTION public.analytics_products(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters     jsonb;
  v_total_rev   numeric;
  v_kpis        jsonb;
  v_products    jsonb;
  v_mix_shift   jsonb;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;

  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to, p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  SELECT COALESCE(SUM(item_price), 0) INTO v_total_rev
  FROM public._analytics_filtered_sales(v_filters);

  SELECT jsonb_build_object(
    'active_count',         (SELECT COUNT(*) FROM public.products WHERE company = p_company_id AND COALESCE(discontinued, false) = false),
    'slow_mover_count',     (
      SELECT COUNT(*) FROM public.products p
      WHERE p.company = p_company_id
        AND COALESCE(p.discontinued, false) = false
        AND NOT EXISTS (
          SELECT 1 FROM public.sales s
          JOIN public."vendingMachine" vm ON vm.id = s.machine_id
          WHERE vm.company = p_company_id
            AND s.product_id = p.id
            AND s.created_at >= now() - interval '30 days'
        )
    ),
    'discontinued_count',   (SELECT COUNT(*) FROM public.products WHERE company = p_company_id AND discontinued = true),
    'categories_with_sales',(
      SELECT COUNT(DISTINCT p.category)
      FROM public._analytics_filtered_sales(v_filters) s
      JOIN public.products p ON p.id = s.product_id
      WHERE p.category IS NOT NULL
    )
  ) INTO v_kpis;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',              p.id,
    'name',            p.name,
    'image_path',      p.image_path,
    'category_id',     p.category,           -- alias intentional (see plan header)
    'velocity',        ROUND(COALESCE(stats.units::numeric / NULLIF(EXTRACT(EPOCH FROM (p_to - p_from))/86400.0, 0), 0), 3),
    'units',           COALESCE(stats.units, 0),
    'revenue',         ROUND(COALESCE(stats.revenue, 0)::numeric, 2),
    'mix_pct',         ROUND((COALESCE(stats.revenue, 0) * 100.0 / NULLIF(v_total_rev, 0))::numeric, 2),
    'vat_rate',        stats.vat_rate,
    'last_sold_at',    stats.last_sold_at,
    'status',          CASE
      WHEN COALESCE(p.discontinued, false) THEN 'discontinued'
      WHEN stats.units IS NULL OR stats.units = 0 THEN 'dead'
      WHEN stats.last_sold_at < now() - interval '30 days' THEN 'slow'
      ELSE 'active'
    END,
    'slow_mover_days', GREATEST(0, EXTRACT(DAY FROM (now() - COALESCE(stats.last_sold_at, p.created_at)))::int)
  ) ORDER BY COALESCE(stats.revenue, 0) DESC), '[]'::jsonb)
  INTO v_products
  FROM public.products p
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS units,
           SUM(s.item_price) AS revenue,
           MAX(s.created_at) AS last_sold_at,
           AVG(s.tax_rate_snapshot)::numeric(6,4) AS vat_rate
    FROM public._analytics_filtered_sales(v_filters) s
    WHERE s.product_id = p.id
  ) stats ON true
  WHERE p.company = p_company_id;

  -- Mix-shift series: daily revenue per category over the period
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date',        d.date,
    'category_id', d.category_id,
    'revenue',     d.rev
  ) ORDER BY d.date, d.category_id), '[]'::jsonb)
  INTO v_mix_shift
  FROM (
    SELECT date_trunc('day', s.created_at)::date AS date,
           p.category AS category_id,
           ROUND(SUM(s.item_price)::numeric, 2) AS rev
    FROM public._analytics_filtered_sales(v_filters) s
    LEFT JOIN public.products p ON p.id = s.product_id
    GROUP BY 1, 2
  ) d;

  RETURN jsonb_build_object(
    'version',          1,
    'kpis',             v_kpis,
    'products',         v_products,
    'mix_shift_series', v_mix_shift
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_products(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_products(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;

-- ── analytics_machines ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_machines(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters    jsonb;
  v_kpis       jsonb;
  v_machines   jsonb;
  v_heatmaps   jsonb;
  v_stockout_h numeric;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;
  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to, p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  SELECT COALESCE(SUM(duration_seconds), 0) / 3600.0 INTO v_stockout_h
  FROM public.tray_stockout_events
  WHERE company_id = p_company_id
    AND started_at >= p_from AND started_at < p_to
    AND ended_at IS NOT NULL;

  WITH per_machine AS (
    SELECT vm.id, vm.name, vm.location_lat AS lat, vm.location_lon AS lng, e.status, e.online_since,
           COALESCE(SUM(s.item_price), 0) AS revenue,
           COUNT(s.id) AS units,
           MAX(s.created_at) AS last_sold_at
    FROM public."vendingMachine" vm
    LEFT JOIN public.embeddeds e ON e.id = vm.embedded
    LEFT JOIN public._analytics_filtered_sales(v_filters) s ON s.machine_id = vm.id
    WHERE vm.company = p_company_id
      AND (cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0 OR vm.id = ANY (p_machine_ids))
    GROUP BY vm.id, vm.name, vm.location_lat, vm.location_lon, e.status, e.online_since
  ),
  pax_per_machine AS (
    SELECT p.machine_id,
           COALESCE(SUM(p.count), 0) AS pax_count
    FROM public.paxcounter p
    JOIN public."vendingMachine" vm ON vm.id = p.machine_id
    WHERE vm.company = p_company_id
      AND p.created_at >= p_from AND p.created_at < p_to
    GROUP BY p.machine_id
  )
  SELECT jsonb_build_object(
    'active_count',       (SELECT COUNT(*) FROM per_machine),
    'best_machine_id',    (SELECT id FROM per_machine ORDER BY revenue DESC LIMIT 1),
    'best_machine_name',  (SELECT name FROM per_machine ORDER BY revenue DESC LIMIT 1),
    'best_revenue',       (SELECT ROUND(revenue::numeric, 2) FROM per_machine ORDER BY revenue DESC LIMIT 1),
    'avg_conversion_pct', (SELECT ROUND(AVG(
                              CASE WHEN COALESCE(pp.pax_count, 0) > 0
                                THEN pm.units * 100.0 / pp.pax_count
                                ELSE NULL END
                            )::numeric, 2)
                          FROM per_machine pm LEFT JOIN pax_per_machine pp ON pp.machine_id = pm.id),
    'total_stockout_hours', ROUND(v_stockout_h::numeric, 2)
  ) INTO v_kpis
  FROM (SELECT 1) _; -- dummy to allow CTEs

  -- machines[]
  WITH per_machine AS (
    SELECT vm.id, vm.name, vm.location_lat AS lat, vm.location_lon AS lng, e.status, e.online_since,
           COALESCE(SUM(s.item_price), 0) AS revenue,
           COUNT(s.id) AS units,
           MAX(s.created_at) AS last_sold_at
    FROM public."vendingMachine" vm
    LEFT JOIN public.embeddeds e ON e.id = vm.embedded
    LEFT JOIN public._analytics_filtered_sales(v_filters) s ON s.machine_id = vm.id
    WHERE vm.company = p_company_id
      AND (cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0 OR vm.id = ANY (p_machine_ids))
    GROUP BY vm.id, vm.name, vm.location_lat, vm.location_lon, e.status, e.online_since
  ),
  pax_per_machine AS (
    SELECT p.machine_id, COALESCE(SUM(p.count), 0) AS pax_count
    FROM public.paxcounter p
    JOIN public."vendingMachine" vm ON vm.id = p.machine_id
    WHERE vm.company = p_company_id
      AND p.created_at >= p_from AND p.created_at < p_to
    GROUP BY p.machine_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                   pm.id,
    'name',                 pm.name,
    'lat',                  pm.lat,
    'lng',                  pm.lng,
    'status',               pm.status,
    'revenue',              ROUND(pm.revenue::numeric, 2),
    'units',                pm.units,
    'conversion_pct',       CASE WHEN COALESCE(pp.pax_count, 0) > 0
                              THEN ROUND((pm.units * 100.0 / pp.pax_count)::numeric, 2)
                              ELSE NULL END,
    'last_sale_gap_minutes', CASE WHEN pm.last_sold_at IS NOT NULL
                              THEN EXTRACT(EPOCH FROM (now() - pm.last_sold_at))::int / 60
                              ELSE NULL END,
    'stock_health',         NULL,  -- computed client-side from machine_trays via existing component
    'current_online',       (pm.status IS NOT NULL AND pm.status <> 'offline')
  ) ORDER BY pm.revenue DESC), '[]'::jsonb)
  INTO v_machines
  FROM per_machine pm
  LEFT JOIN pax_per_machine pp ON pp.machine_id = pm.id;

  -- heatmaps: cells = sales count
  -- Pre-aggregate per (machine, dow) and (machine, hour) so the LEFT JOIN
  -- against the bucket-generators returns at most one row per bucket
  -- (otherwise array_agg would emit one element per matching cell, producing
  -- arrays longer than 7/24 when sales exist across multiple dows or hours).
  WITH cells AS (
    SELECT s.machine_id,
           EXTRACT(ISODOW FROM s.created_at)::int AS dow,    -- 1=Mon..7=Sun
           EXTRACT(HOUR   FROM s.created_at)::int AS hour,
           COUNT(*) AS cnt
    FROM public._analytics_filtered_sales(v_filters) s
    GROUP BY 1, 2, 3
  ),
  cells_dow AS (
    SELECT machine_id, dow, SUM(cnt) AS cnt FROM cells GROUP BY 1, 2
  ),
  cells_hour AS (
    SELECT machine_id, hour, SUM(cnt) AS cnt FROM cells GROUP BY 1, 2
  )
  SELECT COALESCE(jsonb_object_agg(
    machine_id::text,
    jsonb_build_object(
      'dow',  (SELECT array_agg(COALESCE(cd.cnt, 0) ORDER BY d) FROM generate_series(1,7) AS d LEFT JOIN cells_dow cd ON cd.machine_id = m.machine_id AND cd.dow = d),
      'hour', (SELECT array_agg(COALESCE(ch.cnt, 0) ORDER BY h) FROM generate_series(0,23) AS h LEFT JOIN cells_hour ch ON ch.machine_id = m.machine_id AND ch.hour = h)
    )
  ), '{}'::jsonb)
  INTO v_heatmaps
  FROM (SELECT DISTINCT machine_id FROM cells) m;

  RETURN jsonb_build_object(
    'version',  1,
    'kpis',     v_kpis,
    'machines', v_machines,
    'heatmaps', v_heatmaps
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_machines(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_machines(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;

-- ── analytics_conversion ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_conversion(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_filters       jsonb;
  v_kpis          jsonb;
  v_machines      jsonb;
  v_hour_heatmap  jsonb;
  v_daily_series  jsonb;
  v_total_pax     bigint;
  v_total_units   bigint;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;
  v_filters := public._analytics_build_filters(
    p_company_id, p_from, p_to, p_machine_ids, p_channels, p_category_ids, p_vat_rates
  );

  SELECT COALESCE(SUM(p.count), 0) INTO v_total_pax
  FROM public.paxcounter p
  JOIN public."vendingMachine" vm ON vm.id = p.machine_id
  WHERE vm.company = p_company_id
    AND p.created_at >= p_from AND p.created_at < p_to
    AND (cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0 OR p.machine_id = ANY (p_machine_ids));

  SELECT COUNT(*) INTO v_total_units
  FROM public._analytics_filtered_sales(v_filters);

  SELECT jsonb_build_object(
    'footfall',         v_total_pax,
    'conversion_pct',   ROUND((v_total_units * 100.0 / NULLIF(v_total_pax, 0))::numeric, 2),
    'best_machine_id',  (
      SELECT pm.id FROM (
        SELECT vm.id,
               (COUNT(s.id) * 100.0 / NULLIF(COALESCE(SUM(p.count), 0), 0)) AS conv
        FROM public."vendingMachine" vm
        LEFT JOIN public._analytics_filtered_sales(v_filters) s ON s.machine_id = vm.id
        LEFT JOIN public.paxcounter p ON p.machine_id = vm.id
          AND p.created_at >= p_from AND p.created_at < p_to
        WHERE vm.company = p_company_id
        GROUP BY vm.id
      ) pm
      ORDER BY conv DESC NULLS LAST LIMIT 1
    ),
    'empty_passes',     GREATEST(0, v_total_pax - v_total_units)
  ) INTO v_kpis;

  -- Per-machine conversion table
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                   vm.id,
    'name',                 vm.name,
    'pax',                  COALESCE(pp.pax_count, 0),
    'sales',                COALESCE(sp.unit_count, 0),
    'conversion_pct',       CASE WHEN COALESCE(pp.pax_count, 0) > 0
                              THEN ROUND((COALESCE(sp.unit_count, 0) * 100.0 / pp.pax_count)::numeric, 2)
                              ELSE 0 END,
    'revenue_per_visitor',  CASE WHEN COALESCE(pp.pax_count, 0) > 0
                              THEN ROUND((COALESCE(sp.revenue, 0) / pp.pax_count)::numeric, 2)
                              ELSE NULL END
  ) ORDER BY vm.name), '[]'::jsonb)
  INTO v_machines
  FROM public."vendingMachine" vm
  LEFT JOIN (
    SELECT s.machine_id, COUNT(*) AS unit_count, SUM(s.item_price) AS revenue
    FROM public._analytics_filtered_sales(v_filters) s
    GROUP BY s.machine_id
  ) sp ON sp.machine_id = vm.id
  LEFT JOIN (
    SELECT p.machine_id, SUM(p.count) AS pax_count
    FROM public.paxcounter p
    WHERE p.created_at >= p_from AND p.created_at < p_to
    GROUP BY p.machine_id
  ) pp ON pp.machine_id = vm.id
  WHERE vm.company = p_company_id
    AND (cardinality(COALESCE(p_machine_ids, '{}'::uuid[])) = 0 OR vm.id = ANY (p_machine_ids));

  -- hour_heatmap: machine_id → 24-element array of conversion_pct per hour
  WITH pax_h AS (
    SELECT p.machine_id, EXTRACT(HOUR FROM p.created_at)::int AS h, SUM(p.count) AS pax_count
    FROM public.paxcounter p JOIN public."vendingMachine" vm ON vm.id = p.machine_id
    WHERE vm.company = p_company_id AND p.created_at >= p_from AND p.created_at < p_to
    GROUP BY 1, 2
  ),
  sales_h AS (
    SELECT s.machine_id, EXTRACT(HOUR FROM s.created_at)::int AS h, COUNT(*) AS unit_count
    FROM public._analytics_filtered_sales(v_filters) s
    GROUP BY 1, 2
  )
  SELECT COALESCE(jsonb_object_agg(
    m.id::text,
    (SELECT array_agg(
       CASE WHEN COALESCE(ph.pax_count, 0) > 0
         THEN ROUND((COALESCE(sh.unit_count, 0) * 100.0 / ph.pax_count)::numeric, 2)
         ELSE NULL END
       ORDER BY hours.h
     )
     FROM (SELECT generate_series(0, 23) AS h) hours
     LEFT JOIN pax_h ph ON ph.machine_id = m.id AND ph.h = hours.h
     LEFT JOIN sales_h sh ON sh.machine_id = m.id AND sh.h = hours.h
    )
  ), '{}'::jsonb)
  INTO v_hour_heatmap
  FROM public."vendingMachine" m
  WHERE m.company = p_company_id;

  -- daily series
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date',           d.date,
    'conversion_pct', CASE WHEN COALESCE(d.pax, 0) > 0
                        THEN ROUND((d.units * 100.0 / d.pax)::numeric, 2)
                        ELSE NULL END
  ) ORDER BY d.date), '[]'::jsonb)
  INTO v_daily_series
  FROM (
    SELECT all_days.d AS date,
           COALESCE(SUM(p.count), 0) AS pax,
           COALESCE((SELECT COUNT(*) FROM public._analytics_filtered_sales(v_filters) s
                     WHERE date_trunc('day', s.created_at) = all_days.d), 0) AS units
    FROM (
      SELECT generate_series(date_trunc('day', p_from), date_trunc('day', p_to), interval '1 day')::date AS d
    ) all_days
    LEFT JOIN public.paxcounter p
      ON date_trunc('day', p.created_at)::date = all_days.d
    LEFT JOIN public."vendingMachine" vm ON vm.id = p.machine_id AND vm.company = p_company_id
    GROUP BY all_days.d
  ) d;

  RETURN jsonb_build_object(
    'version',                1,
    'kpis',                   v_kpis,
    'machines',               v_machines,
    'hour_heatmap',           v_hour_heatmap,
    'daily_conversion_series', v_daily_series
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_conversion(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_conversion(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;

-- ── analytics_operations ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_operations(
  p_company_id uuid,
  p_from timestamptz, p_to timestamptz,
  p_compare_from timestamptz, p_compare_to timestamptz,
  p_machine_ids uuid[], p_channels text[],
  p_category_ids uuid[], p_vat_rates numeric[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' SET statement_timeout = '10s'
AS $$
DECLARE
  v_kpis           jsonb;
  v_stockouts      jsonb;
  v_refill_tours   jsonb;
  v_stock_cover    jsonb;
BEGIN
  IF p_company_id IS NULL OR p_company_id <> public.my_company_id() THEN
    RAISE EXCEPTION 'analytics: company_id mismatch';
  END IF;

  -- KPIs
  SELECT jsonb_build_object(
    'stockout_hours',     ROUND((COALESCE((SELECT SUM(duration_seconds) FROM public.tray_stockout_events
                                          WHERE company_id = p_company_id
                                            AND started_at >= p_from AND started_at < p_to
                                            AND ended_at IS NOT NULL), 0) / 3600.0)::numeric, 2),
    'lost_revenue',       ROUND(COALESCE((SELECT SUM(lost_revenue_estimated) FROM public.tray_stockout_events
                                          WHERE company_id = p_company_id
                                            AND started_at >= p_from AND started_at < p_to
                                            AND ended_at IS NOT NULL), 0)::numeric, 2),
    'refill_tour_count',  (SELECT COUNT(DISTINCT metadata->>'tour_id')
                           FROM public.activity_log
                           WHERE company_id = p_company_id
                             AND created_at >= p_from AND created_at < p_to
                             AND metadata->>'tour_id' IS NOT NULL),
    'avg_stock_cover_days', (
      SELECT ROUND(AVG(NULLIF(mt.current_stock, 0)::numeric / NULLIF(public.get_product_velocity_one(p_company_id, mt.product_id, 30), 0))::numeric, 1)
      FROM public.machine_trays mt
      JOIN public."vendingMachine" vm ON vm.id = mt.machine_id
      WHERE vm.company = p_company_id
    )
  ) INTO v_kpis;

  -- stockout_events[]
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                     e.id,
    'machine_id',             e.machine_id,
    'machine_name',           vm.name,
    'tray_id',                e.tray_id,
    'item_number',            e.item_number,
    'product_id',             e.product_id,
    'product_name',           p.name,
    'started_at',             e.started_at,
    'ended_at',               e.ended_at,
    'duration_seconds',       e.duration_seconds,
    'lost_units_estimated',   e.lost_units_estimated,
    'lost_revenue_estimated', e.lost_revenue_estimated
  ) ORDER BY e.lost_revenue_estimated DESC NULLS LAST), '[]'::jsonb)
  INTO v_stockouts
  FROM public.tray_stockout_events e
  LEFT JOIN public."vendingMachine" vm ON vm.id = e.machine_id
  LEFT JOIN public.products p ON p.id = e.product_id
  WHERE e.company_id = p_company_id
    AND e.started_at >= p_from AND e.started_at < p_to;

  -- refill_tours[] — group activity_log rows by tour_id (10-min fallback bucketing
  -- intentionally NOT replicated server-side — clients pre-V2 used metadata->>'tour_id'
  -- consistently; if needed, add a CASE WHEN tour_id IS NULL THEN time-bucket-id ELSE tour_id END)
  SELECT COALESCE(jsonb_agg(t ORDER BY (t->>'started_at')::timestamptz DESC), '[]'::jsonb)
  INTO v_refill_tours
  FROM (
    SELECT jsonb_build_object(
      'tour_id',          metadata->>'tour_id',
      'started_at',       MIN(created_at),
      'ended_at',         MAX(created_at),
      'duration_minutes', GREATEST(1, EXTRACT(EPOCH FROM (MAX(created_at) - MIN(created_at)))::int / 60),
      'user_display',     (metadata->'_user_display')::text,
      'machines_count',   COUNT(DISTINCT (metadata->>'machine_id')),
      'units_added',      SUM((metadata->>'units_added')::int),
      'machines',         jsonb_agg(jsonb_build_object(
                            'machine_id',   metadata->>'machine_id',
                            'machine_name', metadata->>'machine_name',
                            'items_added',  (metadata->>'units_added')::int
                          ))
    ) AS t
    FROM public.activity_log
    WHERE company_id = p_company_id
      AND created_at >= p_from AND created_at < p_to
      AND metadata->>'tour_id' IS NOT NULL
    GROUP BY metadata->>'tour_id', metadata->'_user_display'
  ) tours;

  -- stock_cover[]
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tray_id',       mt.id,
    'machine_id',    mt.machine_id,
    'machine_name',  vm.name,
    'item_number',   mt.item_number,
    'product_id',    mt.product_id,
    'product_name',  p.name,
    'current_stock', mt.current_stock,
    'velocity',      ROUND(public.get_product_velocity_one(p_company_id, mt.product_id, 30)::numeric, 3),
    'cover_days',    CASE
      WHEN public.get_product_velocity_one(p_company_id, mt.product_id, 30) > 0
        THEN ROUND((mt.current_stock / public.get_product_velocity_one(p_company_id, mt.product_id, 30))::numeric, 1)
      ELSE NULL END
  ) ORDER BY (
    CASE WHEN public.get_product_velocity_one(p_company_id, mt.product_id, 30) > 0
      THEN mt.current_stock / public.get_product_velocity_one(p_company_id, mt.product_id, 30)
      ELSE 999999 END
  )), '[]'::jsonb)
  INTO v_stock_cover
  FROM public.machine_trays mt
  JOIN public."vendingMachine" vm ON vm.id = mt.machine_id
  LEFT JOIN public.products p ON p.id = mt.product_id
  WHERE vm.company = p_company_id;

  RETURN jsonb_build_object(
    'version',         1,
    'kpis',            v_kpis,
    'stockout_events', v_stockouts,
    'refill_tours',    v_refill_tours,
    'stock_cover',     v_stock_cover
  );
END;
$$;

REVOKE ALL ON FUNCTION public.analytics_operations(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_operations(uuid, timestamptz, timestamptz, timestamptz, timestamptz, uuid[], text[], uuid[], numeric[]) TO authenticated;
