//
//  ChatViewModel.swift
//  Gist
//
//  The single view model behind the chat screen. It owns all chat business
//  logic so the views stay dumb (README convention: no business logic in views).
//
//  What it does:
//   • Loads persisted history from SwiftData and keeps an in-memory mirror the
//     UI renders from (so we can stream tokens into a message live, then persist
//     the final text once).
//   • Drives a send: persist the user turn, open an empty assistant turn, consume
//     `ChatService.stream`, append deltas as they arrive, and persist the final.
//   • Tracks the *cosmetic* remaining-count + tier from `meta`/`done` events.
//     This is UX only — the daily cap is enforced server-side (README rules).
//   • Maps `ChatError.limitReached` to a paywall presentation; every other error
//     marks the assistant turn failed with a friendly inline message + retry.
//   • Survives a dropped stream gracefully (partial text is kept; the turn is
//     marked failed so the user can retry).
//

import Foundation
import SwiftData

/// View model for ``ChatView``.
///
/// `@MainActor` because every property it mutates feeds the UI; `@Observable`
/// (iOS 17+) so SwiftUI tracks changes automatically. Streaming work happens in
/// a `Task` but always hops back here to mutate state, so reads stay coherent.
@MainActor
@Observable
final class ChatViewModel {

    // MARK: - Rendered state

    /// The messages the UI renders, in chronological order. This is the in-memory
    /// mirror of the persisted history; the streaming assistant turn is mutated
    /// here in place so tokens appear live before the final save.
    private(set) var messages: [DisplayMessage] = []

    /// The text bound to the input bar.
    var inputText: String = ""

    /// Whether a stream is currently in flight (drives the typing indicator and
    /// disables the send button / input while a reply is arriving).
    private(set) var isStreaming: Bool = false

    /// The most recent server-reported remaining-count for *today*, if known.
    ///
    /// Populated from `meta` (and refreshed by `done`). Purely cosmetic — shown
    /// in the free-tier ``RemainingPill``. `nil` until the first reply arrives.
    private(set) var remaining: Int?

    /// The tier reported by the last `meta` event (`"free"` / `"paid"`), if any.
    /// The authoritative paid-vs-free signal for *gating UI* is the subscription
    /// manager; this is only a hint mirrored from the server's view.
    private(set) var serverTier: String?

    /// Set when the server returns `402` (daily limit reached). Drives the
    /// paywall sheet. Cleared when the sheet is dismissed.
    var isPaywallPresented: Bool = false

    /// The limit context captured from the `402`, shown in the paywall copy.
    private(set) var limitInfo: LimitInfo?

    // MARK: - Dependencies

    /// The network service (an `actor`). Only the view model talks to it.
    private let chatService: ChatService
    /// Owns SwiftData persistence + history helpers.
    private let persistence: PersistenceController
    /// Subscription state, used to decide whether the remaining pill shows
    /// (free tier only) and read by the paywall/settings via the environment.
    private let subscriptions: SubscriptionManager

    /// The active conversation we append to. Resolved lazily on first load.
    private var conversation: Conversation?

    /// The handle for the in-flight stream, so a new send / view teardown can
    /// cancel a previous one cleanly.
    private var streamTask: Task<Void, Never>?

    // MARK: - Init

    init(
        chatService: ChatService,
        persistence: PersistenceController,
        subscriptions: SubscriptionManager
    ) {
        self.chatService = chatService
        self.persistence = persistence
        self.subscriptions = subscriptions
        loadHistory()
    }

    // MARK: - Derived UI flags

    /// Whether the free-tier remaining pill should be shown. Hidden for paid
    /// users (they have effectively unlimited volume) and until we know a count.
    var showsRemainingPill: Bool {
        !subscriptions.isSubscribed && remaining != nil
    }

    /// Whether the conversation is empty (drives the empty-state placeholder).
    var isEmpty: Bool { messages.isEmpty }

    /// The content of the most recent message. Exposed so the view can observe
    /// it and auto-scroll as tokens stream into the trailing assistant bubble
    /// (the `messages.count` alone doesn't change while a single bubble grows).
    var lastMessageContent: String { messages.last?.content ?? "" }

