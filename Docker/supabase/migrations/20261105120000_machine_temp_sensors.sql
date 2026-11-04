-- Per-machine names and visibility for the board's temperature sensors.
--
-- Firmware reports the latest readings in every /mdb-log snapshot, which
-- mqtt-webhook merges into embeddeds.mdb_diagnostics:
--   "temps":{"ntc":41.3,"ow":[{"id":"28FF64A1B2C30405","b":1,"t":21.5}]}
-- A 1-Wire ROM id is not something an operator recognises, so the machine
-- settings let them name each sensor and pick the ones shown next to the
-- machine name (machine page and Machines panel). Shape:
--   [{"id":"ntc","name":"PCB","show":true},
--    {"id":"28FF64A1B2C30405","name":"Fridge","show":true}]
-- "ntc" is the onboard thermistor, anything else a 1-Wire ROM id (16 hex).
--
-- Kept on the machine, not the board: the probes are mounted in the machine
-- (fridge, cash box, ...). Display only: no trigger, webhook or firmware
-- reads it. Additive with a default, so older clients keep working.

ALTER TABLE public."vendingMachine"
  ADD COLUMN IF NOT EXISTS temp_sensors jsonb NOT NULL DEFAULT '[]'::jsonb;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'vendingmachine_temp_sensors_is_array'
      AND conrelid = 'public."vendingMachine"'::regclass
  ) THEN
    ALTER TABLE public."vendingMachine"
      ADD CONSTRAINT vendingmachine_temp_sensors_is_array
      CHECK (jsonb_typeof(temp_sensors) = 'array');
  END IF;
END $$;

COMMENT ON COLUMN public."vendingMachine".temp_sensors IS
  'Operator names and visibility for the board temperature sensors: [{"id":"ntc"|"<1-Wire ROM id>","name":text,"show":bool}]. Readings live in embeddeds.mdb_diagnostics.temps. Display only.';
