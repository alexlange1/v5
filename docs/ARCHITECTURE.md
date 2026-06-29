# Gist architecture

How the pieces fit together, and *why* they fit that way. This document is
descriptive — the normative contracts live in [`API_CONTRACT.md`](./API_CONTRACT.md)
and [`CONFIG.md`](./CONFIG.md). Where this doc and those disagree, those win.

## The three components

| Component | Tech | Responsibility |
|-----------|------|----------------|
| **iOS client** | SwiftUI, SwiftData, RevenueCat SDK | One chat screen, on-device history, anonymous identity, paywall UI. Holds **no** model credentials. |
| **Backend proxy** | Cloudflare Worker (TypeScript) | Hold model credentials, inject the brevity system prompt, enforce the daily volume cap, verify entitlement, run the cost circuit breaker. |
| **Model** | A small GLM variant via an OpenAI-compatible endpoint | Generate the (short) completion. URL + key are backend config, swappable without touching the client. |

The Worker exists for exactly three reasons: **hold the key**, **inject the
prompt**, **count the volume**. Everything else is in service of those.

## End-to-end request lifecycle

The single request that matters is `POST /v1/chat`. The client sends the full
conversation it wants answered; the backend runs a fixed, normative sequence
(reproduced from `API_CONTRACT.md` "Server processing order"):

1. **Validate** the JSON body. Malformed → `400 invalid_request`. The body must
   end with a `user` turn; roles are limited to `user`/`assistant`. The system
   prompt is **never** accepted from the client.
   (`backend/src/lib/validate.ts`)
2. **Per-minute rate limit** per `userId` (`RATE_LIMIT_PER_MINUTE`). Exceeded →
   `429 rate_limited` + `Retry-After`. (`backend/src/lib/rate-limit.ts`)
3. **Resolve entitlement** → `tier ∈ {free, paid}` via the RevenueCat REST API,
   **fail-closed to `free`** on any provider error, cached briefly in KV.
   (`backend/src/lib/entitlement.ts`)
4. **Compute the local day key** `YYYY-MM-DD` from the device `timezone` and read
   the user's current count. (`backend/src/lib/timezone.ts`,
   `backend/src/lib/daily-counter.ts`)
5. **Cap check.** Free → `FREE_DAILY_MESSAGE_LIMIT` (20); paid →
   `PAID_DAILY_SOFT_CAP` (500). Over the cap → `402 daily_limit_reached`. **The
   model is not called.** The client renders the 402 as the paywall.
6. **Circuit breaker.** If global estimated daily spend ≥
   `DAILY_SPEND_CEILING_EUR` **and** `tier == free` → `503 circuit_open`. Paid
   traffic is still served. (`backend/src/lib/circuit-breaker.ts`)
7. **Reserve** the message: increment the daily counter **and** add
   `EST_COST_PER_REQUEST_EUR` to the global spend estimate.
8. **Call the model** (OpenAI-compatible, streaming) with `SYSTEM_PROMPT`
   prepended to the sanitized history and `max_tokens = MAX_OUTPUT_TOKENS`.
   (`backend/src/lib/model.ts`)
9. **Stream** the reply to the client as SSE (see below). A pre-stream upstream
   failure **refunds** the reserved count and returns `502`; a mid-stream failure
   emits an SSE `error` event and **keeps** the count consumed.

The handler (`backend/src/handlers/chat.ts`) is written to be **pure with respect
to injected dependencies** — storage, `fetch`, and the clock are all passed in —
so each step is unit-testable without a live KV, network, or wall clock.

### What the client does with the result

The client decides purely from the **HTTP status code**, then (for SSE) from the
**event names** (`ChatService` in `ios/Gist/Networking/ChatService.swift`):

- `200` → parse the SSE stream: `meta` first, then `delta` chunks (concatenated
  into the answer), then `done`.
