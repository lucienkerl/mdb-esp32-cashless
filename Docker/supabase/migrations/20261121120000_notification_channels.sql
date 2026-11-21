-- Notification settings per event type AND channel (push, email, …).
--
-- Until now `notification_preferences` held one on/off switch per event type,
-- and the only channel was push. Operators want to choose per event which
-- channel(s) to use — e.g. sales only as push, a machine going offline as push
-- AND email. `notification_settings` is that matrix: one row per
-- (user, event type, channel).
--
-- Defaults (a missing row): push is ON (unchanged behaviour of the old table,
-- absence = enabled), every other channel is OFF — a new channel is always
-- opt-in. The same rule lives in functions/_shared/notification-settings.ts
-- and in the clients; keep them together.
--
-- Channels are plain text so a later channel (SMS, Telegram, webhook, …) needs
-- no schema change, only a sender in the edge functions and a column in the
-- clients.
--
-- Backward compatibility: app versions in the field still read and upsert
-- `notification_preferences` (onConflict user_id,notification_type), so that
-- table stays and is kept in sync with the push column of the new one in both
-- directions. The edge functions read only `notification_settings`.

CREATE TABLE IF NOT EXISTS public.notification_settings (
    user_id           uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    notification_type text        NOT NULL,
    channel           text        NOT NULL CHECK (channel ~ '^[a-z][a-z0-9_]*$'),
    enabled           boolean     NOT NULL,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, notification_type, channel)
);

COMMENT ON TABLE public.notification_settings IS
  'Per-user notification matrix: event type x channel. Missing row = default (push on, every other channel off).';

ALTER TABLE public.notification_settings ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.notification_settings TO authenticated;
GRANT ALL ON public.notification_settings TO service_role;

DROP POLICY IF EXISTS notification_settings_select ON public.notification_settings;
CREATE POLICY notification_settings_select ON public.notification_settings
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

DROP POLICY IF EXISTS notification_settings_insert ON public.notification_settings;
CREATE POLICY notification_settings_insert ON public.notification_settings
    FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS notification_settings_update ON public.notification_settings;
CREATE POLICY notification_settings_update ON public.notification_settings
    FOR UPDATE TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS notification_settings_delete ON public.notification_settings;
CREATE POLICY notification_settings_delete ON public.notification_settings
    FOR DELETE TO authenticated
    USING (user_id = auth.uid());

-- Backfill: every existing per-type switch becomes the push cell.
INSERT INTO public.notification_settings (user_id, notification_type, channel, enabled, updated_at)
SELECT user_id, notification_type, 'push', enabled, updated_at
FROM public.notification_preferences
ON CONFLICT (user_id, notification_type, channel) DO NOTHING;

-- ── Sync: legacy table → push cell ───────────────────────────────────────────
-- pg_trigger_depth() > 1 means we are inside the other sync trigger; stop
-- there so the two triggers never bounce a write back and forth.
CREATE OR REPLACE FUNCTION public.sync_notification_preferences_to_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF pg_trigger_depth() > 1 THEN
        RETURN NULL;
    END IF;

    IF TG_OP = 'DELETE' THEN
        DELETE FROM public.notification_settings
        WHERE user_id = OLD.user_id
          AND notification_type = OLD.notification_type
          AND channel = 'push';
        RETURN NULL;
    END IF;

    INSERT INTO public.notification_settings (user_id, notification_type, channel, enabled, updated_at)
    VALUES (NEW.user_id, NEW.notification_type, 'push', NEW.enabled, now())
    ON CONFLICT (user_id, notification_type, channel)
    DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now();
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_notification_preferences ON public.notification_preferences;
CREATE TRIGGER trg_sync_notification_preferences
    AFTER INSERT OR UPDATE OR DELETE ON public.notification_preferences
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_notification_preferences_to_settings();

-- ── Sync: push cell → legacy table (so old apps show the current switch) ─────
CREATE OR REPLACE FUNCTION public.sync_notification_settings_to_preferences()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF pg_trigger_depth() > 1 THEN
        RETURN NULL;
    END IF;

    IF TG_OP = 'DELETE' THEN
        IF OLD.channel = 'push' THEN
            DELETE FROM public.notification_preferences
            WHERE user_id = OLD.user_id
              AND notification_type = OLD.notification_type;
        END IF;
        RETURN NULL;
    END IF;

    IF NEW.channel <> 'push' THEN
        RETURN NULL;
    END IF;

    INSERT INTO public.notification_preferences (user_id, notification_type, enabled, updated_at)
    VALUES (NEW.user_id, NEW.notification_type, NEW.enabled, now())
    ON CONFLICT (user_id, notification_type)
    DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now();
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_notification_settings ON public.notification_settings;
CREATE TRIGGER trg_sync_notification_settings
    AFTER INSERT OR UPDATE OR DELETE ON public.notification_settings
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_notification_settings_to_preferences();

