import { describe, it, expect } from "vitest";

import { handleChat, type ChatDeps } from "../src/handlers/chat";
import {
  DAILY_SPEND_CEILING_EUR,
  FREE_DAILY_MESSAGE_LIMIT,
  PAID_DAILY_SOFT_CAP,
  RATE_LIMIT_PER_MINUTE,
} from "../src/config";
import {
  InMemoryStorage,
  fixedClock,
  makeChatRequest,
  makeEnv,
  makeFakeFetch,
  modelErrorResponse,
  modelStreamResponse,
  parseSSE,
  revenueCatActive,
  revenueCatFree,
  type ScriptedResponse,
} from "./helpers/fakes";

// A fixed instant + tz so the local day key is deterministic.
const NOW = new Date("2026-06-29T10:00:00Z"); // 12:00 Berlin (UTC+2 summer)
const TZ = "Europe/Berlin";
const DAY = "2026-06-29";
const USER = "u1";

/** The KV count key the handler reads/writes for our fixed user + day. */
const COUNT_KEY = `count:${USER}:${DAY}`;

/** Build a chat request body for our fixed user/tz. */
function chatBody(content = "Capital of France?") {
  return {
    userId: USER,
    timezone: TZ,
    messages: [{ role: "user", content }],
  };
}

/**
 * Build a `ChatDeps` with the given storage and scripted fetch entries. The
 * RevenueCat entry is provided per-test (free vs paid); the model entry can be
 * overridden for the upstream-error case.
 */
function makeDeps(
  storage: InMemoryStorage,
  scripted: ScriptedResponse[],
): ChatDeps & { fetchImpl: ReturnType<typeof makeFakeFetch> } {
  const env = makeEnv();
  const fetchImpl = makeFakeFetch(scripted);
  return { storage, fetchImpl, now: fixedClock(NOW), env };
}

/** Default model + RevenueCat scripting for a free, successful flow. */
function freeAndModelOk(): ScriptedResponse[] {
  return [
    { match: "api.revenuecat.com", response: () => revenueCatFree() },
    { match: "/chat/completions", response: () => modelStreamResponse(["Paris", "."], "stop") },
  ];
}

/** Default model + RevenueCat scripting for a paid, successful flow. */
function paidAndModelOk(): ScriptedResponse[] {
  return [
    { match: "api.revenuecat.com", response: () => revenueCatActive("premium") },
    { match: "/chat/completions", response: () => modelStreamResponse(["Paris", "."], "stop") },
  ];
}

