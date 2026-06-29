//
//  APIModels.swift
//  Gist
//
//  Codable types that mirror docs/API_CONTRACT.md exactly. This file is the
//  client-side half of the shared contract; the backend implements the other
//  half. If the contract changes, change both sides.
//

import Foundation

// MARK: - Request

/// The body of `POST /v1/chat`.
///
/// `messages` must be non-empty and end with a `user` turn. The system prompt
/// is added by the backend and must never be supplied here.
struct ChatRequest: Codable, Equatable {
    /// Anonymous device UUID (or, later, an Apple `sub`). Must equal the
    /// `X-Gist-User` header value.
    let userId: String
    /// IANA timezone reported by the device; drives the daily reset.
    let timezone: String
    /// Full conversation the client wants answered.
    let messages: [Wire]
    /// Optional client version, for backend diagnostics.
    let clientVersion: String?

    /// A single conversational turn on the wire.
    ///
    /// Roles are limited to `user` and `assistant` (see ``MessageRole``). The
    /// type is deliberately minimal — only what the contract specifies.
    struct Wire: Codable, Equatable {
        let role: String
        let content: String

        init(role: String, content: String) {
            self.role = role
            self.content = content
        }

        /// Convenience initializer from the strongly-typed role enum.
        init(role: MessageRole, content: String) {
            self.role = role.rawValue
            self.content = content
        }
    }
}

// MARK: - SSE success payloads

/// Payload of the `meta` SSE event — sent first, before any token.
///
/// Lets the client update its remaining-count UI immediately. The
/// remaining-count shown here is for UX only; the cap is enforced server-side.
struct Meta: Codable, Equatable {
    let tier: String
    let used: Int
    let limit: Int
    let remaining: Int
    /// Next local midnight, ISO-8601 with offset.
    let resetAt: String
}

/// Payload of a `delta` SSE event. `text` chunks concatenate into the answer.
struct Delta: Codable, Equatable {
    let text: String
}

/// Payload of the terminal `done` SSE event.
struct Done: Codable, Equatable {
    /// One of `stop` | `length` (length = hit the token cap).
    let finishReason: String
    let used: Int
    let remaining: Int
}

// MARK: - Error envelope

/// The shared error enum from the contract.
///
/// Unknown / future codes decode to ``ErrorCode/unknown`` rather than failing,
/// so a backend addition never crashes an older client.
enum ErrorCode: String, Codable {
    case dailyLimitReached = "daily_limit_reached"
    case rateLimited = "rate_limited"
    case circuitOpen = "circuit_open"
    case invalidRequest = "invalid_request"
    case upstreamError = "upstream_error"
    case internalError = "internal_error"
    /// Any code not recognized by this client build.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ErrorCode(rawValue: raw) ?? .unknown
    }
}

/// The `error` object returned on every pre-stream rejection (JSON) and inside
/// a mid-stream SSE `error` event.
///
/// All fields beyond `code`/`message` are optional because they only appear on
/// specific statuses (e.g. `limit`/`used`/`resetAt` on a 402, `retryAfter` on a
/// 429). `message` is always a short, friendly, user-presentable string.
struct APIError: Codable, Equatable {
    let code: ErrorCode
    let message: String
    let tier: String?
    let limit: Int?
    let used: Int?
    let resetAt: String?
    let retryAfter: Int?
}

/// Wrapper matching the `{ "error": { ... } }` JSON envelope from the contract.
struct APIErrorEnvelope: Codable, Equatable {
    let error: APIError
}

// MARK: - Limit info (from a 402)

/// The paywall context extracted from a `402 daily_limit_reached` response.
///
/// Surfaced to the Views layer (via ``ChatError/limitReached(_:)``) so the
/// paywall can show how many messages were used and when they reset.
struct LimitInfo: Equatable {
    let tier: String
    let limit: Int
    let used: Int
    /// Next local midnight, ISO-8601 with offset, if the backend provided it.
    let resetAt: String?

    /// Builds a ``LimitInfo`` from a decoded ``APIError`` (the 402 body).
    /// Missing numeric fields default to `0`, missing tier to `"free"`.
    init(apiError: APIError) {
        self.tier = apiError.tier ?? "free"
        self.limit = apiError.limit ?? 0
        self.used = apiError.used ?? 0
        self.resetAt = apiError.resetAt
    }

    /// Memberwise initializer (useful for previews and tests).
    init(tier: String, limit: Int, used: Int, resetAt: String?) {
        self.tier = tier
        self.limit = limit
        self.used = used
        self.resetAt = resetAt
    }
}

// MARK: - Streamed event

/// A single decoded event from the SSE stream, surfaced to callers of
/// ``ChatService/stream(messages:)``.
///
/// Note that a mid-stream `error` SSE event is *not* represented here: the
/// service maps it to a thrown ``ChatError`` so streaming and pre-stream
/// failures are handled uniformly by the Views layer.
enum ChatEvent: Equatable {
    /// The leading `meta` event with tier/limit/remaining info.
    case meta(Meta)
    /// A `delta` token chunk (already unwrapped to its `text`).
    case delta(String)
    /// The terminal `done` event.
    case done(Done)
}
