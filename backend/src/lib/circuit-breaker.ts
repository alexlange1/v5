/**
 * Global cost circuit breaker.
 *
 * Tracks an *estimated* global daily spend in KV (`spend:{YYYY-MM-DD}`) and
 * trips once it reaches `DAILY_SPEND_CEILING_EUR`. When open, NEW FREE requests
 * are throttled (503); paid traffic is still served (see handler / contract).
 *
 * The estimate is best-effort: KV increments are not atomic, but the breaker is
 * a coarse safety valve, not an accountant.
 */

import { COUNTER_TTL_SECONDS, DAILY_SPEND_CEILING_EUR } from "../config";
import type { Storage } from "./storage";

/** Build the KV key for the global spend estimate on a given local day. */
function spendKey(dayKey: string): string {
  return `spend:${dayKey}`;
}

/** Read the current estimated spend (EUR) for `dayKey`. Absent → 0. */
async function getSpend(storage: Storage, dayKey: string): Promise<number> {
  const raw = await storage.get(spendKey(dayKey));
  if (raw === null) return 0;
  const parsed = Number.parseFloat(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

/**
 * Add `eur` to the day's estimated spend (read-modify-write).
 * Called when a request is reserved (step 7 of the processing order).
 */
export async function addSpend(storage: Storage, dayKey: string, eur: number): Promise<void> {
  const current = await getSpend(storage, dayKey);
  const next = current + eur;
  await storage.put(spendKey(dayKey), String(next), COUNTER_TTL_SECONDS);
}

/** True once the day's estimated spend has reached the ceiling. */
export async function isOpen(storage: Storage, dayKey: string): Promise<boolean> {
  const spend = await getSpend(storage, dayKey);
  return spend >= DAILY_SPEND_CEILING_EUR;
}
