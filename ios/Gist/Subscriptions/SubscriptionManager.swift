//
//  SubscriptionManager.swift
//  Gist
//
//  The ONLY place in the app that talks to RevenueCat. The rest of the app
//  depends solely on `isSubscribed`, `purchaseMonthly()`, `restore()`, and
//  `priceString` — never on RevenueCat types directly. This keeps the billing
//  vendor swappable and the View layer simple.
//
//  Product model: the paywall is *volume* (free users get a daily message cap;
//  paid users are effectively unlimited). There is no "longer answers" upgrade —
//  brevity is universal (README "Core product rules"). Entitlement is the source
//  of truth; the backend independently verifies it via the RevenueCat REST API.
//

import Foundation

// TODO: The RevenueCat Swift SDK is declared as an SPM dependency in
// `ios/project.yml` (XcodeGen). After running `xcodegen generate`, the
// `RevenueCat` module below resolves. Until then this file will not compile.
import RevenueCat

/// Observable façade over RevenueCat for subscription state and purchases.
///
/// Marked `@MainActor` because it publishes UI-facing state. Uses the
/// `@Observable` macro (iOS 17+) so SwiftUI views can observe `isSubscribed`,
/// `priceString`, and `isLoading` directly.
@MainActor
@Observable
final class SubscriptionManager {

    /// Whether the user currently holds the unlimited-volume entitlement.
    ///
    /// Driven entirely by ``AppConfig/entitlementId``. This is the single flag
    /// the rest of the app reads to decide free-vs-paid behavior. Note this is a
    /// UX signal only — the backend independently enforces the cap, so a tampered
    /// client cannot grant itself paid volume.
    private(set) var isSubscribed: Bool = false

    /// Localized price string for the monthly product (e.g. "€2.99").
    ///
    /// Sourced from the store via the loaded offering. Falls back to
    /// ``AppConfig/priceHint`` until offerings load (or if they fail to load).
    private(set) var priceString: String = AppConfig.priceHint

    /// Whether a configure/load/purchase/restore operation is in flight.
    private(set) var isLoading: Bool = false

    /// The current monthly package, cached after `loadOfferings()` so purchase
    /// does not need to re-fetch. Stays inside this file; never exposed.
    private var monthlyPackage: Package?

    /// Whether `configure(apiKey:)` has already run (idempotency guard).
    private var isConfigured = false

    /// User-facing errors from subscription operations.
    enum SubscriptionError: Error {
        /// No purchasable monthly package was available (offerings not loaded
        /// or product not configured in the store).
        case noProductAvailable
        /// The user cancelled the purchase flow.
        case purchaseCancelled
        /// Any other failure; carries a short friendly message.
        case failed(String)

        /// Short, user-presentable copy.
        var userMessage: String {
            switch self {
            case .noProductAvailable:
                return "Subscriptions are unavailable right now. Try again shortly."
            case .purchaseCancelled:
                return "Purchase cancelled."
            case .failed:
                return "Something went wrong with the purchase. Please try again."
            }
        }
    }

    init() {}

    // MARK: - Configuration

    /// Configures the RevenueCat SDK with the public key and syncs initial
    /// entitlement state. Call once, early in app startup.
    ///
    /// - Parameter apiKey: The RevenueCat **public** SDK key
    ///   (``AppConfig/revenueCatPublicKey``).
    func configure(apiKey: String = AppConfig.revenueCatPublicKey) {
        guard !isConfigured else { return }
        isConfigured = true

        Purchases.configure(withAPIKey: apiKey)

        // Pull current entitlement + offerings without blocking the caller.
        Task {
            await refreshSubscriptionStatus()
            await loadOfferings()
        }
    }

    // MARK: - Offerings & price

    /// Loads the current offering and caches the monthly package + its localized
    /// price. Safe to call repeatedly (e.g. when showing the paywall).
    func loadOfferings() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let offerings = try await Purchases.shared.offerings()
            // Prefer the explicit monthly product id, then RevenueCat's
            // `.monthly` convenience, then any first package as a last resort.
            let current = offerings.current
            let package = current?.availablePackages.first {
                $0.storeProduct.productIdentifier == AppConfig.monthlyProductId
            } ?? current?.monthly ?? current?.availablePackages.first

            monthlyPackage = package
            if let package {
                priceString = package.storeProduct.localizedPriceString
            }
        } catch {
            // Keep the fallback price; the paywall remains usable.
            // No raw error is surfaced to the UI.
        }
    }

    // MARK: - Purchase / restore

    /// Purchases the monthly subscription.
    ///
    /// - Throws: ``SubscriptionError`` on cancellation or failure.
    func purchaseMonthly() async throws {
        // Ensure we have a package to buy (offerings may not have loaded yet).
        if monthlyPackage == nil {
            await loadOfferings()
        }
        guard let package = monthlyPackage else {
            throw SubscriptionError.noProductAvailable
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                throw SubscriptionError.purchaseCancelled
            }
            updateSubscription(from: result.customerInfo)
        } catch let subscriptionError as SubscriptionError {
            throw subscriptionError
        } catch {
            // RevenueCat surfaces user cancellation as an error in some paths.
            if let rcError = error as? RevenueCat.ErrorCode, rcError == .purchaseCancelledError {
                throw SubscriptionError.purchaseCancelled
            }
            throw SubscriptionError.failed("\(error)")
        }
    }

    /// Restores previous purchases and refreshes entitlement state.
    ///
    /// - Throws: ``SubscriptionError/failed(_:)`` if restore fails.
    func restore() async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            let info = try await Purchases.shared.restorePurchases()
            updateSubscription(from: info)
        } catch {
            throw SubscriptionError.failed("\(error)")
        }
    }

    // MARK: - Entitlement state

    /// Fetches the latest customer info and updates ``isSubscribed``.
    func refreshSubscriptionStatus() async {
        do {
            let info = try await Purchases.shared.customerInfo()
            updateSubscription(from: info)
        } catch {
            // Fail closed: if we cannot confirm the entitlement, treat as free.
            // The backend is the real enforcement point regardless.
            isSubscribed = false
        }
    }

    /// Derives ``isSubscribed`` from a `CustomerInfo`, checking the configured
    /// entitlement id.
    private func updateSubscription(from info: CustomerInfo) {
        isSubscribed = info.entitlements[AppConfig.entitlementId]?.isActive == true
    }
}
