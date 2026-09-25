-- Deals: an offer stops being "new" once the user has SEEN it in the list,
-- not only after pinning/archiving it.
--
--   1. deal_user_state.seen_at – first time the offer card was on screen
--   2. mark_deals_seen(jsonb)  – batch stamp from the clients (web + iOS)
--   3. get_new_deal_keys()     – full previous body + seen_at exclusion
--
-- get_new_deals_count() wraps get_new_deal_keys(), so the dashboard banners
-- (web, iOS, Android) pick this up without changes. Old clients never call
-- mark_deals_seen and keep the previous pin/archive-only behaviour.

-- 1. seen_at -----------------------------------------------------------------
ALTER TABLE public.deal_user_state
  ADD COLUMN IF NOT EXISTS seen_at timestamptz NULL;

-- 2. mark_deals_seen ---------------------------------------------------------
-- p_keys: [{"retailer": "...", "offer_id": "..."}, ...]
-- Keeps the first seen_at (COALESCE) and never touches pinned/archived.
-- SECURITY INVOKER: the deal_user_state RLS policies already scope writes to
-- the caller's own rows in their own company.
CREATE OR REPLACE FUNCTION public.mark_deals_seen(p_keys jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE
  v_company uuid := public.my_company_id();
  v_user    uuid := auth.uid();
BEGIN
  IF v_company IS NULL OR v_user IS NULL OR p_keys IS NULL
     OR jsonb_typeof(p_keys) <> 'array' THEN
    RETURN;
  END IF;

  INSERT INTO public.deal_user_state (user_id, company_id, retailer, offer_id, seen_at)
  SELECT DISTINCT v_user, v_company, k->>'retailer', k->>'offer_id', now()
  FROM jsonb_array_elements(p_keys) AS k
  WHERE coalesce(k->>'retailer', '') <> '' AND coalesce(k->>'offer_id', '') <> ''
  ON CONFLICT (user_id, company_id, retailer, offer_id)
  DO UPDATE SET seen_at = coalesce(public.deal_user_state.seen_at, EXCLUDED.seen_at);
END $$;

COMMENT ON FUNCTION public.mark_deals_seen(jsonb) IS
  'Stamps deal_user_state.seen_at (first view only) for the calling user. Seen offers are no longer returned by get_new_deal_keys.';

GRANT EXECUTE ON FUNCTION public.mark_deals_seen(jsonb) TO authenticated;

-- 3. get_new_deal_keys: body of 20260614120200 + seen_at exclusion ------------
CREATE OR REPLACE FUNCTION public.get_new_deal_keys()
RETURNS TABLE (retailer text, offer_id text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_company  uuid := public.my_company_id();
  v_user     uuid := auth.uid();
  v_baseline timestamptz;
BEGIN
  IF v_company IS NULL OR v_user IS NULL THEN RETURN; END IF;

  INSERT INTO public.deal_user_seen (user_id, company_id)
  VALUES (v_user, v_company)
  ON CONFLICT (user_id, company_id) DO NOTHING;

  SELECT dus.baseline_at INTO v_baseline
  FROM public.deal_user_seen dus
  WHERE dus.user_id = v_user AND dus.company_id = v_company;

  RETURN QUERY
  SELECT DISTINCT dc.retailer, dc.offer_id
  FROM public.deal_cache dc
  JOIN public.deal_offer_first_seen fs
    ON  fs.company_id = dc.company_id
    AND fs.retailer   = dc.retailer
    AND fs.offer_id   = dc.offer_id
  WHERE dc.company_id = v_company
    AND dc.offer_id IS NOT NULL
    AND (dc.valid_until IS NULL OR dc.valid_until >= current_date)
    AND fs.first_seen_at > v_baseline
    AND NOT EXISTS (
      SELECT 1 FROM public.deal_user_state us
      WHERE us.user_id    = v_user
        AND us.company_id  = v_company
        AND us.retailer    = dc.retailer
        AND us.offer_id    = dc.offer_id
        AND (us.pinned_at IS NOT NULL OR us.archived_at IS NOT NULL OR us.seen_at IS NOT NULL)
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.get_suppressed_offer_keys(v_company) s
      WHERE s.retailer = dc.retailer AND s.offer_id = dc.offer_id
    );
END $$;

COMMENT ON FUNCTION public.get_new_deal_keys IS
  'Returns (retailer, offer_id) of offers that are new for the calling user: currently cached, valid, first seen after the user baseline, not suppressed, and not yet seen/pinned/archived. Lazily creates the user baseline on first call.';

GRANT EXECUTE ON FUNCTION public.get_new_deal_keys() TO authenticated;
