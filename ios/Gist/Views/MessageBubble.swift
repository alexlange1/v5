//
//  MessageBubble.swift
//  Gist
//
//  Renders a single chat turn. User turns are right-aligned with an accent fill;
//  assistant turns are left-aligned on a neutral surface. A failed assistant turn
//  shows a friendly inline error and a Retry affordance.
//
//  Purely presentational: all logic (sending, retrying) lives in the view model.
//  Retry is delivered via a closure the parent supplies.
//

import SwiftUI

/// A chat message bubble for one ``DisplayMessage``.
struct MessageBubble: View {

    /// The message to render.
    let message: DisplayMessage
    /// Invoked when the user taps Retry on a failed assistant turn.
    let onRetry: () -> Void

    /// Whether this is the local user's turn (drives alignment + colors).
    private var isUser: Bool { message.role.isUser }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                bubble

                // Failed assistant turn → inline error + retry.
                if message.failed {
                    failureFooter
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }

    // MARK: - Bubble

    /// The text bubble itself. Shown whenever there is content; an empty failed
    /// placeholder shows nothing here (the failure footer carries the message).
    @ViewBuilder
    private var bubble: some View {
        if !message.content.isEmpty {
            Text(message.content)
                .font(.body)
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .textSelection(.enabled)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    /// The bubble fill: accent for the user, a neutral surface for the assistant.
    /// Both adapt automatically to light/dark mode.
    private var bubbleBackground: some View {
        Group {
            if isUser {
                Color.accentColor
            } else {
                Color(.secondarySystemBackground)
            }
        }
    }

    // MARK: - Failure

    /// Inline error copy + Retry button for a failed turn.
    private var failureFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.secondary)
            Text(message.errorMessage ?? "Something went wrong.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: onRetry) {
                Text("Retry")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Failed: \(message.errorMessage ?? "Something went wrong."). Double tap Retry to try again.")
    }
}

#Preview("User") {
    MessageBubble(
        message: DisplayMessage(role: .user, content: "What's the capital of France?"),
        onRetry: {}
    )
    .padding()
}

#Preview("Assistant") {
    MessageBubble(
        message: DisplayMessage(role: .assistant, content: "Paris is the capital of France."),
        onRetry: {}
    )
    .padding()
}

#Preview("Failed") {
    MessageBubble(
        message: DisplayMessage(
            role: .assistant,
            content: "",
            failed: true,
            errorMessage: "The model is unavailable. Please retry."
        ),
        onRetry: {}
    )
    .padding()
}