-- ── Machine offline / back online alerts ─────────────────────────────────────
-- A device's MQTT last will flips embeddeds.status to 'offline' the moment the
-- broker loses it — also for a few seconds of WiFi trouble or a reboot. To keep
-- that from paging anyone, the alert goes out only after the device has stayed
-- offline for companies.offline_alert_minutes (default 5). A "back online"
-- alert is sent only for an outage that was alerted, so short blips stay
-- silent in both directions.
--
-- embeddeds.offline_alerted_at marks "offline alert sent, back-online alert
-- still owed". A pg_cron job checks once a minute.

ALTER TABLE public.embeddeds
    ADD COLUMN IF NOT EXISTS offline_alerted_at timestamptz;

COMMENT ON COLUMN public.embeddeds.offline_alerted_at IS
  'Set when the machine-offline alert went out; cleared (with a back-online alert) once the device is online again.';

ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS offline_alert_minutes smallint NOT NULL DEFAULT 5
        CHECK (offline_alert_minutes BETWEEN 1 AND 1440);

COMMENT ON COLUMN public.companies.offline_alert_minutes IS
  'Minutes a device must stay offline before the machine_offline notification fires.';

-- Devices that are already offline when this ships count as alerted: nobody
-- should get a flood of alerts for outages that are days old. They do get the
-- back-online alert when they return.
UPDATE public.embeddeds
SET offline_alerted_at = now()
WHERE status = 'offline'
  AND offline_alerted_at IS NULL;

CREATE OR REPLACE FUNCTION public.dispatch_device_connectivity_alerts()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_url  text := current_setting('app.settings.supabase_url', true);
    v_key  text := current_setting('app.settings.service_role_key', true);
    v_dev  record;
    v_sent integer := 0;
BEGIN
    IF v_url IS NULL OR v_url = '' OR v_key IS NULL OR v_key = '' THEN
        RAISE WARNING 'dispatch_device_connectivity_alerts: app.settings.supabase_url or service_role_key not set; skipping. Run Docker/update.sh to configure.';
        RETURN 0;
    END IF;

    -- Offline long enough and not alerted yet.
    FOR v_dev IN
        SELECT e.id
        FROM public.embeddeds e
        JOIN public.companies c ON c.id = e.company
        WHERE e.status = 'offline'
          AND e.offline_alerted_at IS NULL
          AND e.status_at IS NOT NULL
          AND e.status_at < now() - make_interval(mins => c.offline_alert_minutes)
        FOR UPDATE OF e SKIP LOCKED
    LOOP
        UPDATE public.embeddeds SET offline_alerted_at = now() WHERE id = v_dev.id;
        PERFORM net.http_post(
            url     := v_url || '/functions/v1/notify-device-status',
            headers := jsonb_build_object(
                         'Authorization', 'Bearer ' || v_key,
                         'Content-Type',  'application/json'),
            body    := jsonb_build_object('embedded_id', v_dev.id, 'event', 'offline')
        );
        v_sent := v_sent + 1;
    END LOOP;

    -- Back online after an alerted outage.
    FOR v_dev IN
        SELECT e.id, e.offline_alerted_at
        FROM public.embeddeds e
        WHERE e.status = 'online'
          AND e.offline_alerted_at IS NOT NULL
        FOR UPDATE OF e SKIP LOCKED
    LOOP
        UPDATE public.embeddeds SET offline_alerted_at = NULL WHERE id = v_dev.id;
        PERFORM net.http_post(
            url     := v_url || '/functions/v1/notify-device-status',
            headers := jsonb_build_object(
                         'Authorization', 'Bearer ' || v_key,
                         'Content-Type',  'application/json'),
            body    := jsonb_build_object('embedded_id', v_dev.id, 'event', 'online')
        );
        v_sent := v_sent + 1;
    END LOOP;

    RETURN v_sent;
END;
$$;

COMMENT ON FUNCTION public.dispatch_device_connectivity_alerts IS
  'Called every minute by pg_cron. POSTs notify-device-status for devices offline longer than companies.offline_alert_minutes and for alerted devices that are back online.';

REVOKE ALL ON FUNCTION public.dispatch_device_connectivity_alerts() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dispatch_device_connectivity_alerts() FROM anon, authenticated;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'device_connectivity_alerts') THEN
            PERFORM cron.unschedule('device_connectivity_alerts');
        END IF;

        PERFORM cron.schedule(
            'device_connectivity_alerts',
            '* * * * *',
            $cron$SELECT public.dispatch_device_connectivity_alerts();$cron$
        );

        RAISE NOTICE 'device_connectivity_alerts: scheduled every minute';
    ELSE
        RAISE WARNING 'pg_cron not installed; device_connectivity_alerts not scheduled. Invoke dispatch_device_connectivity_alerts() manually or fix shared_preload_libraries.';
    END IF;
END $$;