- `402` → open the paywall (the only status that does).
- Any other non-200 → a friendly inline error with a retry affordance. Raw
  upstream bodies and stack traces are never surfaced.

## The SSE streaming design

Success is **Server-Sent Events**; every *pre-stream* rejection is plain JSON.
This split is deliberate: the client can map the failure path from the status
code alone (and read a small JSON error body), while the success path streams
tokens as they arrive for a responsive, "typing" feel on a small screen.

Event order on a `200 text/event-stream` (exact shapes in `API_CONTRACT.md`):

```
event: meta     ← sent FIRST, before any token
data: {"tier":"free","used":6,"limit":20,"remaining":14,"resetAt":"…+02:00"}

event: delta    ← zero or more; .text chunks concatenate into the answer
data: {"text":"Paris"}

event: done     ← terminal; finishReason ∈ {stop, length}
data: {"finishReason":"stop","used":6,"remaining":14}
```

Design points:

- **`meta` leads.** It carries `used` / `limit` / `remaining` / `resetAt` so the
  client can update its remaining-count UI *before* the first token. That count
  is **UX only** — never a trust boundary (the cap is enforced in step 5).
- **Friendly errors only.** A mid-stream failure becomes an SSE `error` event
  whose `message` is a short, user-presentable string. The client
  (`ChatService.parseSSE`) maps it to a thrown `ChatError.server(message:)` so a
  streaming failure is handled identically to a pre-stream one.
- **Forward-compatible parsing.** Unknown event names and unknown error codes are
  ignored / decoded to `.unknown` rather than crashing, so the backend can add
  events/codes without breaking older clients.
- **Cancellation.** The client stream cancels the underlying network task if the
  consumer stops early (e.g. the user navigates away mid-answer).

## Why history is device-only

Conversation history is stored **only on the device** via SwiftData
(`ios/Gist/Models/ChatMessage.swift`, `ios/Gist/Persistence/PersistenceController.swift`).
There is **no server-side chat storage in v1**. Reasons:

- **Privacy / data residency.** Prompts and answers never sit in our
  infrastructure at rest. The Worker is a *pass-through* proxy: it sees a request,
  forwards it, streams the reply, and keeps only counters — not content. This is
  the strongest possible posture for an EU consumer app (see
  [`SECURITY.md`](./SECURITY.md)).
- **Simplicity & cost.** No accounts, no chat database, no sync service. The
  product is one chat screen; on-device storage is sufficient and free.
- **The client sends history each turn.** Because there is no server memory, the
  client includes the conversation it wants answered in each request. The backend
  trims it to `MAX_HISTORY_MESSAGES` / `MAX_MESSAGE_CHARS` (always preserving the
  latest user turn) before calling the model.

Trade-off: history does not roam across a user's devices. That is an acceptable
v1 limitation and keeps the privacy story clean.

## The timezone-based daily reset

"Daily" means the **user's local calendar day**, not UTC — a Berlin user's free
allowance resets at Berlin midnight, not at 01:00/02:00.

- The device reports its IANA `timezone` (e.g. `Europe/Berlin`) on every request
  (`DeviceIdentity.currentTimezoneIdentifier`).
- The backend computes the local day key `YYYY-MM-DD` for that timezone using
  `Intl.DateTimeFormat` (`backend/src/lib/timezone.ts → localDayKey`). The count
  lives at KV key `count:{userId}:{YYYY-MM-DD}` with a 48h TTL
  (`COUNTER_TTL_SECONDS`), so yesterday's key simply expires — there is no reset
  job.
- `resetAt` (next local midnight, ISO-8601 **with offset**) is computed by
  `nextLocalMidnightISO`, which handles DST transitions, and is returned in the
  `meta`/`done` events and the 402 body so the client can say exactly when the
  user's messages come back.
- Invalid / unknown timezones fall back to UTC rather than throwing.

