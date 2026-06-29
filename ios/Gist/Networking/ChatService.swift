//
//  ChatService.swift
//  Gist
//
//  The single network entry point for chat. Implements the client half of
//  docs/API_CONTRACT.md: POST /v1/chat, map the HTTP status BEFORE streaming,
//  then parse the SSE line protocol into a stream of ``ChatEvent``.
//
//  Trust boundary note: brevity and the daily volume cap are enforced entirely
//  server-side. This client never limits message length or counts messages as a
//  gate; any remaining-count it shows is purely cosmetic (docs/README "Core
//  product rules").
//

import Foundation

// MARK: - Errors

/// Errors surfaced from ``ChatService`` to the Views layer.
///
/// Each case carries only what the UI needs. Friendly, user-presentable copy
/// is available via ``userMessage`` — raw upstream bodies and stack traces are
/// never exposed (docs/API_CONTRACT.md).
enum ChatError: Error, Equatable {
    /// `402` — the user hit their daily cap. Opens the paywall.
    case limitReached(LimitInfo)
    /// `429` — too many requests. Carries the server's `Retry-After` seconds,
    /// when present.
    case rateLimited(retryAfter: Int?)
    /// `503` — global circuit breaker is open.
    case circuitOpen
    /// `400` / `500` / `502`, or a mid-stream SSE `error` event. Carries the
    /// already-friendly server message.
    case server(message: String)
    /// Transport-level failure (no/again connection, timeout, TLS, etc.).
    case network

    /// A short, friendly string safe to show directly to the user.
    ///
    /// Mirrors the "Client behaviour" column of the contract's error table.
    var userMessage: String {
        switch self {
        case .limitReached:
            // The paywall UI supplies its own richer copy; this is a fallback.
            return "You've used all your messages for today."
        case .rateLimited:
            return "Slow down a moment, then try again."
        case .circuitOpen:
            return "We're at capacity right now. Try again shortly."
        case .server(let message):
            // The backend guarantees `message` is already friendly; if it ever
            // arrives empty we substitute a generic line.
            return message.isEmpty ? "Something went wrong. Please retry." : message
        case .network:
            return "No connection. Check your network and try again."
        }
    }
}

// MARK: - Service

