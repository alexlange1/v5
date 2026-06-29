/**
 * Test fakes — everything the handler + libs need injected, implemented with
 * plain in-memory data + standard Web APIs so tests run under `vitest` on Node
 * 22 with NO workerd / wrangler runtime.
 *
 * Provides:
 *   - `InMemoryStorage`     : the `Storage` interface, backed by a Map.
 *   - `makeFakeFetch`       : a scripted `fetch` (RevenueCat JSON + model SSE).
 *   - `fixedClock`          : a `() => Date` that always returns a fixed instant.
 *   - small builders for OpenAI-style SSE bodies and RevenueCat responses.
 */

import type { Storage } from "../../src/lib/storage";
import type { Env } from "../../src/types";

// ---------------------------------------------------------------------------
// InMemoryStorage — a faithful fake of the `Storage` interface.
// ---------------------------------------------------------------------------

/**
 * An in-memory `Storage`. TTLs are accepted for signature-compatibility but
 * intentionally ignored (tests do not exercise expiry). `increment` mirrors the
 * real read-modify-write semantics in `KVStorage`.
 */
export class InMemoryStorage implements Storage {
  /** Exposed for white-box assertions / seeding in tests. */
  readonly map = new Map<string, string>();

  async get(key: string): Promise<string | null> {
    const value = this.map.get(key);
    return value === undefined ? null : value;
  }

  async put(key: string, value: string, _ttlSec?: number): Promise<void> {
    this.map.set(key, value);
  }

  async increment(key: string, _ttlSec?: number): Promise<number> {
    const current = this.map.get(key);
    const parsed = current === undefined ? 0 : Number.parseInt(current, 10);
    const next = (Number.isFinite(parsed) ? parsed : 0) + 1;
    this.map.set(key, String(next));
    return next;
  }

  /** Convenience: directly seed an integer value (e.g. a pre-existing count). */
  seed(key: string, value: string | number): void {
    this.map.set(key, String(value));
  }
}

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------

/** A clock that always returns the same instant. */
export function fixedClock(instant: Date): () => Date {
  return () => new Date(instant.getTime());
}

// ---------------------------------------------------------------------------
// Scripted fetch
// ---------------------------------------------------------------------------

/**
 * One scripted HTTP response. `match` decides whether this entry handles a given
 * request URL; the first matching entry (in order) wins.
 */
export interface ScriptedResponse {
  /** Substring or predicate matched against the request URL. */
  match: string | ((url: string) => boolean);
  /** The `Response` to return, or a factory (so each call gets a fresh body). */
  response: Response | (() => Response);
}

/**
 * Build a fake `fetch` from an ordered list of scripted responses. The returned
 * function records every call on `.calls` for assertions (e.g. "model was NOT
 * called"). An unmatched URL throws — making missing scripting loud, not silent.
 */
export function makeFakeFetch(
  scripted: ScriptedResponse[],
): typeof fetch & { calls: string[] } {
  const calls: string[] = [];

  const impl = (async (input: RequestInfo | URL): Promise<Response> => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : input.url;
    calls.push(url);

    for (const entry of scripted) {
      const hit =
        typeof entry.match === "string" ? url.includes(entry.match) : entry.match(url);
      if (hit) {
        return typeof entry.response === "function" ? entry.response() : entry.response;
      }
    }
    throw new Error(`fakeFetch: no scripted response for URL: ${url}`);
  }) as typeof fetch & { calls: string[] };

  impl.calls = calls;
  return impl;
}

// ---------------------------------------------------------------------------
// Builders: RevenueCat responses
// ---------------------------------------------------------------------------

/**
 * A RevenueCat subscriber response in which the given entitlement is ACTIVE.
 * `expires` may be `null` (lifetime) or an ISO date string in the future.
 */
export function revenueCatActive(
  entitlementId: string,
  expires: string | null = null,
): Response {
  const body = {
    subscriber: {
      entitlements: {
        [entitlementId]: { expires_date: expires },
      },
    },
  };
  return jsonResponse(body, 200);
}

/** A RevenueCat subscriber response with NO active entitlements (free tier). */
export function revenueCatFree(): Response {
  const body = { subscriber: { entitlements: {} } };
  return jsonResponse(body, 200);
}

