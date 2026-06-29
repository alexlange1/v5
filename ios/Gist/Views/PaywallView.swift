//
//  PaywallView.swift
//  Gist
//
//  The subscription paywall, shown when the backend returns 402
//  (daily_limit_reached). It is App-Store-review-compliant: it states the price,
//  the billing period, and that the subscription auto-renews, and it offers a
//  Restore Purchases action plus links to Terms (EULA) and Privacy.
//
//  PRODUCT-CRITICAL COPY (README "Core product rules"): the upgrade buys MORE
//  MESSAGES PER DAY — nothing else. Short answers are free forever; there is no
//  "longer answers" upgrade and the under-100-word cap applies to everyone, paid
//  or free. The copy below must always reflect this. Do not add language implying
//  paid users get longer/different answers.
//

import SwiftUI

/// The subscription paywall sheet.
///
/// All purchase logic is delegated to ``SubscriptionManager`` (the only place
/// that touches RevenueCat). The price string comes from the live store offering
/// with ``AppConfig/priceHint`` as a fallback until offerings load.
struct PaywallView: View {

    /// Subscription façade from the environment (price, purchase, restore).
    @Environment(SubscriptionManager.self) private var subscriptions
    /// Lets the sheet dismiss itself.
    @Environment(\.dismiss) private var dismiss

    /// Optional context from the 402 (how many were used, when they reset). Used
    /// only to make the headline more specific; the offer is the same regardless.
    let limitInfo: LimitInfo?

    /// Transient error copy from a failed purchase/restore, shown inline.
    @State private var errorMessage: String?

    // TODO: Replace these placeholder URLs with your real, hosted legal pages
    // before submitting to App Review. The EULA (Terms of Use) and Privacy Policy
    // links are REQUIRED for an auto-renewing subscription.
    private let termsURL = URL(string: "https://gist.app/terms")!     // TODO: real Terms of Use (EULA)
    private let privacyURL = URL(string: "https://gist.app/privacy")! // TODO: real Privacy Policy

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    promise
                    priceBlock
                    actions
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    legal
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    // MARK: - Sections

    /// Headline: you've hit today's free limit.
    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.badge.clock.fill")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("You're out of messages for today")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(subheadline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    /// A free user hit the daily cap; tell them they reset, and what upgrading does.
    private var subheadline: String {
        "Upgrade to Premium for many more messages every day. Your free messages refresh tomorrow."
    }

    /// THE PROMISE. This block is the heart of the product positioning and must
    /// remain: brevity is free forever; the only thing you pay for is volume.
    private var promise: some View {
        VStack(alignment: .leading, spacing: 12) {
            promiseRow(
                icon: "checkmark.seal.fill",
                tint: .green,
                title: "Short answers stay free — forever",
                detail: "Every answer is always under \(AppConfig.wordCapCopy) words, for everyone. Premium never makes answers longer."
            )
            promiseRow(
                icon: "infinity",
                tint: .accentColor,
                title: "Premium only adds more messages per day",
                detail: "You're paying for volume, not length. That's the only difference."
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// A single labelled promise row.
    private func promiseRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Price + billing-period disclosure. App Review requires the price, the
    /// duration (monthly), and that it auto-renews to be clearly visible.
    private var priceBlock: some View {
        VStack(spacing: 4) {
            Text(subscriptions.priceString)
                .font(.title.bold())
            Text("Billed monthly · auto-renewing subscription")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subscriptions.priceString), billed monthly, auto-renewing subscription")
    }

    /// Subscribe + Restore actions.
    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: subscribe) {
                Group {
                    if subscriptions.isLoading {
                        ProgressView()
                    } else {
                        Text("Subscribe")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(subscriptions.isLoading)

            Button(action: restore) {
                Text("Restore Purchases")
                    .font(.subheadline)
            }
            .disabled(subscriptions.isLoading)
        }
    }

    /// Auto-renew terms + required legal links (EULA + Privacy).
    private var legal: some View {
        VStack(spacing: 10) {
            Text("Payment is charged to your Apple ID at confirmation. The subscription renews automatically each month unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your App Store account settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Terms of Use (EULA)", destination: termsURL)
                Link("Privacy Policy", destination: privacyURL)
            }
            .font(.caption2)
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    /// Kicks off the monthly purchase. On success the entitlement flips and the
    /// sheet dismisses; cancellation is silent; other failures show inline copy.
    private func subscribe() {
        errorMessage = nil
        Task {
            do {
                try await subscriptions.purchaseMonthly()
                if subscriptions.isSubscribed {
                    dismiss()
                }
            } catch let error as SubscriptionManager.SubscriptionError {
                // Cancellation is not an error worth shouting about.
                if case .purchaseCancelled = error { return }
                errorMessage = error.userMessage
            } catch {
                errorMessage = "Something went wrong with the purchase. Please try again."
            }
        }
    }

    /// Restores prior purchases. On success (entitlement active) the sheet
    /// dismisses; otherwise an inline note is shown.
    private func restore() {
        errorMessage = nil
        Task {
            do {
                try await subscriptions.restore()
                if subscriptions.isSubscribed {
                    dismiss()
                } else {
                    errorMessage = "No active subscription found to restore."
                }
            } catch {
                errorMessage = "Couldn't restore purchases. Please try again."
            }
        }
    }
}

#Preview {
    PaywallView(limitInfo: LimitInfo(tier: "free", limit: 20, used: 20, resetAt: nil))
        .environment(SubscriptionManager())
}