/// Streams chat completions from the Gist backend.
///
/// Modeled as an `actor` so its mutable session/config are safely shared across
/// concurrent callers. The public surface is a single streaming method.
actor ChatService {

    /// The backend base URL (defaults to ``AppConfig/backendBaseURL``).
    private let baseURL: URL
    /// The URLSession used for the streaming request.
    private let session: URLSession
    /// Supplies the authoritative identity + timezone for each request.
    /// Defaults to ``DeviceIdentity`` static accessors.
    private let userIDProvider: @Sendable () -> String
    private let timezoneProvider: @Sendable () -> String
    private let clientVersionProvider: @Sendable () -> String?

    /// Designated initializer. Defaults wire the real app config & identity;
    /// the closures make the service trivially testable with fakes.
    init(
        baseURL: URL = AppConfig.backendBaseURL,
        session: URLSession = .shared,
        userIDProvider: @escaping @Sendable () -> String = { DeviceIdentity.currentUserID },
        timezoneProvider: @escaping @Sendable () -> String = { DeviceIdentity.currentTimezoneIdentifier },
        clientVersionProvider: @escaping @Sendable () -> String? = { AppConfig.clientVersion }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.userIDProvider = userIDProvider
        self.timezoneProvider = timezoneProvider
        self.clientVersionProvider = clientVersionProvider
    }

    /// Sends `messages` and streams the reply.
    ///
    /// The returned stream yields ``ChatEvent`` values (`meta`, then any number
    /// of `delta`, then `done`). The HTTP status is mapped to a ``ChatError``
    /// **before** any token is yielded; a mid-stream SSE `error` event is also
    /// surfaced as a thrown ``ChatError/server(message:)``.
    ///
    /// - Parameter messages: The conversation to answer. Must be non-empty and
    ///   end with a `user` turn (validated server-side).
    /// - Returns: An `AsyncThrowingStream` of decoded events.
    func stream(messages: [ChatRequest.Wire]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancel the underlying network task if the consumer stops early.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Implementation

    /// Performs the request, maps the status, and pumps the SSE parser.
    private func run(
        messages: [ChatRequest.Wire],
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        let request = try makeRequest(messages: messages)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch is URLError {
            throw ChatError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatError.network
        }

        // Map the HTTP status BEFORE streaming any tokens (contract requires the
        // client to decide from the status code first).
        if http.statusCode != 200 {
            try await mapErrorStatus(http, bytes: bytes)
            return // mapErrorStatus always throws on non-200; this is unreachable.
        }

        try await parseSSE(bytes: bytes, continuation: continuation)
    }

    /// Builds the `POST /v1/chat` request with headers and JSON body.
    private func makeRequest(messages: [ChatRequest.Wire]) throws -> URLRequest {
        let userID = userIDProvider()

        let body = ChatRequest(
            userId: userID,
            timezone: timezoneProvider(),
            messages: messages,
            clientVersion: clientVersionProvider()
        )

        let url = baseURL.appendingPathComponent("v1/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `X-Gist-User` is the authoritative identity header (must match body).
        request.setValue(userID, forHTTPHeaderField: "X-Gist-User")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: HTTP status -> ChatError

    /// Maps a non-200 response to the appropriate ``ChatError`` and throws it.
    ///
    /// The body is read (best effort) to extract the friendly message and, for
    /// 402/429, the structured limit / retry fields. We never surface a raw
    /// upstream body verbatim — only the contract's `message` and known fields.
    private func mapErrorStatus(
        _ http: HTTPURLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws -> Never {
        let apiError = await Self.decodeError(from: bytes)

        switch http.statusCode {
        case 402:
            let info = apiError.map(LimitInfo.init(apiError:))
                ?? LimitInfo(tier: "free", limit: 0, used: 0, resetAt: nil)
            throw ChatError.limitReached(info)

        case 429:
            // Prefer the structured field, fall back to the `Retry-After` header.
            let retryAfter = apiError?.retryAfter ?? Self.retryAfterHeader(http)
            throw ChatError.rateLimited(retryAfter: retryAfter)

        case 503:
            throw ChatError.circuitOpen

        default:
            // 400 / 500 / 502 and any other unexpected status → friendly server
            // error. Treated by the Views layer as a retryable inline error.
            let message = apiError?.message ?? "Something went wrong. Please retry."
            throw ChatError.server(message: message)
        }
    }

    /// Reads the entire (small) error body and decodes the `{ error: {...} }`
    /// envelope. Returns `nil` if the body is missing or unparseable — callers
    /// fall back to a generic friendly message in that case.
    private static func decodeError(from bytes: URLSession.AsyncBytes) async -> APIError? {
        var data = Data()
        // Error bodies are tiny; accumulate raw bytes then decode.
        if let collected = try? await collect(bytes) {
            data = collected
        }
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error
    }

    /// Accumulates an `AsyncBytes` stream into `Data`.
    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    /// Parses the `Retry-After` header (seconds) if present.
    private static func retryAfterHeader(_ http: HTTPURLResponse) -> Int? {
        guard let value = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    // MARK: SSE parsing

    /// Parses the SSE line protocol into ``ChatEvent`` values.
    ///
    /// The protocol is `event:`/`data:` field lines grouped into records that
    /// are separated by a blank line. We accumulate fields for the current
    /// record and dispatch when the blank-line boundary is reached. A `data:`
    /// payload is a single-line JSON object (per the contract), so multi-line
    /// `data:` concatenation is supported defensively but not required.
    private func parseSSE(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        var eventName: String?
        var dataLines: [String] = []

        /// Dispatch the accumulated record, then reset for the next one.
        func flush() throws {
            defer {
                eventName = nil
                dataLines = []
            }
            guard let name = eventName, !dataLines.isEmpty else { return }
            let json = dataLines.joined(separator: "\n")
            guard let payload = json.data(using: .utf8) else { return }

            switch name {
            case "meta":
                if let meta = try? JSONDecoder().decode(Meta.self, from: payload) {
                    continuation.yield(.meta(meta))
                }
            case "delta":
                if let delta = try? JSONDecoder().decode(Delta.self, from: payload) {
                    continuation.yield(.delta(delta.text))
                }
            case "done":
                if let done = try? JSONDecoder().decode(Done.self, from: payload) {
                    continuation.yield(.done(done))
                }
            case "error":
                // Mid-stream failure: surface as a thrown error so the Views
                // layer handles it like any other error. The message is the
                // backend's friendly copy.
                let apiError = try? JSONDecoder().decode(APIError.self, from: payload)
                throw ChatError.server(
                    message: apiError?.message ?? "The model is unavailable. Please retry."
                )
            default:
                break // Ignore unknown event types for forward-compatibility.
            }
        }

        do {
            for try await line in bytes.lines {
                if line.isEmpty {
                    // Record boundary.
                    try flush()
                    continue
                }
                if line.hasPrefix(":") {
                    continue // SSE comment / heartbeat.
                }
                if let value = field("event", in: line) {
                    eventName = value
                } else if let value = field("data", in: line) {
                    dataLines.append(value)
                }
                // Other SSE fields (id, retry) are not used by this contract.
            }
            // Flush any trailing record not terminated by a blank line.
            try flush()
        } catch let chatError as ChatError {
            throw chatError
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch is URLError {
            throw ChatError.network
        }
    }

    /// Extracts the value of an SSE field line of the form `name:value` or
    /// `name: value` (a single leading space after the colon is stripped, per
    /// the SSE spec).
    private func field(_ name: String, in line: String) -> String? {
        let prefix = name + ":"
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        return value
    }
}
