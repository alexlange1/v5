# Gist

> A mobile-first AI chat app whose entire identity is **brevity**. Every answer is
> capped at **under 100 words**, always — there is no way to make answers longer.
> Length is the product, not a paywalled lever. Monetisation is by **daily message
> volume**, not by answer length.

## Core product rules (invariants — do not violate)

1. **Short is free and permanent.** The under-100-word cap applies to every user,
   free or paid. There is no "unlock longer answers" feature.
2. **The paywall is volume.** Free users get a limited number of messages per day.
   Paid users get effectively unlimited. Everything else is identical.
3. **Brevity and the volume cap are enforced server-side.** The client never holds
   the model API key and is never trusted to count messages.

## Architecture at a glance

```
┌──────────────────────────┐        HTTPS / SSE        ┌────────────────────────────┐
│  iOS app (SwiftUI)        │  ───────────────────────► │  Backend proxy             │
│  • single chat screen     │   POST /v1/chat           │  (Cloudflare Worker)       │
│  • local history (SwiftData)                          │  • inject brevity prompt   │
│  • anonymous device id    │  ◄─────────────────────── │  • count daily volume (KV) │
│  • RevenueCat paywall     │   text/event-stream       │  • verify entitlement (RC) │
└──────────────────────────┘                           │  • circuit breaker         │
                                                        └─────────────┬──────────────┘
                                                                      │ OpenAI-compatible
                                                                      ▼  (swappable)
                                                        ┌────────────────────────────┐
                                                        │  GLM inference             │
                                                        │  OpenRouter (default) /     │
                                                        │  Together / self-host vLLM  │
                                                        └────────────────────────────┘
```

- **Client:** native iOS (SwiftUI). Conversation history is stored **only on the
  device** (SwiftData). No server-side chat storage in v1.
- **Backend:** a thin Cloudflare Worker. It exists for exactly three reasons —
  hold the model credentials, inject the brevity system prompt, and enforce the
  daily volume cap. Per-user daily counts live in Cloudflare KV keyed by
  `count:{userId}:{YYYY-MM-DD}` with a TTL so old keys expire automatically.
- **Model:** a **small** GLM open-weight variant (not the flagship), reached via an
  OpenAI-compatible endpoint. The endpoint URL + credentials live only in backend
  config and are swappable without touching client code.

> **Data residency:** production traffic must **not** route through Z.ai's hosted
> cloud (China infrastructure / National Intelligence Law — a GDPR concern for an
> EU consumer app). Default is OpenRouter (Western); self-hosting the MIT-licensed
> open weights on EU infra is also supported. See `docs/SECURITY.md`.

## Repository layout

```
.
├── README.md                  ← you are here
├── docs/
│   ├── API_CONTRACT.md        ← the HTTP + SSE contract (source of truth)
│   ├── CONFIG.md              ← every tunable constant, in one table
│   ├── ARCHITECTURE.md        ← how the pieces fit, request lifecycle
│   ├── SECURITY.md            ← threat model + data residency
│   └── DEPLOYMENT.md          ← how to deploy the backend & build the app
├── backend/                   ← Cloudflare Worker (TypeScript)
│   ├── src/                   ← worker entry, handlers, lib, config
│   └── test/                  ← vitest unit tests (pure logic, fakes for KV/fetch)
└── ios/                       ← SwiftUI client
    ├── project.yml            ← XcodeGen spec (run `xcodegen generate`)
    └── Gist/                  ← app source
```

## Quick start

**Backend** (see `docs/DEPLOYMENT.md` for the full version):

```bash
cd backend
npm install
cp .dev.vars.example .dev.vars   # fill in OPENROUTER_API_KEY, REVENUECAT_API_KEY
npm test                          # run the unit tests
npm run dev                       # local Worker on http://localhost:8787
```

**iOS** (requires macOS + Xcode 15+):

```bash
cd ios
brew install xcodegen            # one-time
xcodegen generate                # produces Gist.xcodeproj
open Gist.xcodeproj
```

## Definition of done

A user can open the app, ask questions, and get useful answers **always under
100 words**. A free user is cut off after the daily cap and shown a paywall. A
paid user is not. The API key is never present in the client, and neither the
brevity rule nor the volume cap can be bypassed by editing the app.

## Status

v1 scaffold. The backend is implemented and unit-tested. The iOS client is
implemented as Xcode-ready source (XcodeGen project spec). See per-package
READMEs for what is wired vs. what needs your store/provider credentials.
