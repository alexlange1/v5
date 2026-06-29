//
//  Keychain.swift
//  Gist
//
//  Minimal wrapper over the Security framework for storing small blobs of
//  `Data` (e.g. the anonymous device id). Intentionally tiny: save / load /
//  delete by string key. No iCloud Keychain sync (kSecAttrSynchronizable is
//  left at its default `false`) so the id stays bound to this device.
//

import Foundation
import Security

/// A minimal, type-safe Keychain accessor for generic password items.
///
/// Errors are surfaced as ``Keychain/KeychainError`` so callers can decide how
/// to react. The store is keyed by a string `account` within a single service.
enum Keychain {

    /// Errors thrown by the Keychain wrapper.
    enum KeychainError: Error {
        /// The underlying `Security` API returned a non-success status.
        case unexpectedStatus(OSStatus)
    }

    /// The service namespace under which all Gist items are stored.
    private static let service = "app.gist.keychain"

    /// Persists `data` for `account`, replacing any existing value.
    ///
    /// - Parameters:
    ///   - data: The bytes to store.
    ///   - account: A stable string key identifying the item.
    /// - Throws: ``KeychainError/unexpectedStatus(_:)`` on failure.
    static func save(_ data: Data, account: String) throws {
        // Delete any existing item first so this acts as an upsert.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Available after first unlock; survives reboots, not backed up to
            // other devices. Appropriate for a per-device anonymous id.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads the bytes stored for `account`, or `nil` if no item exists.
    ///
    /// - Parameter account: The string key used when saving.
    /// - Returns: The stored `Data`, or `nil` when absent.
    /// - Throws: ``KeychainError/unexpectedStatus(_:)`` on an unexpected failure.
    static func load(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes the item stored for `account`. A no-op if nothing is stored.
    ///
    /// - Parameter account: The string key used when saving.
    /// - Throws: ``KeychainError/unexpectedStatus(_:)`` on an unexpected failure.
    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
