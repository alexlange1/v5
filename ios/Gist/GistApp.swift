//
//  GistApp.swift
//  Gist
//
//  Application entry point. Wires the three long-lived dependencies the UI needs
//  — the SwiftData stack, the RevenueCat-backed subscription state, and the chat
//  network service — and injects them into the SwiftUI environment so views and
//  view models can resolve them without global singletons.
//
//  Trust-boundary reminder (README "Core product rules"): nothing here enforces
//  brevity or the daily volume cap. Those live entirely server-side. The client
//  only renders results and shows a *cosmetic* remaining-count for UX.
//

import SwiftUI
import SwiftData

/// The Gist app.
///
/// Responsibilities, in order:
/// 1. Build (or reuse) the SwiftData `ModelContainer` via ``PersistenceController``.
/// 2. Configure RevenueCat exactly once through ``SubscriptionManager``.
/// 3. Inject the shared objects into the environment.
/// 4. Show the single ``ChatView`` as the root.
@main
struct GistApp: App {

    /// Owns the SwiftData stack. We hold the controller (not just the container)
    /// so view models can use its history helpers (`activeConversation`,
    /// `clearAllHistory`) which need explicit context control.
    private let persistence = PersistenceController.shared

    /// The single subscription façade for the whole app. Marked `@State` so its
    /// `@Observable` changes drive SwiftUI updates; created once for the app's
    /// lifetime.
    @State private var subscriptions = SubscriptionManager()

    /// The chat network service. An `actor`, shared across the app; views never
    /// call it directly — only the view model does.
    private let chatService = ChatService()

    init() {
        // Configure RevenueCat with the *public* SDK key at launch. This is
        // idempotent (the manager guards re-entry) and non-blocking: it kicks
        // off entitlement + offerings loads in the background.
        //
        // Note: `SubscriptionManager` is `@MainActor`; `App.init` already runs
        // on the main actor, so the call is safe without hopping.
        subscriptions.configure()
    }

    var body: some Scene {
        WindowGroup {
            ChatView(
                viewModel: ChatViewModel(
                    chatService: chatService,
                    persistence: persistence,
                    subscriptions: subscriptions
                )
            )
            // Make the subscription state observable anywhere in the tree (the
            // paywall and settings read it).
            .environment(subscriptions)
        }
        // Hand SwiftUI the SwiftData container so `@Query` / `modelContext` work
        // and so the model context the view model uses is the same one views see.
        .modelContainer(persistence.container)
    }
}
