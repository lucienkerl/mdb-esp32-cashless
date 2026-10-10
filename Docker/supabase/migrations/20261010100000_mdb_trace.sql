-- Live MDB bus trace.
--
-- While an operator has a trace running (config cmd 0x33), the firmware
-- publishes batches of raw MDB words on /{company}/{device}/mdb-trace and
-- mqtt-webhook stores one row per batch here. The management frontend
-- subscribes to INSERTs for the machine and renders them as a live console.
--
-- One row per batch (not per word) keeps write volume at ~2 rows/s per tracing
-- device. Rows are short-lived debugging data: the webhook prunes anything
-- older than an hour, there is no history to preserve.
--
-- frames: JSON array of [age_ms, dir, hex] — age_ms is how long before the
-- row's created_at the frame started, dir is "r" (seen on the bus) or "t"
-- (sent by the device), hex is concatenated 3-digit hex 9-bit MDB words.

CREATE TABLE IF NOT EXISTS public.mdb_trace (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at  timestamptz NOT NULL DEFAULT now(),
    embedded_id uuid        NOT NULL REFERENCES public.embeddeds(id) ON DELETE CASCADE,
    frames      jsonb       NOT NULL,
    dropped     integer     NOT NULL DEFAULT 0   -- words lost on the device (ring overflow) before this batch
);

ALTER TABLE public.mdb_trace ENABLE ROW LEVEL SECURITY;

-- Only service_role writes (via mqtt-webhook); authenticated users read.
GRANT SELECT ON public.mdb_trace TO authenticated;
GRANT ALL ON public.mdb_trace TO service_role;

-- Members of the same company can read the trace of their devices.
DROP POLICY IF EXISTS mdb_trace_select ON public.mdb_trace;
CREATE POLICY mdb_trace_select ON public.mdb_trace
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.embeddeds e
            WHERE e.id = mdb_trace.embedded_id
              AND e.company = public.my_company_id()
        )
    );

-- Per-device reads ordered by time, and the webhook's retention delete.
CREATE INDEX IF NOT EXISTS idx_mdb_trace_embedded_created
    ON public.mdb_trace (embedded_id, created_at DESC);

-- Live updates for the frontend console.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'mdb_trace'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.mdb_trace;
    END IF;
END $$;
