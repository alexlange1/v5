//
//  InputBar.swift
//  Gist
//
//  The bottom-pinned composer: a growing multi-line text field plus a send
//  button. The send button is disabled when the field is empty or a reply is
//  streaming.
//
//  Important (README "Core product rules"): this bar does NOT limit message
//  length. Brevity is a property of the *answer* and is enforced server-side via
//  the injected system prompt — the user may type whatever they like.
//

import SwiftUI

/// The chat composer pinned to the bottom of ``ChatView``.
struct InputBar: View {

    /// The text being composed (two-way bound to the view model's `inputText`).
    @Binding var text: String
    /// Whether a reply is currently streaming (disables sending).
    let isStreaming: Bool
    /// Whether sending is currently allowed (non-empty + not streaming). Supplied
    /// by the view model so the enable/disable rule lives in one place.
    let canSend: Bool
    /// Invoked when the user taps send (or hits return on the field).
    let onSend: () -> Void

    /// Focus state for the field, so the keyboard can be managed if needed.
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Growing text field: 1 line minimum, expands up to a few lines, then
            // scrolls internally. `axis: .vertical` gives the multiline growth.
            TextField("Ask anything…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit {
                    if canSend { onSend() }
                }
                .accessibilityLabel("Message")

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The send button. Shows a paper-plane glyph; disabled state is reflected
    /// both visually (dimmed) and via `.disabled` for accessibility.
    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
        }
        .disabled(!canSend)
        .accessibilityLabel("Send")
        .accessibilityHint(isStreaming ? "Waiting for the current reply" : "Sends your message")
    }
}

#Preview("Empty") {
    InputBar(text: .constant(""), isStreaming: false, canSend: false, onSend: {})
}

#Preview("Ready") {
    InputBar(text: .constant("Hello"), isStreaming: false, canSend: true, onSend: {})
}

#Preview("Streaming") {
    InputBar(text: .constant("Hello"), isStreaming: true, canSend: false, onSend: {})
}
