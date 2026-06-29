# Gist deployment

How to deploy the **backend** (Cloudflare Worker) and ship the **iOS** app. Every
tunable referenced here is defined once in [`CONFIG.md`](./CONFIG.md); the HTTP
contract is in [`API_CONTRACT.md`](./API_CONTRACT.md).

---

## Backend (Cloudflare Worker)

The Worker holds the model credentials, injects the brevity prompt, and enforces
the daily volume cap. It needs one KV namespace and a handful of secrets.

### Prerequisites

- A Cloudflare account and [`wrangler`](https://developers.cloudflare.com/workers/wrangler/)
  (`npm install` in `backend/` provides it as a dev dependency).
- An inference provider account (OpenRouter by default).
- A RevenueCat account with the secret REST key.

### 1. Create the KV namespace

A single namespace named **`COUNTERS`** holds everything; key prefixes separate
concerns (`count:`, `spend:`, `rl:`, `ent:` — see `CONFIG.md`).

```bash
cd backend
npx wrangler kv namespace create COUNTERS
# also create the preview namespace used by `wrangler dev`:
npx wrangler kv namespace create COUNTERS --preview
```

Wrangler prints an `id` (and `preview_id`). Put them in `wrangler.toml` as the
`COUNTERS` binding:

```toml
# wrangler.toml
name = "gist-backend"
main = "src/index.ts"
compatibility_date = "2024-09-23"

[[kv_namespaces]]
binding = "COUNTERS"
id = "<the id from the create command>"
preview_id = "<the preview_id from the create command>"
```

> TODO: A human must paste the real `id` / `preview_id` from the commands above.

### 2. Set the secrets

Secrets are **never** committed. Locally, put them in `backend/.dev.vars`
(git-ignored); in production, set them with `wrangler secret put`. The variable
names are exactly those in `CONFIG.md`:

```bash
# Production secrets (run once each; wrangler prompts for the value):
npx wrangler secret put MODEL_BASE_URL            # e.g. https://openrouter.ai/api/v1
npx wrangler secret put MODEL_API_KEY             # inference provider key — NEVER in the client
npx wrangler secret put REVENUECAT_API_KEY        # RevenueCat SECRET REST key (sk_…)
npx wrangler secret put REVENUECAT_ENTITLEMENT_ID # e.g. premium (must match the iOS entitlementId)
npx wrangler secret put MODEL_HTTP_REFERER        # optional; OpenRouter attribution
```

For local development, create `.dev.vars` from the example and fill it in:

```bash
cp .dev.vars.example .dev.vars   # then edit
npm run dev                       # local Worker on http://localhost:8787
```

> TODO: Supply real values for `MODEL_API_KEY` and `REVENUECAT_API_KEY` (and the
> base URL / entitlement id for your environment).

### 3. Deploy

```bash
npm test            # run the unit tests first
npx wrangler deploy # publish the Worker
```

Verify with the health check (`API_CONTRACT.md`):

```bash
curl https://<your-worker-domain>/health
# → {"status":"ok","version":"1.0.0"}
```

### Choosing the inference provider

The provider is just the `MODEL_BASE_URL` / `MODEL_API_KEY` pair, because the
Worker calls an **OpenAI-compatible** `/chat/completions` endpoint. Swapping
providers is a secret change with **no client release**. Production must **not**
route through Z.ai's hosted cloud (China infra / National Intelligence Law / GDPR
— see [`SECURITY.md`](./SECURITY.md)).

| Provider | `MODEL_BASE_URL` | Notes |
|----------|------------------|-------|
| **OpenRouter** (default) | `https://openrouter.ai/api/v1` | Western aggregator. Set `MODEL_HTTP_REFERER` for attribution. Default in `CONFIG.md`. |
| **Together AI** | `https://api.together.xyz/v1` | OpenAI-compatible; check the exact GLM model slug in their catalog. |
| **Self-hosted vLLM** | `http://<your-host>:8000/v1` | Run the MIT-licensed GLM open weights on **EU** infra for the strongest data-residency story. `MODEL_API_KEY` is whatever token your vLLM is configured with. |

> Whatever the provider, confirm the exact `MODEL_NAME` slug against that
> provider's catalog before launch — slugs differ across providers.