describe("handleChat — server processing order", () => {
  // (a) free, under the cap → 200 SSE with correct meta/delta/done + counter++.
  it("(a) free under cap → 200 with meta + deltas + done, and increments the counter", async () => {
    const storage = new InMemoryStorage();
    storage.seed(COUNT_KEY, 5); // already used 5 today
    const deps = makeDeps(storage, freeAndModelOk());

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("text/event-stream");

    const events = await parseSSE(res);
    // meta is first.
    expect(events[0].event).toBe("meta");
    expect(events[0].data).toMatchObject({
      tier: "free",
      used: 6, // 5 + this reservation
      limit: FREE_DAILY_MESSAGE_LIMIT,
      remaining: FREE_DAILY_MESSAGE_LIMIT - 6,
      resetAt: "2026-06-30T00:00:00+02:00", // next local (Berlin) midnight after NOW
    });

    // deltas in order, then done.
    const deltas = events.filter((e) => e.event === "delta").map((e) => e.data.text);
    expect(deltas).toEqual(["Paris", "."]);

    const done = events.find((e) => e.event === "done");
    expect(done?.data).toMatchObject({
      finishReason: "stop",
      used: 6,
      remaining: FREE_DAILY_MESSAGE_LIMIT - 6,
    });

    // Counter actually incremented in storage.
    expect(storage.map.get(COUNT_KEY)).toBe("6");
  });

  // (b) free, at the cap → 402 daily_limit_reached, model NOT called.
  it("(b) free at cap → 402 daily_limit_reached and the model is NOT called", async () => {
    const storage = new InMemoryStorage();
    storage.seed(COUNT_KEY, FREE_DAILY_MESSAGE_LIMIT); // exactly at the cap
    const deps = makeDeps(storage, freeAndModelOk());

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(402);
    expect(res.headers.get("Content-Type")).toBe("application/json");
    const body = (await res.json()) as { error: Record<string, unknown> };
    expect(body.error).toMatchObject({
      code: "daily_limit_reached",
      tier: "free",
      limit: FREE_DAILY_MESSAGE_LIMIT,
      used: FREE_DAILY_MESSAGE_LIMIT,
      resetAt: "2026-06-30T00:00:00+02:00", // next local (Berlin) midnight after NOW
    });

    // The model must NOT have been called.
    expect(deps.fetchImpl.calls.some((u) => u.includes("/chat/completions"))).toBe(false);
    // Counter unchanged.
    expect(storage.map.get(COUNT_KEY)).toBe(String(FREE_DAILY_MESSAGE_LIMIT));
  });

  // (c) paid, above the free limit but under the soft cap → 200.
  it("(c) paid above free limit but under soft cap → 200", async () => {
    const storage = new InMemoryStorage();
    storage.seed(COUNT_KEY, FREE_DAILY_MESSAGE_LIMIT + 50); // well past the free cap
    const deps = makeDeps(storage, paidAndModelOk());

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(200);
    const events = await parseSSE(res);
    expect(events[0].event).toBe("meta");
    expect(events[0].data).toMatchObject({
      tier: "paid",
      limit: PAID_DAILY_SOFT_CAP,
      used: FREE_DAILY_MESSAGE_LIMIT + 51,
    });
  });

  // (d) paid, at the soft cap → 402.
  it("(d) paid at the soft cap → 402 daily_limit_reached", async () => {
    const storage = new InMemoryStorage();
    storage.seed(COUNT_KEY, PAID_DAILY_SOFT_CAP); // exactly at the soft cap
    const deps = makeDeps(storage, paidAndModelOk());

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(402);
    const body = (await res.json()) as { error: Record<string, unknown> };
    expect(body.error).toMatchObject({
      code: "daily_limit_reached",
      tier: "paid",
      limit: PAID_DAILY_SOFT_CAP,
      used: PAID_DAILY_SOFT_CAP,
    });
    // Model not called.
    expect(deps.fetchImpl.calls.some((u) => u.includes("/chat/completions"))).toBe(false);
  });

  // (e) rate limited → 429 + Retry-After.
  it("(e) rate limited → 429 with retryAfter + Retry-After header", async () => {
    const storage = new InMemoryStorage();
    // Pre-fill the current minute's rate bucket to the limit so the next request
    // (this one) trips. Compute the same epoch-minute the handler will use.
    const minute = Math.floor(NOW.getTime() / 60000);
    storage.seed(`rl:${USER}:${minute}`, RATE_LIMIT_PER_MINUTE);
    const deps = makeDeps(storage, freeAndModelOk());

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(429);
    expect(res.headers.get("Retry-After")).toBeTruthy();
    const body = (await res.json()) as { error: Record<string, unknown> };
    expect(body.error.code).toBe("rate_limited");
    expect(body.error.retryAfter).toBeGreaterThan(0);
    // Neither entitlement nor model should be consulted after a rate-limit block.
    expect(deps.fetchImpl.calls.some((u) => u.includes("/chat/completions"))).toBe(false);
  });

  // (f) circuit open: free → 503, but paid → 200.
  it("(f) circuit open → 503 for free", async () => {
    const storage = new InMemoryStorage();
    storage.seed(`spend:${DAY}`, DAILY_SPEND_CEILING_EUR); // breaker tripped
    const deps = makeDeps(storage, freeAndModelOk());

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(503);
    const body = (await res.json()) as { error: Record<string, unknown> };
    expect(body.error.code).toBe("circuit_open");
    // Model not called for throttled free traffic.
    expect(deps.fetchImpl.calls.some((u) => u.includes("/chat/completions"))).toBe(false);
  });

  it("(f) circuit open → still 200 for paid", async () => {
    const storage = new InMemoryStorage();
    storage.seed(`spend:${DAY}`, DAILY_SPEND_CEILING_EUR); // breaker tripped
    const deps = makeDeps(storage, paidAndModelOk());

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(200);
    const events = await parseSSE(res);
    expect(events[0].data).toMatchObject({ tier: "paid" });
  });

  // (g) pre-stream upstream error → 502 AND the reserved count is refunded.
  it("(g) pre-stream upstream error → 502 and the counter is refunded to its prior value", async () => {
    const storage = new InMemoryStorage();
    storage.seed(COUNT_KEY, 3); // prior value
    const deps = makeDeps(storage, [
      { match: "api.revenuecat.com", response: () => revenueCatFree() },
      { match: "/chat/completions", response: () => modelErrorResponse(503) },
    ]);

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(502);
    expect(res.headers.get("Content-Type")).toBe("application/json");
    const body = (await res.json()) as { error: Record<string, unknown> };
    expect(body.error.code).toBe("upstream_error");
    // The message must be the friendly string, never an upstream body / stack.
    expect(body.error.message).toBe("The model is unavailable. Please retry.");

    // Counter refunded back to the prior value (reserved then refunded).
    expect(storage.map.get(COUNT_KEY)).toBe("3");
  });

  // Bad request → 400.
  it("rejects a malformed body with 400 invalid_request", async () => {
    const storage = new InMemoryStorage();
    const deps = makeDeps(storage, freeAndModelOk());
    const badReq = new Request("https://api.gist.app/v1/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{ not json",
    });

    const res = await handleChat(badReq, deps);
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: Record<string, unknown> };
    expect(body.error.code).toBe("invalid_request");
  });

  // X-Gist-User header, when present, must match the body userId (contract).
  it("rejects an X-Gist-User header that disagrees with the body userId (400)", async () => {
    const storage = new InMemoryStorage();
    const deps = makeDeps(storage, freeAndModelOk());
    const req = new Request("https://api.gist.app/v1/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Gist-User": "someone-else" },
      body: JSON.stringify(chatBody()),
    });

    const res = await handleChat(req, deps);
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: Record<string, unknown> };
    expect(body.error.code).toBe("invalid_request");
    // Model must not be called when identity is inconsistent.
    expect(deps.fetchImpl.calls.some((u) => u.includes("/chat/completions"))).toBe(false);
  });

  it("accepts a matching X-Gist-User header (200)", async () => {
    const storage = new InMemoryStorage();
    const deps = makeDeps(storage, freeAndModelOk());
    const req = new Request("https://api.gist.app/v1/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Gist-User": USER },
      body: JSON.stringify(chatBody()),
    });

    const res = await handleChat(req, deps);
    expect(res.status).toBe(200);
  });
});

