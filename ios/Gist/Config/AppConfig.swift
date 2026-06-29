//
//  AppConfig.swift
//  Gist
//
//  Single source of truth for client-side tunables and credentials.
//  These mirror the "iOS constants" table in docs/CONFIG.md.
//
//  In a real deployment these values should be injected from an `xcconfig` /
//  build settings so that dev / staging / prod point at different backends and
//  store keys. The scaffold ships sensible defaults in code, with TODO markers
//  on every credential a human must supply before shipping.
//

import Foundation

/// Compile-time configuration constants for the Gist client.
///
/// Nothing secret lives here: the model API key never reaches the client
/// (see README "Core product rules"). The only key present is the RevenueCat
/// *public* SDK key, which is designed to be embedded in the app.
enum AppConfig {

    /// Backend base URL (per build config).
    ///
    /// All API calls are made relative to this. Override per environment via
    /// `xcconfig` in a real deployment.
    // TODO: Point this at your deployed Cloudflare Worker (dev/staging/prod).
    static let backendBaseURL = URL(string: "https://api.gist.app")!

    /// RevenueCat **public** SDK key (safe to embed in the client binary).
    ///
    /// This is NOT the RevenueCat secret REST key — that one lives only in the
    /// backend. The public key begins with `appl_` for Apple platforms.
    // TODO: Replace with your RevenueCat public SDK key from the RevenueCat dashboard.
    static let revenueCatPublicKey = "appl_REPLACE_ME"

    /// The RevenueCat entitlement that grants unlimited daily volume.
    ///
    /// Must match the backend's `REVENUECAT_ENTITLEMENT_ID` (docs/CONFIG.md).
    static let entitlementId = "premium"

    /// StoreKit / App Store Connect product identifier for the monthly plan.
    ///
    /// The actual price is configured in App Store Connect, not here.
    static let monthlyProductId = "app.gist.premium.monthly"

    /// The word cap used in UI copy only.
    ///
    /// The cap itself is enforced server-side via the injected system prompt;
    /// this constant exists purely so on-screen copy can say "under 100 words".
    static let wordCapCopy: Int = 100

    /// Display fallback price.
    ///
    /// The real, localized price always comes from the store via
    /// `SubscriptionManager.priceString`. This is shown only if offerings have
    /// not loaded yet (or fail to load).
    static let priceHint = "€2.99 / month"

    /// Client version reported to the backend for diagnostics (`clientVersion`
    /// in the chat request). Pulled from the bundle when available.
    static var clientVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return version
    }
}
