/**
 * Storage abstraction over Cloudflare KV.
 *
 * Handlers depend on the `Storage` *interface*, not on KV directly, so unit
 * tests can inject an in-memory fake and run under plain vitest (no workerd).
 */

/** Minimal key/value store the rest of the backend depends on. */
export interface Storage {
  /** Read a value, or `null` if absent. */
  get(key: string): Promise<string | null>;
  /** Write a value, optionally with a TTL in seconds. */
  put(key: string, value: string, ttlSec?: number): Promise<void>;
  /**
   * Read-modify-write increment of an integer counter.
   * Returns the new value. If the key is absent it starts from 0.
   */
  increment(key: string, ttlSec?: number): Promise<number>;
}

/** `Storage` backed by a Cloudflare KV namespace. */
export class KVStorage implements Storage {
  constructor(private readonly kv: KVNamespace) {}

  async get(key: string): Promise<string | null> {
    return this.kv.get(key);
  }

  async put(key: string, value: string, ttlSec?: number): Promise<void> {
    // KV requires a minimum TTL of 60s; callers pass values well above that.
    await this.kv.put(key, value, ttlSec ? { expirationTtl: ttlSec } : undefined);
  }

  /**
   * Increment is read-modify-write.
   *
   * NOTE: KV has no atomic increment, so concurrent requests for the same key
   * can race and lose an increment. Best-effort counting is acceptable for v1
   * (the daily cap is a soft spend lever, not a hard security boundary), and a
   * lost increment only ever *under*-counts, never over-grants.
   */
  async increment(key: string, ttlSec?: number): Promise<number> {
    const current = await this.kv.get(key);
    const parsed = current === null ? 0 : Number.parseInt(current, 10);
    const next = (Number.isFinite(parsed) ? parsed : 0) + 1;
    await this.put(key, String(next), ttlSec);
    return next;
  }
}