    /// Whether the send action is currently allowed: non-empty input and no
    /// stream in flight. (Length is *not* checked client-side — brevity is a
    /// server concern; this is only the obvious "don't send blank / don't double
    /// send" UX guard.)
    var canSend: Bool {
        !isStreaming && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - History

    /// Loads persisted messages into the in-memory mirror on launch.
    private func loadHistory() {
        let conversation = persistence.activeConversation()
        self.conversation = conversation
        messages = conversation.orderedMessages.map(DisplayMessage.init(stored:))
    }

    /// Clears all on-device history and resets the in-memory state.
    ///
    /// Cancels any in-flight stream first so a late token cannot resurrect a
    /// just-deleted message.
    func clearHistory() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false

        persistence.clearAllHistory()
        // A fresh active conversation is created on next access.
        conversation = persistence.activeConversation()
        messages = []
        // Remaining/tier are server-driven; leave them as last known. They refresh
        // on the next successful send.
    }

    // MARK: - Send

    /// Sends the current input as a new user turn and streams the assistant reply.
    ///
    /// Flow (mirrors docs/API_CONTRACT.md client behaviour):
    ///  1. Persist the user message.
    ///  2. Open an empty, in-memory assistant message and start the typing state.
    ///  3. Consume the SSE stream: `meta` → update remaining/tier; `delta` →
    ///     append text live; `done` → finalize + persist.
    ///  4. `402` → present the paywall and drop the empty assistant turn.
    ///     Any other error → mark the assistant turn failed with friendly copy
    ///     and allow retry. A dropped stream is treated as a failed turn that
    ///     keeps whatever partial text arrived.
    func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !trimmed.isEmpty else { return }

        // Clear the field immediately for responsiveness.
        inputText = ""

        // 1. Persist the user turn and mirror it into the UI.
        let userStored = StoredMessage(role: .user, content: trimmed)
        persistence.append(userStored, to: conversation)
        messages.append(DisplayMessage(stored: userStored))

        // The wire history is the full conversation so far (user + assistant).
        // The backend trims/sanitizes and injects the system prompt; we just send
        // what we have, ending on this user turn.
        let wire = messages
            .filter { !$0.isFailedPlaceholder }
            .map(\.asWire)