// The global spend circuit breaker must use a single UTC day bucket, NOT the
// requesting user's local day — otherwise the ceiling fragments across timezones.
describe("handleChat — circuit breaker uses a global (UTC) spend bucket", () => {
  // An instant where the user's LOCAL day and the UTC day differ.
  const NOW_LATE = new Date("2026-06-29T23:30:00Z"); // 01:30 next day in Berlin (UTC+2)
  const UTC_DAY = "2026-06-29";
  const LOCAL_DAY = "2026-06-30";

  function lateDeps(scripted: ScriptedResponse[]): ChatDeps & {
    fetchImpl: ReturnType<typeof makeFakeFetch>;
  } {
    return {
      storage: new InMemoryStorage(),
      fetchImpl: makeFakeFetch(scripted),
      now: fixedClock(NOW_LATE),
      env: makeEnv(),
    };
  }

  it("trips when the UTC-day spend bucket is at the ceiling (free)", async () => {
    const deps = lateDeps(freeAndModelOk());
    (deps.storage as InMemoryStorage).seed(`spend:${UTC_DAY}`, DAILY_SPEND_CEILING_EUR);

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(503);
    const body = (await res.json()) as { error: Record<string, unknown> };
    expect(body.error.code).toBe("circuit_open");
  });

  it("does NOT trip when only the local-day bucket is full (proves UTC keying)", async () => {
    const deps = lateDeps(freeAndModelOk());
    // Seed the user's LOCAL day — the wrong key. The breaker reads the UTC bucket,
    // which is empty, so the request must succeed.
    (deps.storage as InMemoryStorage).seed(`spend:${LOCAL_DAY}`, DAILY_SPEND_CEILING_EUR);

    const res = await handleChat(makeChatRequest(chatBody()), deps);

    expect(res.status).toBe(200);
    // And the spend accrues into the UTC bucket, not the local one.
    expect((deps.storage as InMemoryStorage).map.has(`spend:${UTC_DAY}`)).toBe(true);
  });
});
