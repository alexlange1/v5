/**
 * Entitlement resolution via RevenueCat.
 *
 * Maps a `userId` to a `Tier`. The result is cached briefly in KV
 * (`ent:{userId}`, TTL `ENTITLEMENT_CACHE_TTL_SEC`) to keep the hot path fast
 * and to avoid hammering RevenueCat.
 *
 * FAIL-CLOSED: on ANY error (network, non-200, malformed body, bad cache) we
 * resolve to `"free"`. Paid is only granted when the configured entitlement is
 * present AND active.
 *
 * `fetch` is injected so this is unit-testable under plain vitest.
 */

import { ENTITLEMENT_CACHE_TTL_SEC } from "../config";
import type { Env, Tier } from "../types";
import type { Storage } from "./storage";

/** Dependencies for entitlement resolution (all injected for testability). */
export interface EntitlementDeps {
  storage: Storage;
  fetchImpl: typeof fetch;
  env: Env;
}

/** Build the KV cache key for a user's resolved tier. */
function entKey(userId: string): string {
  return `ent:${userId}`;
}

/** Minimal shape of the RevenueCat subscriber response we rely on. */
interface RevenueCatSubscriberResponse {
  subscriber?: {
    entitlements?: Record<
      string,
      {
        // ISO date string, or null for a lifetime/non-expiring entitlement.
        expires_date?: string | null;
      }
    >;
  };
}

/**
 * Decide whether the configured entitlement is present AND active.
 * Active = no expiry (lifetime) OR expiry strictly in the future.
 */
function isEntitlementActive(
  body: RevenueCatSubscriberResponse,
  entitlementId: string,
  now: Date,
): boolean {
  const ent = body.subscriber?.entitlements?.[entitlementId];
  if (!ent) return false;
  const expires = ent.expires_date;
  if (expires === null || expires === undefined) return true; // non-expiring
  const expiresMs = Date.parse(expires);
  if (Number.isNaN(expiresMs)) return false; // unparsable → treat as inactive
  return expiresMs > now.getTime();
}

/**
 * Resolve the tier for `userId`.
 *
 * 1. Return a cached tier from `ent:{userId}` if present.
 * 2. Otherwise GET `/v1/subscribers/{userId}` from RevenueCat with the secret
 *    REST key, decide the tier, cache it, and return it.
 * 3. On any failure, return `"free"` (fail-closed) without caching the failure.
 */
export async function resolveTier(deps: EntitlementDeps, userId: string): Promise<Tier> {
  const { storage, fetchImpl, env } = deps;

  // 1. Cache hit.
  try {
    const cached = await storage.get(entKey(userId));
    if (cached === "paid" || cached === "free") {
      return cached;
    }
  } catch {
    // Ignore cache-read errors and fall through to a live lookup.
  }

  // 2. Live lookup, fail-closed on anything unexpected.
  let tier: Tier = "free";
  try {
    const url = `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userId)}`;
    const res = await fetchImpl(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${env.REVENUECAT_API_KEY}`,
        Accept: "application/json",
      },
    });

    if (res.ok) {
      const body = (await res.json()) as RevenueCatSubscriberResponse;
      if (isEntitlementActive(body, env.REVENUECAT_ENTITLEMENT_ID, new Date())) {
        tier = "paid";
      }
    }
    // Non-2xx → leave tier as "free" (fail-closed).
  } catch {
    return "free"; // network/parse error: do not cache, just fail-closed.
  }

  // 3. Cache the resolved tier (best-effort).
  try {
    await storage.put(entKey(userId), tier, ENTITLEMENT_CACHE_TTL_SEC);
  } catch {
    // Caching is non-critical; ignore.
  }

  return tier;
}
