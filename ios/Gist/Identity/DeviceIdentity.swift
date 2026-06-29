//
//  DeviceIdentity.swift
//  Gist
//
//  Provides the stable anonymous user identifier sent to the backend as both
//  the `userId` body field and the `X-Gist-User` header (see
//  docs/API_CONTRACT.md). The id is generated once, persisted in the Keychain,
//  and reused for the lifetime of the install.
//

import Foundation

/// Source of the app's stable identity and locale-derived request fields.
///
/// In v1 the identity is an anonymous, per-install UUID. The backend treats the
/// value it receives as authoritative; the client simply provides a consistent
/// id so the daily volume cap can be attributed correctly.
enum DeviceIdentity {

    /// Keychain account under which the anonymous id is stored.
    private static let account = "device-user-id"

    /// The stable anonymous user id for this install.
    ///
    /// On first access a fresh UUID is generated and written to the Keychain;
    /// subsequent accesses return the persisted value. Because it lives in the
    /// Keychain it survives app deletion/reinstall on the same device, keeping
    /// the daily cap from being trivially reset by a reinstall.
    ///
    /// - Note: **Sign in with Apple migration.** When Sign in with Apple is
    ///   added later, the authoritative id should become the Apple identity
    ///   token's `sub` claim (a stable, app-scoped user identifier). At that
    ///   point this property would prefer the stored Apple `sub` and fall back
    ///   to the anonymous UUID only for users who have not signed in. The
    ///   backend already accepts "anonymous device UUID, or Apple sub" for
    ///   `userId` (docs/API_CONTRACT.md), so no contract change is required —
    ///   only the source of the string changes here.
    static var currentUserID: String {
        if let data = try? Keychain.load(account: account),
           let existing = String(data: data, encoding: .utf8),
           !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString
        // Best-effort persist. If the Keychain write fails we still return a
        // usable id for this session rather than crashing; the next launch will
        // simply try again. This keeps the app functional in degraded states.
        if let data = generated.data(using: .utf8) {
            try? Keychain.save(data, account: account)
        }
        return generated
    }

    /// The device's current IANA timezone identifier (e.g. `"Europe/Berlin"`).
    ///
    /// Sent as the `timezone` request field; the backend uses it to compute the
    /// local day key that drives the daily reset (docs/API_CONTRACT.md).
    static var currentTimezoneIdentifier: String {
        TimeZone.current.identifier
    }

    /// Removes the persisted anonymous id (e.g. on an explicit "reset identity"
    /// action). The next access to ``currentUserID`` will mint a new one.
    static func reset() {
        try? Keychain.delete(account: account)
    }
}
