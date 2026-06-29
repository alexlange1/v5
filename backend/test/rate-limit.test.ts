import { describe, it, expect } from "vitest";

import { checkRateLimit } from "../src/lib/rate-limit";
import { RATE_LIMIT_PER_MINUTE } from "../src/config";
import { InMemoryStorage } from "./helpers/fakes";

const USER = "u1";

describe("checkRateLimit", () => {
  it("allows up to RATE_LIMIT_PER_MINUTE, then blocks", async () => {
    const storage = new InMemoryStorage();
    // A fixed instant mid-minute so retryAfter is deterministic.
    const now = new Date("2026-06-29T10:00:20Z");

    // The first N requests are allowed.
    for (let i = 0; i < RATE_LIMIT_PER_MINUTE; i++) {
      const r = await checkRateLimit(storage, USER, now);
      expect(r.allowed).toBe(true);
      expect(r.retryAfter).toBeUndefined();
    }

    // The (N+1)th request is blocked, with a retryAfter set.
    const blocked = await checkRateLimit(storage, USER, now);
    expect(blocked.allowed).toBe(false);
    expect(blocked.retryAfter).toBeGreaterThan(0);
    // 20s into the minute → ~40s until the next bucket.
    expect(blocked.retryAfter).toBe(40);
  });

  it("uses the documented KV key scheme rl:{userId}:{epochMinute}", async () => {
    const storage = new InMemoryStorage();
    const now = new Date("2026-06-29T10:00:20Z");
    await checkRateLimit(storage, USER, now);
    const minute = Math.floor(now.getTime() / 60000);
    expect(storage.map.get(`rl:${USER}:${minute}`)).toBe("1");
  });

  it("resets in a new minute bucket", async () => {
    const storage = new InMemoryStorage();
    const minute1 = new Date("2026-06-29T10:00:20Z");
    const minute2 = new Date("2026-06-29T10:01:20Z");

    // Exhaust the first minute.
    for (let i = 0; i <= RATE_LIMIT_PER_MINUTE; i++) {
      await checkRateLimit(storage, USER, minute1);
    }
    expect((await checkRateLimit(storage, USER, minute1)).allowed).toBe(false);

    // A new minute bucket starts fresh.
    expect((await checkRateLimit(storage, USER, minute2)).allowed).toBe(true);
  });

  it("isolates limits per user", async () => {
    const storage = new InMemoryStorage();
    const now = new Date("2026-06-29T10:00:20Z");
    for (let i = 0; i <= RATE_LIMIT_PER_MINUTE; i++) {
      await checkRateLimit(storage, "a", now);
    }
    expect((await checkRateLimit(storage, "a", now)).allowed).toBe(false);
    // A different user is unaffected.
    expect((await checkRateLimit(storage, "b", now)).allowed).toBe(true);
  });
});
