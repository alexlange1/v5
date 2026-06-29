# Gist backend

A thin **Cloudflare Worker** that exists for exactly three reasons:

1. **Hold the model credentials** — the inference API key never reaches the client.
2. **Inject the brevity system prompt** — the under-100-word rule is enforced
   server-side and cannot be edited away in the app.
3. **Enforce the daily volume cap** — per-user daily counts live in Cloudflare KV.

It speaks the contract in [`../docs/API_CONTRACT.md`](../docs/API_CONTRACT.md) and
its tunables live in [`../docs/CONFIG.md`](../docs/CONFIG.md) (mirrored in
`src/config.ts`). Everything length-related (brevity) and volume-related (the
daily cap) is a **server-side** trust boundary; the client may show a remaining
count for UX only.

## Layout

```
backend/
├── src/
│   ├── index.ts            ← Worker entry: routing + dep wiring + CORS
│   ├── config.ts           ← every tunable constant + the system prompt
│   ├── types.ts            ← Env, request/SSE wire types
│   ├── handlers/
│   │   ├── chat.ts         ← POST /v1/chat — the orchestration
│   │   └── health.ts       ← GET /health
│   └── lib/                ← storage, model, entitlement, rate-limit, etc.
└── test/                   ← vitest unit tests (pure logic; fakes for KV/fetch)
```

## Prerequisites

- **Node 22+** and npm.
- A **Cloudflare account** + `wrangler` (installed as a dev dependency below).
- An **OpenAI-compatible** inference provider (default: OpenRouter).
- A **RevenueCat** project with a server-side (secret) REST key.

## Install

```bash
cd backend
npm install
```

> No runtime dependencies are bundled — the Worker uses only the Workers runtime
> and global Web APIs. The `devDependencies` are just the toolchain (TypeScript,
> vitest, wrangler, type packages).

## Configure

### 1. Create the KV namespace

```bash
npx wrangler kv namespace create COUNTERS
```

Copy the printed `id` into `wrangler.toml` (replace
`REPLACE_WITH_KV_NAMESPACE_ID`). A single namespace holds daily counts, the
global spend estimate, rate-limit windows, and the entitlement cache — key
prefixes (`count:` / `spend:` / `rl:` / `ent:`) separate concerns.

### 2. Non-secret variables

`wrangler.toml → [vars]` already ships safe defaults:

| Var                         | Default                          |
|-----------------------------|----------------------------------|
| `MODEL_BASE_URL`            | `https://openrouter.ai/api/v1`   |
| `REVENUECAT_ENTITLEMENT_ID` | `premium`                        |
| `MODEL_HTTP_REFERER`        | `""` (optional attribution)      |

### 3. Secrets (never committed)

Set the two secret keys per environment:

```bash
npx wrangler secret put MODEL_API_KEY        # inference provider key (e.g. sk-or-...)
npx wrangler secret put REVENUECAT_API_KEY   # RevenueCat SECRET REST key (sk_...)
```

For **local development**, copy the example file and fill it in instead — it is
gitignored and loaded automatically by `wrangler dev`:

```bash
cp .dev.vars.example .dev.vars
# edit .dev.vars: MODEL_API_KEY, REVENUECAT_API_KEY, ...
```

## Run locally

```bash
npm run dev            # wrangler dev → http://localhost:8787
```

Smoke test:

```bash
curl http://localhost:8787/health
# {"status":"ok","version":"1.0.0"}

curl -N http://localhost:8787/v1/chat \
  -H 'Content-Type: application/json' \
  -H 'X-Gist-User: demo-user' \
  -d '{"userId":"demo-user","timezone":"Europe/Berlin","messages":[{"role":"user","content":"Capital of France?"}]}'
```

## Test

The tests are **pure logic** — the handler and libs depend only on injected deps
(a `Storage`, a `fetch`, a clock) and global Web APIs. They run under the plain
`node` vitest environment, with **no workerd / wrangler runtime** required.

```bash
npm test               # vitest run (one-shot)
npm run test:watch     # vitest (watch mode)
npm run typecheck      # tsc --noEmit
```

Coverage includes: timezone day-key + reset math, request validation, the daily
counter / rate-limit / circuit-breaker stores, entitlement resolution (with
fail-closed + caching), the streaming model client, and the full chat handler
end-to-end (free/paid caps, rate limit, circuit breaker, and pre-stream refund).

## Deploy

```bash
npm run deploy         # wrangler deploy
```

Ensure the KV namespace id and both secrets are set for the target environment
first (see **Configure** above).

## Swapping the model provider / endpoint

The model is reached over an **OpenAI-compatible** API, so switching providers is
configuration, not code:

- **Endpoint / provider:** change `MODEL_BASE_URL` (in `wrangler.toml [vars]` for
  prod, or `.dev.vars` locally) and set the matching `MODEL_API_KEY` secret.
  Examples: OpenRouter (`https://openrouter.ai/api/v1`, default), Together, or a
  self-hosted vLLM (`https://your-host/v1`).
- **Model slug:** edit `MODEL_NAME` in `src/config.ts` (a one-line change — keep
  it a **small** GLM variant, not the flagship; see the note in
  [`../docs/CONFIG.md`](../docs/CONFIG.md)) and redeploy.
- **Generation knobs:** `MAX_OUTPUT_TOKENS` and `MODEL_TEMPERATURE`, also in
  `src/config.ts`.

> **Data residency:** production traffic must not route through Z.ai's hosted
> cloud. Default to OpenRouter (Western) or self-host the open weights on EU
> infra. See [`../docs/SECURITY.md`](../docs/SECURITY.md).

The brevity system prompt itself lives in `src/config.ts → SYSTEM_PROMPT` and is
injected on every call regardless of provider.
```
