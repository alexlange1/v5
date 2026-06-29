//
//  RemainingPill.swift
//  Gist
//
//  A small "N left today" pill shown to free users. This is a UX courtesy ONLY —
//  it is NOT an enforcement mechanism. The daily volume cap is enforced entirely
//  server-side (README "Core product rules"); a tampered client cannot grant
//  itself more messages by faking this number.
//

import SwiftUI

/// A compact remaining-messages pill for free-tier users.
///
/// The parent (``ChatView``) decides *whether* to show this (free tier + a known
/// count). This view just renders the number it is given.
struct RemainingPill: View {

    /// The cosmetic remaining count to display. Clamped at zero for safety.
    let remaining: Int

    /// Non-negative display value.
    private var value: Int { max(0, remaining) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.caption2)
            Text("\(value) left today")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(value == 0 ? Color.orange : Color.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(
            Capsule().fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) messages left today")
    }
}

#Preview {
    VStack(spacing: 12) {
        RemainingPill(remaining: 14)
        RemainingPill(remaining: 1)
        RemainingPill(remaining: 0)
    }
    .padding()
}
