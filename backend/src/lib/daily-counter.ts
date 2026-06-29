/**
 * Per-user daily message counter.
 *
 * KV key scheme (from CONFIG.md): `count:{userId}:{YYYY-MM-DD}` with TTL
 * `COUNTER_TTL_SECONDS` so old day-keys expire automatically.
 *
 * This is the server-side trust boundary for the volume cap. The client may
 * mirror a remaining-count for UX, but it is never authoritative.
 */

import { COUNTER_TTL_SECONDS } from "../config";
import type { Storage } from "./storage";

/** Build the KV key for a user's count on a given local day. */
function countKey(userId: string, dayKey: string): string {
  return `count:${userId}:${dayKey}`;
}

/** Read the current count for `userId` on `dayKey`. Absent → 0. */
export async function getCount(
  storage: Storage,
  userId: string,
  dayKey: string,
): Promise<number> {
  const raw = await storage.get(countKey(userId, dayKey));
  if (raw === null) return 0;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

/**
 * Reserve one message: increment the daily counter and return the new count.
 * Called only after the cap check passes (step 7 of the processing order).
 */
export async function reserve(
  storage: Storage,
  userId: string,
  dayKey: string,
): Promise<number> {
  return storage.increment(countKey(userId, dayKey), COUNTER_TTL_SECONDS);
}

/**
 * Refund a previously reserved message (decrement, floored at 0).
 *
 * Used when the upstream model call fails BEFORE any token is produced, so the
 * user is not charged for a request that yielded nothing.
 */
export async function refund(
  storage: Storage,
  userId: string,
  dayKey: string,
): Promise<void> {
  const key = countKey(userId, dayKey);
  const current = await getCount(storage, userId, dayKey);
  const next = current > 0 ? current - 1 : 0;
  await storage.put(key, String(next), COUNTER_TTL_SECONDS);
}
