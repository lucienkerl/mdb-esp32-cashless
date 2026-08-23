/** Match window for brownout-duplicate suppression. Tunable. See spec. */
export const SUPPRESS_WINDOW_MS = 30_000;

/**
 * How far before a `time_uncertain` sale a device restart must have been
 * recorded for the sale to be treated as a brownout re-report.
 *
 * A brownout re-report only ever happens *after* the device reboots,
 * reconnects, and drains its NVS queue — so a corroborating row exists in
 * `device_restarts` near the re-report's receive time. A genuine repeat
 * purchase on a stable device has no such restart in this window and is
 * therefore never auto-removed. The reboot precedes the re-report, hence
 * the window looks mostly backward (a small forward allowance absorbs the
 * ordering skew between the restart event and the drained sale, which can
 * arrive nearly simultaneously).
 */
export const REBOOT_CORRELATION_WINDOW_MS = 10 * 60_000;
export const REBOOT_CORRELATION_FORWARD_MS = 60_000;

export interface SuppressCandidate {
  id: string;
  createdAtMs: number;
  /**
   * `sales.time_uncertain` of the already-stored row. A candidate that is
   * itself time_uncertain is never a valid suppression target — see
   * `decideSuppress`.
   */
  timeUncertain: boolean;
}

/**
 * Decide whether an incoming sale is a brownout re-report that should be
 * suppressed (auto-dropped) instead of inserted.
 *
 * Returns the matched existing sale's id (to store as matched_sale_id) or
 * null to insert normally.
 *
 * Safety, two independent gates:
 *
 *  1. Only `time_uncertain` sales are ever suppressed — a normal sale
 *     (synced clock) is always inserted, even if an identical recent sale
 *     exists.
 *
 *  2. The matched *candidate* must NOT itself be time_uncertain. A brownout
 *     re-report is by definition preceded by an original that the device
 *     recorded while it still had a working clock; the pair is therefore
 *     always (certain original, uncertain re-report). Two adjacent
 *     time_uncertain rows mean something else entirely: the device has no
 *     clock at all right now and is draining its offline NVS queue. Every
 *     sale in such a drain arrives within seconds of its siblings — not
 *     because they are duplicates, but because the webhook stamps them all
 *     with its own receive time (the payload carries occurred_at=0). Without
 *     this gate a machine that buffered six identical vends during an outage
 *     had five of them auto-removed the moment it reconnected.
 *
 * Among the remaining candidates (the caller pre-filters by
 * embedded_id/item_number/item_price/channel), suppress when one falls
 * within ±windowMs of the incoming created_at.
 */
export function decideSuppress(
  incoming: { timeUncertain: boolean; createdAtMs: number },
  candidates: SuppressCandidate[],
  windowMs: number = SUPPRESS_WINDOW_MS,
): string | null {
  if (!incoming.timeUncertain) return null;
  for (const c of candidates) {
    if (c.timeUncertain) continue;
    if (Math.abs(c.createdAtMs - incoming.createdAtMs) <= windowMs) return c.id;
  }
  return null;
}

/**
 * True if any recorded device restart corroborates a brownout re-report for a
 * sale received at `incomingMs`: a restart that occurred within `windowMs`
 * before the sale (or marginally after, within `forwardMs`, to absorb event
 * ordering skew).
 *
 * Used as a second gate after `decideSuppress` matches a same-key candidate:
 * without a nearby reboot the time_uncertain sale is treated as a genuine
 * repeat purchase and inserted normally rather than auto-removed.
 */
export function rebootCorroborates(
  restartMs: number[],
  incomingMs: number,
  windowMs: number = REBOOT_CORRELATION_WINDOW_MS,
  forwardMs: number = REBOOT_CORRELATION_FORWARD_MS,
): boolean {
  for (const r of restartMs) {
    if (r >= incomingMs - windowMs && r <= incomingMs + forwardMs) return true;
  }
  return false;
}
