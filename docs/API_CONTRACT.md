# Gist API Contract

This is the **source of truth** shared by the backend and the iOS client. Both
sides must implement exactly this. If you change anything here, change both sides.

All requests are JSON. The chat endpoint responds with **Server-Sent Events
(SSE)** on success and **JSON** on every pre-stream rejection. The client decides
what to do purely from the **HTTP status code** plus, for SSE, the event names.

---

## `POST /v1/chat`

### Request

Headers:

| Header           | Value                                  |
|------------------|----------------------------------------|
| `Content-Type`   | `application/json`                      |
| `X-Gist-User`    | `<userId>` (authoritative identity)     |

Body:

```jsonc
{
  "userId": "string",          // anonymous device UUID, or Apple sub. Must match X-Gist-User.
  "timezone": "Europe/Berlin", // IANA tz reported by the device; drives the daily reset
  "messages": [                // full conversation the client wants answered
    { "role": "user",      "content": "..." },
    { "role": "assistant", "content": "..." }
  ],
  "clientVersion": "1.0.0"     // optional, for diagnostics
}
```

Notes:
- `messages` must be non-empty and end with a `role: "user"` turn.
- Roles are limited to `user` and `assistant`. The **system prompt is added by the
  backend** and must never be accepted from the client.
- The backend may truncate history to a max number of turns/characters (config),
  but always preserves the latest user turn.

### Server processing order (normative)

1. **Validate** the body. Malformed → `400`.
2. **Per-minute rate limit** per `userId`. Exceeded → `429` + `Retry-After`.
3. **Resolve entitlement** via RevenueCat → `tier ∈ {free, paid}` (fail-closed to
   `free` on provider error; cached briefly in KV).
4. **Compute the local day key** `YYYY-MM-DD` from `timezone`; read the user's count.
5. **Cap check.** Free → `FREE_DAILY_MESSAGE_LIMIT`; paid → `PAID_DAILY_SOFT_CAP`.
   Over the cap → `402` `daily_limit_reached`. **Model is not called.**
6. **Circuit breaker.** If global estimated daily spend ≥ `DAILY_SPEND_CEILING_EUR`
   **and** `tier == free` → `503` `circuit_open`. Paid traffic is still served.
7. **Reserve** the message (increment the daily counter + global spend estimate).
8. **Call the model** (OpenAI-compatible, streaming) with the injected system
   prompt + sanitized messages, `max_tokens = MAX_OUTPUT_TOKENS`.
9. **Stream** the reply to the client as SSE. If the upstream model call fails
   **before any token** is produced, **refund** the reserved count and return the
   error as a normal HTTP error (`502`). If it fails **mid-stream**, emit an SSE
   `error` event and keep the count consumed.

### Responses

#### Success → `200 text/event-stream`

Events are emitted in this order. Each `data:` payload is a single-line JSON object.

```
event: meta
data: {"tier":"free","used":6,"limit":20,"remaining":14,"resetAt":"2026-06-29T00:00:00+02:00"}

event: delta
data: {"text":"Paris"}

event: delta
data: {"text":" is the capital of France."}

event: done
data: {"finishReason":"stop","used":6,"remaining":14}
```

- `meta` is sent **first**, before any token, so the client can update its local
  remaining-count UI immediately.
- `delta.text` chunks concatenate into the full answer.
- `done.finishReason` is one of `stop` | `length` (length = hit the token cap).
- Mid-stream failure:

```
event: error
data: {"code":"upstream_error","message":"The model is unavailable. Please retry."}
```

#### Daily limit reached → `402 application/json`

```jsonc
{
  "error": {
    "code": "daily_limit_reached",
    "message": "You've used all your free messages for today.",
    "tier": "free",
    "limit": 20,
    "used": 20,
    "resetAt": "2026-06-29T00:00:00+02:00"  // next local midnight, ISO-8601 w/ offset
  }
}
```
The client renders this as the **paywall prompt**.

#### Rate limited → `429 application/json`

```jsonc
{ "error": { "code": "rate_limited", "message": "Slow down a moment.", "retryAfter": 12 } }
```
Also sets the `Retry-After: 12` header (seconds).

#### Circuit breaker open → `503 application/json`

```jsonc
{ "error": { "code": "circuit_open", "message": "We're at capacity right now. Try again shortly." } }
```

#### Bad request → `400` / Upstream failure → `502` / Internal → `500`

```jsonc
{ "error": { "code": "invalid_request" | "upstream_error" | "internal_error", "message": "..." } }
```

> The backend must **never** leak raw stack traces or upstream error bodies. The
> `message` field is always a short, friendly, user-presentable string.

---

## `GET /health`

```jsonc
200 { "status": "ok", "version": "1.0.0" }
```

---

## Error code enum (shared)

| code                  | HTTP | Client behaviour                          |
|-----------------------|------|-------------------------------------------|
| `daily_limit_reached` | 402  | Show paywall                              |
| `rate_limited`        | 429  | Inline "slow down", offer retry           |
| `circuit_open`        | 503  | Inline "at capacity", offer retry         |
| `invalid_request`     | 400  | Inline generic error (should not happen)  |
| `upstream_error`      | 502  | Inline "model unavailable", offer retry   |
| `internal_error`      | 500  | Inline generic error, offer retry         |

The client treats **any** non-200, non-402 as a retryable inline error with a
friendly message; 402 is the only status that opens the paywall.
