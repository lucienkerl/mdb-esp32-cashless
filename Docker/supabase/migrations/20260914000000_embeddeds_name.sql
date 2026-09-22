-- Free-text label for an embedded device, independent of whichever
-- vendingMachine it's currently installed in (a device can be swapped
-- between machines, e.g. for hardware-revision replacements). NULL means
-- unnamed — UI falls back to mac_address/subdomain in that case.

ALTER TABLE public.embeddeds
  ADD COLUMN IF NOT EXISTS name text;

COMMENT ON COLUMN public.embeddeds.name IS
  'Optional admin-assigned label to tell multiple physical devices/hardware revisions apart. NULL = unnamed, UI falls back to mac_address/subdomain.';
