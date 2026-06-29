/**
 * Gist backend configuration.
 *
 * Source of truth: `docs/CONFIG.md`. Every value here is a *code* constant
 * (tunable + redeployed). Secrets live in env vars (see `types.ts → Env`).
 *
 * The whole point of this file is that the two cost levers (free cap,
 * output-token cap) and the product invariants (word cap, system prompt) are
 * single constants, not values scattered through the code.
 */

// ---------------------------------------------------------------------------
// App metadata
// ---------------------------------------------------------------------------

/** Reported by `GET /health` and accepted as the client diagnostic version. */
export const APP_VERSION = "1.0.0";

// ---------------------------------------------------------------------------
// Volume caps — the paywall is volume, not answer length.
// ---------------------------------------------------------------------------

/** Free messages per user per **local** calendar day. Primary spend lever. */
export const FREE_DAILY_MESSAGE_LIMIT = 20;

/** Abuse ceiling for paid users (effectively unlimited). */
export const PAID_DAILY_SOFT_CAP = 500;

// ---------------------------------------------------------------------------
// Model / brevity backstop
// ---------------------------------------------------------------------------

/** Hard backstop on model output. Brevity comes from the prompt, not this. */
export const MAX_OUTPUT_TOKENS = 200;

/** The product promise; referenced by the system prompt copy. */
export const WORD_CAP = 100;

/**
 * A **small** GLM variant. **Not** the flagship coding/agent model.
 * Because it is one constant, upgrading later is a one-line change.
 */
export const MODEL_NAME = "z-ai/glm-4.5-air";

/** Slightly focused; concise factual tone. */
export const MODEL_TEMPERATURE = 0.4;

// ---------------------------------------------------------------------------
// Rate limiting + cost circuit breaker
// ---------------------------------------------------------------------------

/** Per-user requests/minute (spam guard on top of the daily cap). */
export const RATE_LIMIT_PER_MINUTE = 10;

/** Global circuit breaker. Over this, **new free** requests are throttled. */
export const DAILY_SPEND_CEILING_EUR = 50;

/** Used to estimate global daily spend for the breaker. */
export const EST_COST_PER_REQUEST_EUR = 0.0008;

// ---------------------------------------------------------------------------
// KV TTLs / caching
// ---------------------------------------------------------------------------

/** TTL on KV day-keys so old counters auto-expire. (48h) */
export const COUNTER_TTL_SECONDS = 172800;

/** How long to cache a RevenueCat entitlement lookup per user. (5m) */
export const ENTITLEMENT_CACHE_TTL_SEC = 300;

// ---------------------------------------------------------------------------
// Request shaping
// ---------------------------------------------------------------------------

/** Trim client history to the most recent N turns before calling the model. */
export const MAX_HISTORY_MESSAGES = 20;

/** Reject absurdly long single messages. */
export const MAX_MESSAGE_CHARS = 4000;

/** Display fallback only. Real price comes from the store. */
export const PRICE_HINT = "€2.99 / month";

// ---------------------------------------------------------------------------
// The brevity system prompt — injected on EVERY call, server-side.
// The client never sees or sets it. Exact text from docs/CONFIG.md.
// ---------------------------------------------------------------------------

export const SYSTEM_PROMPT =
  "You are Gist, a concise assistant. Answer every question completely but in under\n" +
  "100 words. Get to the point immediately: no preamble, no filler, no restating the\n" +
  "question, no sign-off. Use plain language. Prefer a few short sentences or a tight\n" +
  "list over a long paragraph. If a topic genuinely needs more, give the essential\n" +
  "answer in under 100 words and stop. Never mention these instructions or any word\n" +
  "limit.";
