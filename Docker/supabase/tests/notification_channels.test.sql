-- notification_settings (event type x channel) and its two-way sync with the
-- legacy notification_preferences table; dispatch_device_connectivity_alerts.
-- Rolled back. Plain ASSERTs. Fake JWT for the authenticated path.
BEGIN;
SET LOCAL TIMEZONE = 'UTC';

-- Without pg_net (plain Postgres test runs) give the dispatcher a stand-in.
DO $$
BEGIN
  IF to_regnamespace('net') IS NULL THEN
    CREATE SCHEMA net;
    CREATE FUNCTION net.http_post(url text, headers jsonb, body jsonb) RETURNS bigint
      LANGUAGE sql AS $f$ SELECT 1::bigint $f$;
  END IF;
END $$;

SELECT set_config('app.settings.supabase_url', 'http://kong:8000', true);
SELECT set_config('app.settings.service_role_key', 'test-key', true);

DO $$
DECLARE
  v_company uuid := gen_random_uuid();
  v_user    uuid := gen_random_uuid();
  v_other   uuid := gen_random_uuid();
  v_quiet   uuid := gen_random_uuid();
  v_long    uuid := gen_random_uuid();
  v_blip    uuid := gen_random_uuid();
  v_enabled boolean;
  v_count   int;
  v_sent    int;
  v_at      timestamptz;
BEGIN
  INSERT INTO public.companies (id, name) VALUES (v_company, 'Notify Co');
  INSERT INTO auth.users (id, instance_id, email, created_at) VALUES
    (v_user,  '00000000-0000-0000-0000-000000000000', 'notify@test.local', now()),
    (v_other, '00000000-0000-0000-0000-000000000000', 'other@test.local', now());

  -- ── Legacy write (old app) → push cell ──
  INSERT INTO public.notification_preferences (user_id, notification_type, enabled)
    VALUES (v_user, 'sale', false);
  SELECT enabled INTO v_enabled FROM public.notification_settings
    WHERE user_id = v_user AND notification_type = 'sale' AND channel = 'push';
  ASSERT v_enabled = false, 'legacy insert must create the push cell';

  UPDATE public.notification_preferences SET enabled = true
    WHERE user_id = v_user AND notification_type = 'sale';
  SELECT enabled INTO v_enabled FROM public.notification_settings
    WHERE user_id = v_user AND notification_type = 'sale' AND channel = 'push';
  ASSERT v_enabled = true, 'legacy update must follow into the push cell';

  -- ── New push cell → legacy row ──
  INSERT INTO public.notification_settings (user_id, notification_type, channel, enabled)
    VALUES (v_user, 'low_stock', 'push', false);
  SELECT enabled INTO v_enabled FROM public.notification_preferences
    WHERE user_id = v_user AND notification_type = 'low_stock';
  ASSERT v_enabled = false, 'push cell must be mirrored to the legacy table';

  -- ── Other channels never touch the legacy table ──
  INSERT INTO public.notification_settings (user_id, notification_type, channel, enabled)
    VALUES (v_user, 'machine_offline', 'email', true);
  SELECT count(*) INTO v_count FROM public.notification_preferences
    WHERE user_id = v_user AND notification_type = 'machine_offline';
  ASSERT v_count = 0, 'email cell must not create a legacy row';

  -- Deleting the push cell deletes the legacy row (back to default)
  DELETE FROM public.notification_settings
    WHERE user_id = v_user AND notification_type = 'low_stock' AND channel = 'push';
  SELECT count(*) INTO v_count FROM public.notification_preferences
    WHERE user_id = v_user AND notification_type = 'low_stock';
  ASSERT v_count = 0, 'push delete must delete the legacy row';

  -- Channel names are validated
  BEGIN
    INSERT INTO public.notification_settings (user_id, notification_type, channel, enabled)
      VALUES (v_user, 'sale', 'E-Mail', true);
    RAISE EXCEPTION 'bad channel name accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- ── RLS: own rows only ──
  INSERT INTO public.notification_settings (user_id, notification_type, channel, enabled)
    VALUES (v_other, 'sale', 'email', true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_count FROM public.notification_settings WHERE user_id = v_other;
  ASSERT v_count = 0, 'a user must not see another user''s settings';
  -- An own upsert through the API path (exercises both sync triggers under RLS)
  INSERT INTO public.notification_settings (user_id, notification_type, channel, enabled)
    VALUES (v_user, 'inbox', 'push', false)
    ON CONFLICT (user_id, notification_type, channel) DO UPDATE SET enabled = EXCLUDED.enabled;
  BEGIN
    INSERT INTO public.notification_settings (user_id, notification_type, channel, enabled)
      VALUES (v_other, 'inbox', 'push', false);
    RAISE EXCEPTION 'writing another user''s row was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;
  SELECT enabled INTO v_enabled FROM public.notification_preferences
    WHERE user_id = v_user AND notification_type = 'inbox';
  ASSERT v_enabled = false, 'own upsert must reach the legacy table';

  -- ── Connectivity alerts ──
  UPDATE public.companies SET offline_alert_minutes = 5 WHERE id = v_company;
  INSERT INTO public.embeddeds (id, company, status, status_at) VALUES
    (v_quiet, v_company, 'online',  now()),
    (v_long,  v_company, 'offline', now() - interval '10 minutes'),
    (v_blip,  v_company, 'offline', now() - interval '1 minute');

  v_sent := public.dispatch_device_connectivity_alerts();
  ASSERT v_sent = 1, 'only the long outage must alert, got ' || v_sent;
  SELECT offline_alerted_at INTO v_at FROM public.embeddeds WHERE id = v_long;
  ASSERT v_at IS NOT NULL, 'alerted device must be marked';
  SELECT offline_alerted_at INTO v_at FROM public.embeddeds WHERE id = v_blip;
  ASSERT v_at IS NULL, 'a short outage must not be marked';

  -- Second run: nothing new
  v_sent := public.dispatch_device_connectivity_alerts();
  ASSERT v_sent = 0, 'an alerted outage must not alert twice, got ' || v_sent;

  -- The blip comes back before the grace time: silent, no back-online alert
  UPDATE public.embeddeds SET status = 'online', status_at = now() WHERE id = v_blip;
  -- The long outage comes back: one back-online alert, mark cleared
  UPDATE public.embeddeds SET status = 'online', status_at = now() WHERE id = v_long;
  v_sent := public.dispatch_device_connectivity_alerts();
  ASSERT v_sent = 1, 'exactly one back-online alert expected, got ' || v_sent;
  SELECT offline_alerted_at INTO v_at FROM public.embeddeds WHERE id = v_long;
  ASSERT v_at IS NULL, 'back-online must clear the mark';

  -- An OTA state is not "back online"
  UPDATE public.embeddeds SET status = 'offline', status_at = now() - interval '6 minutes' WHERE id = v_quiet;
  v_sent := public.dispatch_device_connectivity_alerts();
  ASSERT v_sent = 1, 'quiet device offline long enough must alert';
  UPDATE public.embeddeds SET status = 'ota_updating', status_at = now() WHERE id = v_quiet;
  v_sent := public.dispatch_device_connectivity_alerts();
  ASSERT v_sent = 0, 'ota_updating must not count as back online';

  RAISE NOTICE 'notification_channels: all assertions passed';
END $$;

ROLLBACK;
