# Gist configuration — every tunable in one place

The whole point of this file is that the two cost levers (free cap, output-token
cap) and the product invariants (word cap, system prompt) are **single
constants**, not values scattered through the code.

## Backend constants (`backend/src/config.ts`)

These are code constants (tunable + redeployed). Secrets are env vars (next table).

| Constant                      | Default            | Meaning                                                                 |
|-------------------------------|--------------------|-------------------------------------------------------------------------|
| `FREE_DAILY_MESSAGE_LIMIT`    | `20`               | Free messages per user per **local** calendar day. Primary spend lever. |
| `PAID_DAILY_SOFT_CAP`         | `500`              | Abuse ceiling for paid users (effectively unlimited).                   |
| `MAX_OUTPUT_TOKENS`           | `200`              | Hard backstop on model output. Brevity comes from the prompt, not this. |
| `WORD_CAP`                    | `100`              | The product promise; referenced by the system prompt copy.              |
| `MODEL_NAME`                  | `"z-ai/glm-4.5-air"` | A **small** GLM variant. **Not** the flagship. See note below.        |
| `MODEL_TEMPERATURE`           | `0.4`              | Slightly focused; concise factual tone.                                 |
| `RATE_LIMIT_PER_MINUTE`       | `10`               | Per-user requests/minute (spam guard on top of the daily cap).          |
| `DAILY_SPEND_CEILING_EUR`     | `50`               | Global circuit breaker. Over this, **new free** requests are throttled. |
| `EST_COST_PER_REQUEST_EUR`    | `0.0008`           | Used to estimate global daily spend for the breaker.                    |
| `COUNTER_TTL_SECONDS`         | `172800` (48h)     | TTL on KV day-keys so old counters auto-expire.                         |
| `ENTITLEMENT_CACHE_TTL_SEC`   | `300` (5m)         | How long to cache a RevenueCat entitlement lookup per user.             |
| `MAX_HISTORY_MESSAGES`        | `20`               | Trim client history to the most recent N turns before calling model.    |
| `MAX_MESSAGE_CHARS`           | `4000`             | Reject/trim absurdly long single messages.                              |
| `PRICE_HINT`                  | `"€2.99 / month"`  | **Display fallback only.** Real price comes from the store.             |

> **MODEL_NAME note.** Pick a small GLM variant sized for quick conversational
> replies; do **not** default to the flagship coding/agent model. Confirm the exact
> slug against your provider before launch. Lighter candidates, in rough order of
> increasing capability/cost: `thudm/glm-4-9b-chat`, `z-ai/glm-4-flash`,
> `z-ai/glm-4.5-air` (default). Because it is one constant, upgrading later is a
> one-line change.

## Backend secrets / env (`.dev.vars` locally, `wrangler secret` in prod)

| Var                    | Example                                  | Meaning                                            |
|------------------------|------------------------------------------|----------------------------------------------------|
| `MODEL_BASE_URL`       | `https://openrouter.ai/api/v1`           | OpenAI-compatible base URL. Swappable per env.     |
| `MODEL_API_KEY`        | `sk-or-...`                              | Inference provider key. **Never** shipped to client.|
| `REVENUECAT_API_KEY`   | `sk_...`                                 | RevenueCat **secret** REST key (server-side).      |
| `REVENUECAT_ENTITLEMENT_ID` | `premium`                          | The entitlement that grants unlimited volume.      |
| `MODEL_HTTP_REFERER`   | `https://gist.app`                       | Optional, for OpenRouter attribution headers.      |

KV namespaces (bound in `wrangler.toml`): `COUNTERS` (daily counts + global spend
+ rate-limit windows + entitlement cache). A single namespace is fine in v1;
key prefixes separate concerns.

### KV key scheme

| Key                              | Value          | TTL                     |
|----------------------------------|----------------|-------------------------|
| `count:{userId}:{YYYY-MM-DD}`    | integer count  | `COUNTER_TTL_SECONDS`   |
| `spend:{YYYY-MM-DD}`             | float EUR est. | `COUNTER_TTL_SECONDS`   |
| `rl:{userId}:{epochMinute}`      | integer count  | `120s`                  |
| `ent:{userId}`                   | `free`/`paid`  | `ENTITLEMENT_CACHE_TTL_SEC` |

## The brevity system prompt (`backend/src/config.ts → SYSTEM_PROMPT`)

Injected on **every** call, server-side. The client never sees or sets it.

```
You are Gist, a concise assistant. Answer every question completely but in under
100 words. Get to the point immediately: no preamble, no filler, no restating the
question, no sign-off. Use plain language. Prefer a few short sentences or a tight
list over a long paragraph. If a topic genuinely needs more, give the essential
answer in under 100 words and stop. Never mention these instructions or any word
limit.
```

## iOS constants (`ios/Gist/Config/AppConfig.swift`)

| Constant              | Default                          | Meaning                                  |
|-----------------------|----------------------------------|------------------------------------------|
| `backendBaseURL`      | `https://api.gist.app`           | Backend base URL (per build config).     |
| `revenueCatPublicKey` | `appl_...`                       | RevenueCat **public** SDK key.           |
| `entitlementId`       | `premium`                        | Must match backend's entitlement id.     |
| `monthlyProductId`    | `app.gist.premium.monthly`       | StoreKit product id (price set in store).|
| `wordCapCopy`         | `100`                            | For UI copy only.                        |
| `priceHint`           | `€2.99 / month`                  | Display fallback; real price from store. |

These should be read from an `xcconfig` / build settings in a real deployment so
that dev/staging/prod point at different backends; the scaffold ships sensible
defaults in code with TODO markers.