### Choosing the model + the two cost levers

Pick a **small** GLM variant — **not** the flagship coding/agent model. Lighter
candidates, in rough order of increasing capability/cost (`CONFIG.md`):
`thudm/glm-4-9b-chat`, `z-ai/glm-4-flash`, `z-ai/glm-4.5-air` (default). Because
`MODEL_NAME` is one constant, upgrading later is a one-line change + redeploy.

Spend is controlled by **two levers**, both single constants in
`backend/src/config.ts`:

1. **`FREE_DAILY_MESSAGE_LIMIT`** (default `20`) — the *primary* lever. It caps
   free messages per user per local day, directly bounding per-user volume.
2. **`MAX_OUTPUT_TOKENS`** (default `200`) — the per-answer backstop. Brevity
   already comes from the prompt; this just guarantees no single answer runs away
   on cost.

The **global circuit breaker** (`DAILY_SPEND_CEILING_EUR`, default `€50`) is the
aggregate safety net: once estimated daily spend hits it, **new free** requests
get `503` while paid traffic continues. Tune all three to your budget; lower the
free limit or the spend ceiling to spend less.

---

## iOS (App Store)

### 1. App Store Connect — the monthly subscription product

1. Create the app record (bundle id **`app.gist`**, matching `project.yml`).
2. Under **Monetization → Subscriptions**, create a subscription group and an
   **auto-renewable monthly** product with id **`app.gist.premium.monthly`**
   (matching `AppConfig.monthlyProductId`).
3. Set the **price** in App Store Connect — the price is configured in the store,
   **not** in code. `AppConfig.priceHint` (`€2.99 / month`) is only a display
   fallback shown until the real localized price loads.
4. Provide subscription metadata (display name, description, review screenshot).

### 2. RevenueCat wiring

RevenueCat is the entitlement source of truth and is verified **server-side**
(`SECURITY.md`).

1. In RevenueCat, create the project and add the App Store app, linking the
   `app.gist.premium.monthly` product.
2. Create the **entitlement** (e.g. `premium`). Its id must match **both**
   `AppConfig.entitlementId` (client) **and** the backend's
   `REVENUECAT_ENTITLEMENT_ID` secret — if these drift, paid users are never
   recognized.
3. Attach the product to an **offering** (RevenueCat's `current` offering is what
   `SubscriptionManager.loadOfferings()` reads).
4. Put the **public** SDK key (`appl_…`) in `AppConfig.revenueCatPublicKey`, and
   the **secret** REST key in the backend's `REVENUECAT_API_KEY`. Never swap them.

> TODO: Replace the `appl_REPLACE_ME` placeholder in
> `ios/Gist/Config/AppConfig.swift` with your real RevenueCat public key, and set
> `AppConfig.backendBaseURL` to your deployed Worker.

### 3. Build & submit

```bash
cd ios
brew install xcodegen     # one-time
xcodegen generate         # produces Gist.xcodeproj (git-ignored)
open Gist.xcodeproj
```

Select your signing team (the `DEVELOPMENT_TEAM` placeholder in `project.yml` is
empty by default), then **Product → Archive** and upload via the Organizer /
Transporter to App Store Connect / TestFlight.

### 4. Required paywall disclosures

Apple **requires** the paywall to disclose subscription terms, and apps that omit
them are rejected. The paywall (and/or adjacent screens) must include:

- **What is offered:** the subscription name, that it grants effectively
  unlimited daily messages (brevity is unchanged — there is no "longer answers"
  upsell), the **localized price** (from the store), and the billing period
  (monthly).
- **Auto-renewal terms:** the subscription auto-renews unless turned off at least
  24 hours before the period ends; the account is charged for renewal within
  24 hours of the period end; manage/cancel in the App Store account settings.
- **A Restore Purchases control** (wired to `SubscriptionManager.restore()`).
- **Functional links** to the **Privacy Policy** and **Terms of Use (EULA)** —
  Apple requires both to be reachable from the paywall. If you use Apple's
  standard EULA, link to it; otherwise link your own.

> TODO: Provide hosted Privacy Policy and Terms of Use URLs and wire them into the
> paywall view before submission.