        startStream(wire: wire)
    }

    /// Retries a previously failed assistant turn.
    ///
    /// The failed assistant placeholder is removed and the stream is re-opened
    /// against the existing user turn that preceded it.
    /// - Parameter message: The failed assistant ``DisplayMessage`` to retry.
    func retry(_ message: DisplayMessage) {
        guard !isStreaming, message.role == .assistant else { return }

        // Drop the failed assistant turn from the UI; the user turn before it
        // remains and anchors the request.
        messages.removeAll { $0.id == message.id }

        let wire = messages
            .filter { !$0.isFailedPlaceholder }
            .map(\.asWire)

        // Nothing to answer if there is no trailing user turn (shouldn't happen).
        guard wire.last?.role == MessageRole.user.rawValue else { return }

        startStream(wire: wire)
    }

    /// Opens the stream and pumps events into state. Shared by `send` and `retry`.
    ///
    /// - Parameter wire: The conversation to send, ending on a `user` turn.
    private func startStream(wire: [ChatRequest.Wire]) {
        // 2. Open an empty assistant turn and enter the streaming state. Tokens
        //    are appended into this turn (looked up by id) as deltas arrive.
        let assistant = DisplayMessage(role: .assistant, content: "")
        let assistantID = assistant.id
        messages.append(assistant)
        isStreaming = true

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }

            // `stream(_:)` is on an actor; awaiting it returns the AsyncSequence.
            let events = await self.chatService.stream(messages: wire)

            do {
                for try await event in events {
                    switch event {
                    case .meta(let meta):
                        self.remaining = meta.remaining
                        self.serverTier = meta.tier

                    case .delta(let text):
                        self.appendDelta(text, to: assistantID)

                    case .done(let done):
                        self.remaining = done.remaining
                    }
                }
                // 3. Stream completed cleanly → persist the final assistant text.
                self.finalizeAssistant(id: assistantID)
            } catch let error as ChatError {
                self.handle(error, assistantID: assistantID)
            } catch is CancellationError {
                // Cancelled by a newer send / teardown: leave state as-is. The
                // partial turn (if any) stays in memory but is not persisted.
                // It will simply not survive the next history load.
            } catch {
                // Any non-ChatError transport surprise → generic friendly failure.
                self.handle(.network, assistantID: assistantID)
            }

            self.isStreaming = false
            self.streamTask = nil
        }
    }

    // MARK: - Streaming mutations

    /// Appends a token chunk to the in-memory assistant turn identified by `id`.
    private func appendDelta(_ text: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += text
        messages[index].failed = false
    }

    /// Persists the completed assistant turn to SwiftData.
    ///
    /// Only called on a clean `done`. If the model produced no text at all we
    /// still persist an (empty) turn rather than silently dropping it, but in
    /// practice the contract guarantees at least the `done` event after deltas.
    private func finalizeAssistant(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let display = messages[index]

        let stored = StoredMessage(
            id: display.id,
            role: .assistant,
            content: display.content,
            failed: false
        )
        persistence.append(stored, to: conversation)
        // Keep the in-memory mirror in sync with what we persisted.
        messages[index].failed = false
    }

    // MARK: - Error handling

    /// Routes a ``ChatError`` to the right UI outcome.
    ///
    /// - `limitReached` → drop the empty assistant turn and present the paywall.
    /// - everything else → mark the assistant turn failed with friendly copy so
    ///   the user can retry inline. Any partial text already streamed is kept.
    private func handle(_ error: ChatError, assistantID: UUID) {
        switch error {
        case .limitReached(let info):
            // Remove the empty placeholder — the paywall, not an error row, is
            // the right response to a 402.
            messages.removeAll { $0.id == assistantID && $0.content.isEmpty }
            limitInfo = info
            // Mirror the tier the server just reported (typically "free").
            serverTier = info.tier
            isPaywallPresented = true

        case .rateLimited, .circuitOpen, .server, .network:
            markFailed(assistantID, message: error.userMessage)
        }
    }

    /// Marks the assistant turn `id` as failed and attaches inline error copy.
    ///
    /// If no text streamed before the failure, the friendly message itself
    /// becomes the bubble's content so the row reads sensibly; otherwise the
    /// partial answer is kept and the error is exposed via ``DisplayMessage``'s
    /// `failed` flag + `errorMessage`.
    private func markFailed(_ id: UUID, message: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].failed = true
        messages[index].errorMessage = message
    }

    // MARK: - Paywall

    /// Called when the paywall sheet is dismissed (regardless of outcome).
    /// Clears the one-shot presentation flag. If the user subscribed, the
    /// subscription manager's `isSubscribed` flips and the pill hides on its own.
    func paywallDismissed() {
        isPaywallPresented = false
        limitInfo = nil
    }
}

// MARK: - DisplayMessage

/// The lightweight, value-type message the UI renders.
///
/// Separate from ``StoredMessage`` (the SwiftData `@Model`) for two reasons:
///  1. We mutate the streaming assistant turn token-by-token in memory before a
///     single final persist — cheaper and simpler than re-saving each delta.
///  2. It carries transient, non-persisted UI state (`errorMessage`) that has no
///     business in the on-disk schema.
struct DisplayMessage: Identifiable, Equatable {
    /// Stable id; shared with the persisted message so the two stay aligned.
    let id: UUID
    /// The message role (drives bubble alignment + styling).
    let role: MessageRole
    /// The (possibly streaming) text.
    var content: String
    /// Whether this turn failed to complete (offers a retry in the UI).
    var failed: Bool
    /// Friendly, transient error copy for a failed turn (never persisted).
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        failed: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.failed = failed
        self.errorMessage = errorMessage
    }

    /// Builds a display message from a persisted one.
    init(stored: StoredMessage) {
        self.id = stored.id
        self.role = stored.messageRole
        self.content = stored.content
        self.failed = stored.failed
        self.errorMessage = nil
    }

    /// Whether this is an empty failed placeholder with no useful content (used
    /// to exclude it from the wire history sent to the backend).
    var isFailedPlaceholder: Bool {
        failed && content.isEmpty
    }

    /// Projects onto the wire type for a chat request.
    var asWire: ChatRequest.Wire {
        ChatRequest.Wire(role: role, content: content)
    }
}
