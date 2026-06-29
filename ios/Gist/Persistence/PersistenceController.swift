//
//  PersistenceController.swift
//  Gist
//
//  Owns the SwiftData ModelContainer and provides small helpers for the single
//  active conversation and history clearing. Designed so multiple conversations
//  are possible later without a migration.
//

import Foundation
import SwiftData

/// Central access point for the app's SwiftData stack.
///
/// Expose ``container`` to the SwiftUI app via `.modelContainer(_:)`, and use
/// the helpers here for operations that need explicit context control.
@MainActor
final class PersistenceController {

    /// The shared, on-disk instance used by the running app.
    static let shared = PersistenceController()

    /// The SwiftData container holding all models.
    let container: ModelContainer

    /// The main-context, convenient for one-off operations.
    var mainContext: ModelContext { container.mainContext }

    /// Builds the controller.
    ///
    /// - Parameter inMemory: When `true`, data lives only in memory — handy for
    ///   previews and tests. Defaults to `false` (persistent on-device store).
    init(inMemory: Bool = false) {
        let schema = Schema([
            Conversation.self,
            StoredMessage.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A failure here means the local store is unusable; there is no
            // sensible degraded mode for persistence, so fail fast with a clear
            // message rather than limping along with a half-initialized stack.
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }
    }

    // MARK: - Active conversation

    /// Returns the single active conversation, creating it on first use.
    ///
    /// "Active" is defined as the most recently updated conversation. Because we
    /// select rather than assume a singleton, adding a conversation list UI
    /// later requires no schema change — only a new way to pick the active one.
    ///
    /// - Parameter context: The context to query/insert in. Defaults to the
    ///   main context.
    /// - Returns: The active ``Conversation``.
    @discardableResult
    func activeConversation(in context: ModelContext? = nil) -> Conversation {
        let ctx = context ?? mainContext

        var descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let existing = (try? ctx.fetch(descriptor))?.first {
            return existing
        }

        let conversation = Conversation()
        ctx.insert(conversation)
        try? ctx.save()
        return conversation
    }

    /// Appends a message to the active conversation and bumps `updatedAt`.
    ///
    /// - Parameters:
    ///   - message: The message to insert.
    ///   - conversation: The target conversation; defaults to the active one.
    ///   - context: The context to mutate; defaults to the main context.
    func append(
        _ message: StoredMessage,
        to conversation: Conversation? = nil,
        in context: ModelContext? = nil
    ) {
        let ctx = context ?? mainContext
        let target = conversation ?? activeConversation(in: ctx)
        message.conversation = target
        target.messages.append(message)
        target.updatedAt = .now
        ctx.insert(message)
        try? ctx.save()
    }

    // MARK: - Maintenance

    /// Deletes all conversations and messages from the store.
    ///
    /// Used by a "Clear history" action. Because the conversation→message
    /// relationship cascades, deleting conversations removes their messages too.
    ///
    /// - Parameter context: The context to mutate; defaults to the main context.
    func clearAllHistory(in context: ModelContext? = nil) {
        let ctx = context ?? mainContext
        do {
            // Delete by model type; cascade handles owned messages, and we also
            // remove any orphaned messages defensively.
            try ctx.delete(model: Conversation.self)
            try ctx.delete(model: StoredMessage.self)
            try ctx.save()
        } catch {
            // Non-fatal: clearing history failing should not crash the app.
            // The caller can surface a generic "couldn't clear" message.
            assertionFailure("clearAllHistory failed: \(error)")
        }
    }
}
