//
//  ChatMessage.swift
//  Gist
//
//  SwiftData models for on-device conversation history. Per README, chat
//  history is stored ONLY on the device — there is no server-side chat storage
//  in v1.
//

import Foundation
import SwiftData

/// The role of a stored message, bridging the persisted `String` to a typed
/// enum. Only `user` and `assistant` are valid per the API contract (the system
/// prompt is added server-side and never stored here).
enum MessageRole: String, Codable, CaseIterable {
    case user
    case assistant

    /// Whether this role represents the local user (drives bubble alignment).
    var isUser: Bool { self == .user }
}

/// A single persisted chat message.
///
/// `role` is stored as a raw `String` for SwiftData friendliness; use
/// ``messageRole`` for the typed value. `failed` marks a message whose send did
/// not complete (so the UI can offer a retry).
@Model
final class StoredMessage {
    /// Stable identity for the message.
    @Attribute(.unique) var id: UUID
    /// Raw role string; one of ``MessageRole``'s raw values.
    var role: String
    /// The message text.
    var content: String
    /// When the message was created (used for ordering).
    var createdAt: Date
    /// Whether the send/stream for this message failed.
    var failed: Bool

    /// Inverse relationship to the owning conversation.
    var conversation: Conversation?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        createdAt: Date = .now,
        failed: Bool = false
    ) {
        self.id = id
        self.role = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.failed = failed
    }

    /// The strongly-typed role, defaulting to `.assistant` for any unexpected
    /// stored value (defensive; should never occur in practice).
    var messageRole: MessageRole {
        get { MessageRole(rawValue: role) ?? .assistant }
        set { role = newValue.rawValue }
    }

    /// Projects this stored message onto the wire type for a chat request.
    var asWire: ChatRequest.Wire {
        ChatRequest.Wire(role: messageRole, content: content)
    }
}

/// A conversation: an ordered collection of ``StoredMessage`` values.
///
/// v1 uses a single active conversation (see ``PersistenceController``), but the
/// model supports multiple conversations so the feature can grow without a
/// migration.
@Model
final class Conversation {
    /// Stable identity for the conversation.
    @Attribute(.unique) var id: UUID
    /// Optional human-friendly title (e.g. derived from the first message).
    var title: String?
    /// When the conversation was created.
    var createdAt: Date
    /// When the conversation was last modified (new message, edit, etc.).
    var updatedAt: Date

    /// Owned messages. Deleting the conversation cascades to its messages.
    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
    var messages: [StoredMessage]

    init(
        id: UUID = UUID(),
        title: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [StoredMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    /// Messages in chronological order (the stored relationship is unordered).
    var orderedMessages: [StoredMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}
