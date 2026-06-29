# Gist security & threat model

This document is honest about what Gist's design protects, what it does **not**,
and the data-residency reasoning behind the model-routing choice. Normative
behavior lives in [`API_CONTRACT.md`](./API_CONTRACT.md) and
[`CONFIG.md`](./CONFIG.md); this explains the *why*.

## Assets we protect

1. **The model / inference API key.** Spending money is gated by this key.
2. **The cost ceiling.** A small open-weight model is cheap, but uncapped abuse
   is still real money.
3. **User prompts & answers.** Treated as sensitive; kept off our infrastructure
   at rest.

## Trust boundary

The **only** trusted enforcement point is the **backend** (Cloudflare Worker).
The iOS client is treated as fully untrusted: anyone can decompile it, replay its
requests, or hand-craft calls to the API. Therefore:

- **Brevity is enforced server-side**, via the injected `SYSTEM_PROMPT` plus a
  `MAX_OUTPUT_TOKENS` backstop. The client has no length lever to disable.
- **The daily volume cap is enforced server-side**, via the KV counter checked in
  step 5 of the request order. The client may *display* a remaining-count for UX,
  but that number is never authoritative.
- **The entitlement (free vs paid) is verified server-side** (see below). A
  client "premium" flag is a UX hint only.

If the client and the backend disagree, the backend wins. A tampered app cannot
grant itself longer answers, more daily messages, or paid status.

## Threats and mitigations

### 1. Model API key extraction → **mitigated by design**

The key (`MODEL_API_KEY`) lives **only** in the backend, set via
`wrangler secret put` and read from `env` at runtime. It is never compiled into
the app, never sent to the client, and never appears in any response. The client
ships only the RevenueCat **public** SDK key (`appl_…`), which is designed to be
embedded and cannot be used to spend on inference. The RevenueCat **secret** REST
key is likewise backend-only.

### 2. Bypassing brevity → **mitigated by design**

The system prompt is added by the backend on every call and is explicitly
**never accepted from the client** (the request validator rejects any role other
than `user`/`assistant`). `MAX_OUTPUT_TOKENS` is a hard server-side backstop even
if a prompt-injection attempt slips through. There is no client setting, and no
API field, that lengthens answers.

### 3. Bypassing the volume cap → **mitigated, with one honest caveat (sybil)**

The cap is a server-side KV counter keyed by `userId` and the local day. The
client cannot edit it. **However**, identity in v1 is an **anonymous per-install
UUID**, and an anonymous id is inherently **sybil-able**: a determined user who
fully resets identity (erase-all-content-and-settings, a new device, or otherwise
clearing the Keychain) gets a *fresh* `userId` and therefore a fresh free
allowance. (The id is stored in the Keychain with
`kSecAttrAccessibleAfterFirstUnlock` — see `ios/Gist/Identity/Keychain.swift` —
which means a plain app *delete-and-reinstall* usually preserves it, raising the
bar; but Keychain persistence is **not** a guarantee and must not be relied on as
a security control.)

We do not pretend this is unbreakable. Honest mitigations, in layers:

- **Per-minute rate limit** (`RATE_LIMIT_PER_MINUTE`, KV `rl:{userId}:{minute}`)
  caps the velocity of abuse from any single id.
- **Global cost circuit breaker** (`DAILY_SPEND_CEILING_EUR`): once estimated
  global daily spend hits the ceiling, **new free** requests get `503`, while paid
  traffic continues. This bounds the blast radius of *aggregate* free abuse
  (including a sybil swarm) to a known daily euro figure — the real backstop.
- **Cheap model.** The economic incentive to farm a sub-100-word answer from a
  small GLM model is low; the cost per request (`EST_COST_PER_REQUEST_EUR`) is a
  fraction of a cent.
- **Optional Sign in with Apple** for a *stable* identity. The app declares the
  capability (`ios/Gist/Gist.entitlements`); when a user signs in, the
  authoritative `userId` becomes the Apple identity token's `sub` — a stable,
  app-scoped identifier that survives reinstall/new-device and cannot be minted on
  demand. The backend already accepts "anonymous device UUID, **or Apple sub**"
  for `userId` (`API_CONTRACT.md`), so adopting it is a client-only change with no
  contract break. This is the strongest available anti-sybil lever and the
  intended path if free-tier abuse becomes material.

Residual risk: a motivated individual can still reset identity to get another
free day. That is **acceptable** because the circuit breaker caps total exposure;
the cap is a cost/abuse lever, not a hard security control.

