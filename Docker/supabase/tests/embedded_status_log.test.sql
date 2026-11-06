-- embedded_status_log: one row per status change of a device, written by the
-- trigger on embeddeds, readable only by the device's own company.
-- Rolled back. Plain ASSERTs. Fake JWT for the authenticated path.
BEGIN;
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company  uuid := gen_random_uuid();
  v_other    uuid := gen_random_uuid();
  v_member   uuid := gen_random_uuid();
  v_device   uuid := gen_random_uuid();
  v_foreign  uuid := gen_random_uuid();
  v_count    int;
  v_status   text;
  v_prev     text;
  v_at       timestamptz;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'Log Co'), (v_other, 'Other Co');
  INSERT INTO auth.users (id, instance_id, email, created_at) VALUES
    (v_member, '00000000-0000-0000-0000-000000000000', 'log-member@test.local', now());
  INSERT INTO public.organization_members (company_id, user_id, role) VALUES
    (v_company, v_member, 'viewer');
  INSERT INTO public.embeddeds (id, company, status, status_at) VALUES
    (v_device,  v_company, NULL, NULL),
    (v_foreign, v_other,   'online', now());

  -- First status ever: logged, no previous status
  UPDATE public.embeddeds SET status = 'online', status_at = '2026-11-04 08:00+00' WHERE id = v_device;
  SELECT status, prev_status, created_at INTO v_status, v_prev, v_at
    FROM public.embedded_status_log WHERE embedded_id = v_device ORDER BY id DESC LIMIT 1;
  ASSERT v_status = 'online', 'first status must be logged';
  ASSERT v_prev IS NULL, 'first status has no previous status';
  ASSERT v_at = '2026-11-04 08:00+00', 'row takes the status_at of the change';

  -- A heartbeat only moves status_at: nothing logged
  UPDATE public.embeddeds SET status_at = '2026-11-04 08:05+00' WHERE id = v_device;
  UPDATE public.embeddeds SET status = 'online', status_at = '2026-11-04 08:10+00' WHERE id = v_device;
  SELECT count(*) INTO v_count FROM public.embedded_status_log WHERE embedded_id = v_device;
  ASSERT v_count = 1, 'unchanged status must not be logged, got ' || v_count;

  -- A real change: logged with the previous status
  UPDATE public.embeddeds SET status = 'offline', status_at = '2026-11-04 09:00+00' WHERE id = v_device;
  SELECT status, prev_status INTO v_status, v_prev
    FROM public.embedded_status_log WHERE embedded_id = v_device ORDER BY id DESC LIMIT 1;
  ASSERT v_status = 'offline' AND v_prev = 'online', 'offline change must carry prev_status online';

  -- Rows older than 30 days are pruned on the next change
  INSERT INTO public.embedded_status_log (embedded_id, status, created_at)
    VALUES (v_device, 'online', now() - interval '40 days');
  UPDATE public.embeddeds SET status = 'online', status_at = now() WHERE id = v_device;
  SELECT count(*) INTO v_count FROM public.embedded_status_log
    WHERE embedded_id = v_device AND created_at < now() - interval '30 days';
  ASSERT v_count = 0, 'old rows must be pruned';

  -- Members see their own devices only
  UPDATE public.embeddeds SET status = 'offline' WHERE id = v_foreign;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_member::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_count FROM public.embedded_status_log WHERE embedded_id = v_device;
  ASSERT v_count = 3, 'member must read own device history, got ' || v_count;
  SELECT count(*) INTO v_count FROM public.embedded_status_log WHERE embedded_id = v_foreign;
  ASSERT v_count = 0, 'member must not read another company''s history';
  RESET ROLE;

  RAISE NOTICE 'embedded_status_log: all assertions passed';
END $$;

ROLLBACK;