Note this is intentionally a *soft* boundary: a user who changes timezones could
nudge their reset. That is fine — the daily cap is a cost lever, not a security
control, and the global circuit breaker (step 6) is the real spend backstop.

## The reserve / refund counting semantics

The cap is enforced by a counter that is **reserved before** the model call and
**refunded only** when the call produced nothing:

- **Reserve (step 7):** after the cap check passes, increment
  `count:{userId}:{localDay}` and add `EST_COST_PER_REQUEST_EUR` to
  `spend:{utcDay}`. The count uses the user's **local** day (so the allowance
  resets at their local midnight); the global spend uses a fixed **UTC** day so
  the cost ceiling is one shared bucket, not one-per-timezone. Reserving *before*
  the model call means a burst of concurrent requests cannot all slip under the cap.
- **Refund (step 9, pre-stream failure):** if the upstream model call throws
  **before any token**, decrement the count (floored at 0) so the user is not
  charged for a request that yielded nothing, and return `502`.
  (`backend/src/lib/daily-counter.ts → refund`)
- **No refund (step 9, mid-stream failure):** if the stream fails **after** at
  least one token, the count stays consumed — the user received partial value and
  we still paid the provider. The client gets an SSE `error` event.

The spend estimate is deliberately **not** refunded on a pre-stream failure: the
circuit breaker is a coarse safety valve, not an accountant, and a small
over-count biases it conservatively (trips slightly early), which is the safe
direction. KV increments are not atomic, so the counter is best-effort under high
concurrency — acceptable because it is a cost lever, with the breaker as the hard
ceiling.

## ASCII sequence diagram (happy path + the two failure forks)

```
 iOS client (ChatService)        Cloudflare Worker (handleChat)         RevenueCat        Model (OpenAI-compatible)
        │                                  │                                │                        │
        │  POST /v1/chat                   │                                │                        │
        │  X-Gist-User: <userId>           │                                │                        │
        │  {userId,timezone,messages}      │                                │                        │
        │ ───────────────────────────────►│                                │                        │
        │                                  │ 1. validate body               │                        │
        │                                  │ 2. rate-limit (KV rl:…)         │                        │
        │                                  │ 3. resolve tier ──────────────►│                        │
        │                                  │    (cache ent:{userId})        │  subscriber/entitlement│
        │                                  │◄───────────────────────────────│  (fail-closed=free)    │
        │                                  │ 4. dayKey from timezone         │                        │
        │                                  │    read count:{userId}:{day}    │                        │
        │                                  │ 5. cap check                    │                        │
        │                                  │ 6. circuit breaker (free only)  │                        │
        │                                  │ 7. RESERVE count + spend        │                        │
        │                                  │ 8. prepend SYSTEM_PROMPT        │                        │
        │                                  │    stream call ────────────────┼───────────────────────►│
        │                                  │                                │   tokens (stream)       │
        │                                  │◄───────────────────────────────┼─────────────────────────│
        │  200 text/event-stream           │                                │                        │
        │◄─ event: meta ───────────────────│ (used/limit/remaining/resetAt) │                        │
        │◄─ event: delta ──────────────────│ "Paris"                        │                        │
        │◄─ event: delta ──────────────────│ " is the capital…"             │                        │
        │◄─ event: done ───────────────────│ finishReason: stop             │                        │
        │                                  │                                │                        │

  Fork A — over the daily cap (step 5):       Fork B — upstream fails BEFORE any token (step 9):
        │  POST /v1/chat                   │        │  (after RESERVE, step 7)               │
        │ ───────────────────────────────►│        │  stream call ─────────────────────────►│  ✗ error
        │   402 daily_limit_reached (JSON) │        │            REFUND count (decrement)    │
        │◄─────────────────────────────────│        │   502 upstream_error (JSON)            │
        │   → client shows the paywall     │        │◄───────────────────────────────────────│
                                                     │   (mid-stream fail instead → SSE
                                                     │    `error` event, count NOT refunded)
```
