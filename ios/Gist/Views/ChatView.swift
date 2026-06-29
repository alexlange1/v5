//
//  ChatView.swift
//  Gist
//
//  The single screen of the app: a scrolling list of message bubbles that
//  auto-scrolls as tokens stream in, a typing indicator while a reply is in
//  flight, a bottom-pinned ``InputBar``, a free-tier ``RemainingPill`` and a
//  gear that opens ``SettingsView``. The ``PaywallView`` is presented as a sheet
//  when the view model flags a daily-limit (402) hit.
//
//  No business logic here — everything is delegated to ``ChatViewModel`` and the
//  injected services.
//

import SwiftUI

/// The root chat screen.
struct ChatView: View {

    /// The view model owning all chat state + logic. Held with `@State` so its
    /// `@Observable` changes drive the view; created and injected by ``GistApp``.
    /// The view model holds the subscription reference itself, so the screen
    /// reads free-vs-paid through `viewModel.showsRemainingPill` rather than the
    /// environment directly.
    @State var viewModel: ChatViewModel

    /// Whether the settings sheet is presented.
    @State private var showingSettings = false

    /// Anchor id for the auto-scroll-to-bottom behaviour.
    private let bottomAnchor = "chat.bottom.anchor"

    var body: some View {
        // Bind into the @Observable view model for two-way input binding.
        @Bindable var vm = viewModel

        NavigationStack {
            VStack(spacing: 0) {
                messageList
                Divider()
                InputBar(
                    text: $vm.inputText,
                    isStreaming: viewModel.isStreaming,
                    canSend: viewModel.canSend,
                    onSend: viewModel.send
                )
            }
            .navigationTitle("Gist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // 402 → paywall. Presented from the view model's one-shot flag.
            .sheet(isPresented: $vm.isPaywallPresented, onDismiss: viewModel.paywallDismissed) {
                PaywallView(limitInfo: viewModel.limitInfo)
            }
            // Gear → settings.
            .sheet(isPresented: $showingSettings) {
                SettingsView(viewModel: viewModel)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Free-tier remaining pill (cosmetic only). `showsRemainingPill` already
        // encapsulates the "free tier + known count" rule.
        if viewModel.showsRemainingPill, let remaining = viewModel.remaining {
            ToolbarItem(placement: .topBarLeading) {
                RemainingPill(remaining: remaining)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.isEmpty && !viewModel.isStreaming {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message) {
                                viewModel.retry(message)
                            }
                            .id(message.id)
                        }

                        // Typing indicator while streaming. Shown when the trailing
                        // assistant bubble has no text yet (waiting on first token).
                        if viewModel.isStreaming, shouldShowTypingIndicator {
                            HStack {
                                TypingIndicator()
                                Spacer(minLength: 40)
                            }
                        }

                        // Invisible anchor we scroll to as content grows.
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
            // Auto-scroll to the bottom as the message count grows, as tokens
            // stream into the last bubble, and when the typing indicator appears.
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.lastMessageContent) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, _ in
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    /// Whether the standalone typing indicator should appear: we're streaming and
    /// the latest assistant turn hasn't produced any visible text yet.
    private var shouldShowTypingIndicator: Bool {
        guard let last = viewModel.messages.last else { return true }
        return last.role == .assistant && last.content.isEmpty && !last.failed
    }

    /// Scrolls the list to the bottom anchor.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !viewModel.messages.isEmpty || viewModel.isStreaming else { return }
        let scroll = { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { scroll() }
        } else {
            scroll()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Ask anything")
                .font(.title3.weight(.semibold))
            Text("Every answer, always under \(AppConfig.wordCapCopy) words.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ChatView(
        viewModel: ChatViewModel(
            chatService: ChatService(),
            persistence: PersistenceController(inMemory: true),
            subscriptions: SubscriptionManager()
        )
    )
    .environment(SubscriptionManager())
}
