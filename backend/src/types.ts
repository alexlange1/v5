/**
 * Shared types for the Gist Worker backend.
 *
 * The wire contract (request body, SSE event shapes, error codes) mirrors
 * `docs/API_CONTRACT.md` exactly. Keep these in sync with that document.
 */

/**
 * Cloudflare Worker environment bindings + secrets.
 *
 * - `COUNTERS` is the single KV namespace (daily counts + global spend +
 *   rate-limit windows + entitlement cache; key prefixes separate concerns).
 * - The rest are env vars / secrets and must NEVER reach client code.
 */
export interface Env {
  /** KV namespace bound in `wrangler.toml`. */
  COUNTERS: KVNamespace;

  /** OpenAI-compatible base URL, e.g. `https://openrouter.ai/api/v1`. */
  MODEL_BASE_URL: string;
  /** Inference provider key. Never shipped to client. */
  MODEL_API_KEY: string;
  /** RevenueCat secret REST key (server-side). */
  REVENUECAT_API_KEY: string;
  /** The entitlement id that grants unlimited volume, e.g. `premium`. */
  REVENUECAT_ENTITLEMENT_ID: string;
  /** Optional, for OpenRouter attribution headers. */
  MODEL_HTTP_REFERER: string;
}

/** Entitlement tiers. Free is volume-capped; paid is effectively unlimited. */
export type Tier = "free" | "paid";

/**
 * A single conversation turn. The `system` role is added by the backend and is
 * never accepted from the client — hence only `user`/`assistant` here.
 */
export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

/** Body of `POST /v1/chat`. */
export interface ChatRequest {
  /** Anonymous device UUID or Apple sub. Must match the `X-Gist-User` header. */
  userId: string;
  /** IANA tz reported by the device; drives the daily reset. */
  timezone: string;
  /** Full conversation the client wants answered. Non-empty, ends with `user`. */
  messages: ChatMessage[];
  /** Optional, for diagnostics. */
  clientVersion?: string;
}

/**
 * Shared error-code enum (see API_CONTRACT.md). Each maps to a fixed HTTP
 * status; the client decides behaviour from the status (+ SSE event names).
 */
export type ErrorCode =
  | "daily_limit_reached"
  | "rate_limited"
  | "circuit_open"
  | "invalid_request"
  | "upstream_error"
  | "internal_error";

// ---------------------------------------------------------------------------
// SSE payload types (the JSON inside each `data:` line)
// ---------------------------------------------------------------------------

/** `event: meta` — emitted FIRST, before any token. */
export interface MetaEvent {
  tier: Tier;
  /** Count after reserving this message. */
  used: number;
  /** The active cap for this tier. */
  limit: number;
  /** `limit - used`, clamped at 0. */
  remaining: number;
  /** Next local midnight, ISO-8601 with offset. */
  resetAt: string;
}

/** `event: delta` — a chunk of the answer; chunks concatenate. */
export interface DeltaEvent {
  text: string;
}

/** `event: done` — terminal success event. */
export interface DoneEvent {
  /** `stop` = natural end, `length` = hit the token cap. */
  finishReason: "stop" | "length";
  used: number;
  remaining: number;
}

/** `event: error` — mid-stream failure; the count stays consumed. */
export interface ErrorEvent {
  code: ErrorCode;
  message: string;
}
