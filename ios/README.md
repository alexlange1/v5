# Gist — iOS client

A SwiftUI app whose entire identity is **brevity**: every answer is capped at
**under 100 words**, always. The cap and the daily volume limit are enforced
**server-side** (see `../docs/API_CONTRACT.md`); the client never holds the model
API key and is never trusted to count messages or limit length.

The Xcode project is **generated** from [`project.yml`](./project.yml) with
[XcodeGen](https://github.com/yonomey/XcodeGen) — `Gist.xcodeproj` is **not**
checked in (it is git-ignored). Regenerate it any time `project.yml` changes.

## Requirements

- macOS with **Xcode 15+** (the app targets **iOS 17.0** and uses SwiftData and
  the `@Observable` macro).
- [XcodeGen](https://github.com/yonomey/XcodeGen).

## Setup

```bash
# 1. Install XcodeGen (one-time).
brew install xcodegen

# 2. Generate the Xcode project from project.yml.
#    Run this from the ios/ directory. It produces Gist.xcodeproj and resolves
#    the RevenueCat Swift Package dependency.
xcodegen generate

# 3. Open it.
open Gist.xcodeproj
```

## Configure before running

Two values must be supplied before the app is useful. Both live in
[`Gist/Config/AppConfig.swift`](./Gist/Config/AppConfig.swift) as `// TODO`
markers (in a real deployment, move these into an `xcconfig` so dev/staging/prod
differ):

1. **Backend URL** — `AppConfig.backendBaseURL`. Point this at your deployed
   Cloudflare Worker (or `http://localhost:8787` for local backend dev; note that
   plain-HTTP localhost needs an ATS exception during development).
2. **RevenueCat public SDK key** — `AppConfig.revenueCatPublicKey` (begins with
   `appl_`). This is the **public** client key, safe to embed. The RevenueCat
   **secret** REST key is backend-only and must never appear here.

The model/inference API key is **never** in the client — it lives only in the
backend (`MODEL_API_KEY`). See `../docs/SECURITY.md`.

Signing: the project ships with **automatic** signing and an empty
`DEVELOPMENT_TEAM`. Select your team in Xcode's *Signing & Capabilities* tab (or
set `DEVELOPMENT_TEAM` in `project.yml`) before building to a device or archiving.

## Run on the simulator

After `xcodegen generate` and `open Gist.xcodeproj`:

1. Pick the **Gist** scheme and an iOS 17+ simulator.
2. Press **Run** (⌘R).

To run the tests: **Product → Test** (⌘U), or:

```bash
xcodebuild -project Gist.xcodeproj -scheme Gist \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

## Capabilities

- **Sign in with Apple** and a **keychain-access-group** placeholder are declared
  in [`Gist/Gist.entitlements`](./Gist/Gist.entitlements). Sign in with Apple is
  optional in v1 — it provides a *stable* identity (`userId`) that resists the
  reinstall-resets-the-free-count weakness of an anonymous UUID
  (see `../docs/SECURITY.md`). Update the keychain-access-group string if your
  bundle id differs from `app.gist`.

## Project layout

```
ios/
├── project.yml          ← XcodeGen spec (this is the source of truth)
├── Gist/
│   ├── GistApp.swift     ← @main app entry
│   ├── Info.plist
│   ├── Gist.entitlements ← Sign in with Apple + keychain group
│   ├── Config/           ← AppConfig (URLs, keys, copy)
│   ├── Identity/         ← anonymous device id + Keychain wrapper
│   ├── Networking/       ← ChatService (SSE), API models
│   ├── Models/           ← SwiftData models (on-device history)
│   ├── Persistence/      ← SwiftData container
│   ├── Subscriptions/    ← RevenueCat façade (SubscriptionManager)
│   ├── ViewModels/
│   └── Views/
└── GistTests/            ← dependency-light XCTest cases
```

> `Gist.xcodeproj/` is generated and **git-ignored**. Never edit the project in
> Xcode and commit it; change `project.yml` and re-run `xcodegen generate`.