/** A non-2xx RevenueCat response (handler should fail closed to `free`). */
export function revenueCatError(status = 500): Response {
  return jsonResponse({ message: "rc down" }, status);
}

/** Build a JSON `Response`. */
export function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Builders: model (OpenAI-compatible) streaming responses
// ---------------------------------------------------------------------------

/**
 * Build a `ReadableStream<Uint8Array>` of OpenAI-style SSE chunks:
 *
 *   data: {"choices":[{"delta":{"content":"Paris"}}]}\n\n
 *   ...
 *   data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n
 *   data: [DONE]\n\n
 *
 * Each text chunk becomes one `delta` frame; the final frame carries the
 * `finish_reason`, followed by the terminal `[DONE]` sentinel.
 */
export function openAIStreamBody(
  textChunks: string[],
  finishReason: "stop" | "length" = "stop",
): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();

  const frames: string[] = textChunks.map((text) => {
    const chunk = { choices: [{ delta: { content: text }, finish_reason: null }] };
    return `data: ${JSON.stringify(chunk)}\n\n`;
  });

  // Final chunk carries the finish reason with an empty delta.
  const finalChunk = { choices: [{ delta: {}, finish_reason: finishReason }] };
  frames.push(`data: ${JSON.stringify(finalChunk)}\n\n`);
  frames.push(`data: [DONE]\n\n`);

  return new ReadableStream<Uint8Array>({
    start(controller) {
      for (const frame of frames) {
        controller.enqueue(encoder.encode(frame));
      }
      controller.close();
    },
  });
}

/** A successful streaming model `Response` (200 + SSE body). */
export function modelStreamResponse(
  textChunks: string[],
  finishReason: "stop" | "length" = "stop",
): Response {
  return new Response(openAIStreamBody(textChunks, finishReason), {
    status: 200,
    headers: { "Content-Type": "text/event-stream" },
  });
}

/** A failed (pre-stream) model `Response` — handler should refund + 502. */
export function modelErrorResponse(status = 503): Response {
  return new Response(JSON.stringify({ error: { message: "upstream boom" } }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Env builder
// ---------------------------------------------------------------------------

/** A test `Env`. KV is omitted (handlers take `storage` separately). */
export function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    // `COUNTERS` is never used directly by the handler (it takes `storage`); a
    // cast keeps the type happy without dragging in a KV fake.
    COUNTERS: undefined as unknown as Env["COUNTERS"],
    MODEL_BASE_URL: "https://model.example/api/v1",
    MODEL_API_KEY: "test-model-key",
    REVENUECAT_API_KEY: "test-rc-key",
    REVENUECAT_ENTITLEMENT_ID: "premium",
    MODEL_HTTP_REFERER: "",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// SSE parsing (for asserting on the handler's streamed response body)
// ---------------------------------------------------------------------------

/** One parsed SSE frame: its event name and the JSON-decoded `data` payload. */
export interface ParsedSSEEvent {
  event: string;
  data: Record<string, unknown>;
}

/**
 * Read a `Response` body to a string and parse it into ordered SSE frames.
 * Expects frames of the shape `event: <name>\ndata: <json>\n\n`.
 */
export async function parseSSE(response: Response): Promise<ParsedSSEEvent[]> {
  const text = await response.text();
  const events: ParsedSSEEvent[] = [];

  for (const block of text.split("\n\n")) {
    const trimmed = block.trim();
    if (trimmed === "") continue;

    let event = "message";
    let data = "";
    for (const line of trimmed.split("\n")) {
      if (line.startsWith("event:")) {
        event = line.slice("event:".length).trim();
      } else if (line.startsWith("data:")) {
        data = line.slice("data:".length).trim();
      }
    }
    events.push({ event, data: data ? (JSON.parse(data) as Record<string, unknown>) : {} });
  }

  return events;
}

/**
 * Build a `POST /v1/chat` `Request` with a JSON body. The path is nominal — the
 * handler reads the body + injected deps, not the route.
 */
export function makeChatRequest(body: unknown): Request {
  return new Request("https://api.gist.app/v1/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}
