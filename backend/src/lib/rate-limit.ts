/**
 * Per-user per-minute rate limit — a spam guard on top of the daily cap.
 *
 * KV key scheme (from CONFIG.md): `rl:{userId}:{epochMinute}` with a 120s TTL
 * (two minutes covers the current window plus clock skew, then auto-expires).
 */

import { RATE_LIMIT_PER_MINUTE } from "../config";
import type { Storage } from "./storage";

/** TTL for a rate-limit window key (seconds). */
const RATE_LIMIT_TTL_SECONDS = 120;

/** Whole-minute bucket since the Unix epoch. */
function epochMinute(now: Date): number {
  return Math.floor(now.getTime() / 60000);
}

/** Build the KV key for a user's current minute bucket. */
function rateLimitKey(userId: string, minute: number): string {
  return `rl:${userId}:${minute}`;
}

/** Result of a rate-limit check. `retryAfter` is seconds until the next bucket. */
export interface RateLimitResult {
  allowed: boolean;
  retryAfter?: number;
}

/**
 * Count this request against the user's current-minute bucket and decide
 * whether it is allowed. Increments first (so the Nth+1 request is the one that
 * trips), then compares against `RATE_LIMIT_PER_MINUTE`.
 */
export async function checkRateLimit(
  storage: Storage,
  userId: string,
  now: Date,
): Promise<RateLimitResult> {
  const minute = epochMinute(now);
  const count = await storage.increment(rateLimitKey(userId, minute), RATE_LIMIT_TTL_SECONDS);

  if (count <= RATE_LIMIT_PER_MINUTE) {
    return { allowed: true };
  }

  // Seconds remaining until the next minute bucket opens.
  const secondsIntoMinute = Math.floor((now.getTime() % 60000) / 1000);
  const retryAfter = Math.max(1, 60 - secondsIntoMinute);
  return { allowed: false, retryAfter };
}
