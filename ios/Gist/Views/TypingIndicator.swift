//
//  TypingIndicator.swift
//  Gist
//
//  An animated three-dot "the assistant is typing" indicator, shown while a
//  reply is streaming in. Purely presentational.
//

import SwiftUI

/// A three-dot bouncing indicator used while the assistant reply streams.
///
/// Each dot pulses with a staggered delay to read as a left-to-right wave. The
/// animation is driven by a single `@State` phase toggled on appear, so it keeps
/// running for the lifetime of the view without a timer.
struct TypingIndicator: View {

    /// Drives the repeating animation. Flipped once on appear; the per-dot
    /// `delay` staggers them.
    @State private var animating = false

    /// Number of dots in the indicator.
    private let dotCount = 3
    /// Diameter of each dot.
    private let dotSize: CGFloat = 7
    /// How far each dot rises at the peak of its bounce.
    private let bounce: CGFloat = 5

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: animating ? -bounce : 0)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: animating
                    )
            }
        }
        // Match the visual padding of an assistant bubble so the indicator sits
        // where the reply will appear.
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .onAppear { animating = true }
        // Accessibility: announce the state rather than reading three dots.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant is typing")
    }
}

#Preview {
    TypingIndicator()
        .padding()
}