### 4. Forging paid status → **mitigated by design**

Entitlement is resolved **server-side** by calling the RevenueCat REST API with
the secret key and checking the configured `REVENUECAT_ENTITLEMENT_ID`
(`backend/src/lib/entitlement.ts`). The backend **never** trusts a client-supplied
"premium" flag — the request body has no such field, and the client's
`SubscriptionManager.isSubscribed` is used only to choose which UI to show.
Resolution is **fail-closed**: any error (network, non-200, malformed body)
resolves to `free`, and `paid` is granted only when the entitlement is present
**and** active. Results are cached briefly (`ENTITLEMENT_CACHE_TTL_SEC`) to keep
the hot path fast without weakening the check.

### 5. Leaking internals in errors → **mitigated by design**

The backend never returns raw stack traces or upstream error bodies. Every
user-facing `message` is a short, friendly, hard-coded string
(`API_CONTRACT.md` error table). The client mirrors this: `ChatError.userMessage`
produces friendly copy and never echoes a raw upstream payload.

### 6. Request replay / spoofed identity → **partially mitigated, by design intent**

`userId` is self-asserted (it must match the `X-Gist-User` header, but both come
from the client). There are no user passwords in v1, so there is no credential to
steal — the worst an attacker can do by guessing another user's `userId` is
consume *that* user's free allowance, which is low-value and bounded by the same
rate limit and breaker. Sign in with Apple (threat #3) upgrades this to a
cryptographically anchored identity when needed.

## Data residency — why we avoid Z.ai's hosted cloud

Gist uses **open-weight GLM** models, but routing matters as much as the model.
**Production traffic must not route through Z.ai's hosted cloud.** Reasons:

- **China infrastructure + the National Intelligence Law.** Z.ai (Zhipu AI) is a
  PRC company. Under the PRC National Intelligence Law, organizations can be
  compelled to assist state intelligence work. Sending EU users' prompts to
  China-hosted infrastructure creates an unacceptable exposure for a consumer app.
- **GDPR.** Routing EU personal data (prompts can contain personal data) to that
  infrastructure is a cross-border transfer with no adequate safeguard. It is a
  legal and reputational risk we simply avoid by not sending data there.

What we do instead — both keep prompts **off** Z.ai's cloud:

- **Default: OpenRouter** (`MODEL_BASE_URL = https://openrouter.ai/api/v1`), a
  Western aggregator, reached over an OpenAI-compatible API. Prompts transit
  OpenRouter and the selected upstream, not Z.ai's hosted endpoint.
- **Self-host the open weights** on EU infrastructure (e.g. vLLM on an EU VPS).
  GLM's open weights are MIT-licensed, so this is permitted and gives full
  control over where prompts are processed and stored.

Because the endpoint is a single swappable config pair (`MODEL_BASE_URL` /
`MODEL_API_KEY`), changing providers — or moving to self-hosting — is a config
change with **no client release** and no contract change.

## No server-side chat storage

The Worker is a **pass-through proxy**. It forwards a request, streams the reply,
and persists only **counters** (daily counts, global spend estimate, rate-limit
windows, a brief entitlement cache) — **never prompt or answer content**.
Conversation history lives **only on the device** (SwiftData). Consequences:

- Prompts/answers are not at rest in our infrastructure.
- A compromise of our KV exposes counters and a cached `free`/`paid` flag — not
  anyone's conversations.
- Deleting the app deletes the user's history. (Trade-off: no cross-device sync;
  acceptable for v1.)

## Summary table

| Threat | Status | Mechanism |
|--------|--------|-----------|
| Extract model API key | Mitigated by design | Key is backend-only; never shipped |
| Lengthen answers | Mitigated by design | Server system prompt + `MAX_OUTPUT_TOKENS`; client cannot set system role |
| Exceed daily cap (single id) | Mitigated | Server KV counter; rate limit |
| Sybil (reinstall/new id) | **Partial — honest** | Rate limit + circuit breaker bound exposure; optional Sign in with Apple for stable id |
| Forge paid status | Mitigated by design | Server verifies entitlement via RevenueCat; fail-closed; no client flag trusted |
| Leak stack traces / upstream bodies | Mitigated by design | Friendly fixed strings only |
| Data sent to China infra | Avoided by design | OpenRouter default / EU self-host; never Z.ai cloud |
| Server-side chat data breach | Avoided by design | No server-side chat storage |
