-- Online history per device.
--
-- embeddeds.status only holds the current state, so nobody can tell when a
-- device was offline yesterday or how long an outage lasted. This table keeps
-- one row per status *change* (online → offline, online → ota_updating, …),
-- which is what the 24-hour connection bar on the machine page and in the apps
-- is drawn from.
--
-- Written by a trigger on embeddeds rather than by mqtt-webhook, so every path
-- that changes the status is covered (the /status handler, the mdb-log
-- heartbeat that repairs a missed 'online', manual fixes in Studio) and the
-- webhook stays unaware of it.
--
-- prev_status lets a reader reconstruct the state at the start of any window
-- from the first row inside it, without a second query for the row before.
--
-- Rows are pruned per device after 30 days on every insert; only the last day
-- is shown, the rest is headroom.

CREATE TABLE IF NOT EXISTS public.embedded_status_log (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at  timestamptz NOT NULL DEFAULT now(),
    embedded_id uuid        NOT NULL REFERENCES public.embeddeds(id) ON DELETE CASCADE,
    status      text        NOT NULL,
    prev_status text
);

ALTER TABLE public.embedded_status_log ENABLE ROW LEVEL SECURITY;

-- Only the trigger (and service_role) writes; members read their devices.
GRANT SELECT ON public.embedded_status_log TO authenticated;
GRANT ALL ON public.embedded_status_log TO service_role;

DROP POLICY IF EXISTS embedded_status_log_select ON public.embedded_status_log;
CREATE POLICY embedded_status_log_select ON public.embedded_status_log
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.embeddeds e
            WHERE e.id = embedded_status_log.embedded_id
              AND e.company = public.my_company_id()
        )
    );

CREATE INDEX IF NOT EXISTS idx_embedded_status_log_embedded_created
    ON public.embedded_status_log (embedded_id, created_at DESC);

-- SECURITY DEFINER: embeddeds is updated by service_role from the webhook, but
-- an admin can also update it (e.g. renaming a device) through RLS, and such a
-- user has no INSERT right on the log.
CREATE OR REPLACE FUNCTION public.log_embedded_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.status IS NULL OR NEW.status = '' THEN
        RETURN NEW;
    END IF;

    INSERT INTO public.embedded_status_log (embedded_id, status, prev_status, created_at)
    VALUES (NEW.id, NEW.status, NULLIF(OLD.status, ''), COALESCE(NEW.status_at, now()));

    DELETE FROM public.embedded_status_log
    WHERE embedded_id = NEW.id
      AND created_at < now() - interval '30 days';

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_embedded_status_change ON public.embeddeds;
CREATE TRIGGER trg_log_embedded_status_change
    AFTER UPDATE OF status ON public.embeddeds
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION public.log_embedded_status_change();
