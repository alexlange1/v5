//
//  SettingsView.swift
//  Gist
//
//  The settings screen reached from the chat's gear button. Shows subscription
//  status, a Restore Purchases action, a Clear History action (with a
//  confirmation), an About section (version + the brevity promise), and the
//  required Terms / Privacy links.
//
//  All actions delegate to the view model / subscription manager — no business
//  logic lives here.
//

import SwiftUI

/// The app settings screen.
struct SettingsView: View {

    /// Subscription state + restore, from the environment.
    @Environment(SubscriptionManager.self) private var subscriptions
    /// Dismiss handle (presented as a sheet from ``ChatView``).
    @Environment(\.dismiss) private var dismiss

    /// The chat view model — used only for `clearHistory()`.
    let viewModel: ChatViewModel

    /// Drives the destructive clear-history confirmation dialog.
    @State private var showingClearConfirm = false
    /// Transient status copy for a restore attempt.
    @State private var restoreMessage: String?

    // TODO: Replace with your real, hosted legal pages before submission (same
    // URLs as the paywall). Required for an app with auto-renewing subscriptions.
    private let termsURL = URL(string: "https://gist.app/terms")!     // TODO: real Terms of Use (EULA)
    private let privacyURL = URL(string: "https://gist.app/privacy")! // TODO: real Privacy Policy

    var body: some View {
        NavigationStack {
            Form {
                subscriptionSection
                dataSection
                aboutSection
                legalSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Clear all conversation history?",
                isPresented: $showingClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    viewModel.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes every message on this device. It can't be undone.")
            }
        }
    }

    // MARK: - Subscription

    private var subscriptionSection: some View {
        Section {
            HStack {
                Text("Plan")
                Spacer()
                Text(subscriptions.isSubscribed ? "Premium" : "Free")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Button {
                restore()
            } label: {
                HStack {
                    Text("Restore Purchases")
                    Spacer()
                    if subscriptions.isLoading {
                        ProgressView()
                    }
                }
            }
            .disabled(subscriptions.isLoading)

            if let restoreMessage {
                Text(restoreMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Subscription")
        } footer: {
            // Reinforce the product rule even here: paying buys volume, not length.
            Text("Premium adds many more messages per day. Answers are always under \(AppConfig.wordCapCopy) words on every plan.")
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section("Data") {
            Button(role: .destructive) {
                showingClearConfirm = true
            } label: {
                Text("Clear History")
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(AppConfig.clientVersion)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            // The brevity promise — the whole identity of the app.
            Text("Gist answers every question in under \(AppConfig.wordCapCopy) words. Short is the point — there's no way to make answers longer, and there never will be.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Legal

    private var legalSection: some View {
        Section("Legal") {
            Link("Terms of Use (EULA)", destination: termsURL)
            Link("Privacy Policy", destination: privacyURL)
        }
    }

    // MARK: - Actions

    /// Restores purchases via the subscription manager and reports the outcome.
    private func restore() {
        restoreMessage = nil
        Task {
            do {
                try await subscriptions.restore()
                restoreMessage = subscriptions.isSubscribed
                    ? "Premium restored."
                    : "No active subscription found."
            } catch {
                restoreMessage = "Couldn't restore purchases. Please try again."
            }
        }
    }
}

#Preview {
    SettingsView(
        viewModel: ChatViewModel(
            chatService: ChatService(),
            persistence: PersistenceController(inMemory: true),
            subscriptions: SubscriptionManager()
        )
    )
    .environment(SubscriptionManager())
}
