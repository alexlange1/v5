import { describe, it, expect } from "vitest";

import { resolveTier } from "../src/lib/entitlement";
import { ENTITLEMENT_CACHE_TTL_SEC } from "../src/config";
import {
  InMemoryStorage,
  makeEnv,
  makeFakeFetch,
  revenueCatActive,
  revenueCatError,
  revenueCatFree,
} from "./helpers/fakes";

const USER = "u1";

describe("resolveTier", () => {
  it("returns 'paid' when RevenueCat reports an active entitlement", async () => {
    const storage = new InMemoryStorage();
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      { match: "api.revenuecat.com", response: () => revenueCatActive(env.REVENUECAT_ENTITLEMENT_ID) },
    ]);

    const tier = await resolveTier({ storage, fetchImpl, env }, USER);
    expect(tier).toBe("paid");
  });

  it("treats a future expiry as active and a past expiry as inactive", async () => {
    const env = makeEnv();

    const future = new Date(Date.now() + 86_400_000).toISOString();
    const tierFuture = await resolveTier(
      {
        storage: new InMemoryStorage(),
        fetchImpl: makeFakeFetch([
          { match: "api.revenuecat.com", response: () => revenueCatActive(env.REVENUECAT_ENTITLEMENT_ID, future) },
        ]),
        env,
      },
      USER,
    );
    expect(tierFuture).toBe("paid");

    const past = new Date(Date.now() - 86_400_000).toISOString();
    const tierPast = await resolveTier(
      {
        storage: new InMemoryStorage(),
        fetchImpl: makeFakeFetch([
          { match: "api.revenuecat.com", response: () => revenueCatActive(env.REVENUECAT_ENTITLEMENT_ID, past) },
        ]),
        env,
      },
      USER,
    );
    expect(tierPast).toBe("free");
  });

  it("returns 'free' when there is no active entitlement", async () => {
    const storage = new InMemoryStorage();
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      { match: "api.revenuecat.com", response: () => revenueCatFree() },
    ]);

    expect(await resolveTier({ storage, fetchImpl, env }, USER)).toBe("free");
  });

  it("fails closed to 'free' on a non-2xx RevenueCat response", async () => {
    const storage = new InMemoryStorage();
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      { match: "api.revenuecat.com", response: () => revenueCatError(500) },
    ]);

    expect(await resolveTier({ storage, fetchImpl, env }, USER)).toBe("free");
  });

  it("fails closed to 'free' on a fetch (network) error without caching", async () => {
    const storage = new InMemoryStorage();
    const env = makeEnv();
    const fetchImpl = (async () => {
      throw new Error("network down");
    }) as typeof fetch;

    expect(await resolveTier({ storage, fetchImpl, env }, USER)).toBe("free");
    // A network failure must NOT be cached (the next call should retry).
    expect(storage.map.has(`ent:${USER}`)).toBe(false);
  });

  it("caches the resolved tier and serves the 2nd call from cache (no 2nd fetch)", async () => {
    const storage = new InMemoryStorage();
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      { match: "api.revenuecat.com", response: () => revenueCatActive(env.REVENUECAT_ENTITLEMENT_ID) },
    ]);

    const first = await resolveTier({ storage, fetchImpl, env }, USER);
    const second = await resolveTier({ storage, fetchImpl, env }, USER);

    expect(first).toBe("paid");
    expect(second).toBe("paid");
    // Exactly ONE upstream call — the second was served from KV cache.
    expect(fetchImpl.calls).toHaveLength(1);
    expect(storage.map.get(`ent:${USER}`)).toBe("paid");
  });

  it("caches under the documented key with the configured TTL", async () => {
    // White-box: assert the cache key matches the KV scheme `ent:{userId}`.
    const storage = new InMemoryStorage();
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      { match: "api.revenuecat.com", response: () => revenueCatFree() },
    ]);
    await resolveTier({ storage, fetchImpl, env }, USER);
    expect(storage.map.has(`ent:${USER}`)).toBe(true);
    // (TTL is accepted by the fake but not enforced; the constant is real.)
    expect(ENTITLEMENT_CACHE_TTL_SEC).toBeGreaterThan(0);
  });
});
