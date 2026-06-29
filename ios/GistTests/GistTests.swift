//
//  GistTests.swift
//  GistTests
//
//  Minimal, dependency-light unit tests for the Gist client. These intentionally
//  exercise only pure, side-effect-free code (constants and value types) so they
//  run fast and need no network, Keychain, StoreKit, or SwiftData.
//
//  The heavy lifting — brevity enforcement and the daily volume cap — is tested
//  server-side (see backend/test), because that is the trust boundary. The
//  client is never trusted to limit length or count messages.
//

import XCTest
@testable import Gist

final class GistTests: XCTestCase {

    // MARK: - Config invariants

    /// The UI copy constant must reflect the product promise (under 100 words).
    /// This is the *only* place 100 appears on the client, and it is for copy
    /// only — the real cap is enforced server-side via the injected system prompt.
    func testWordCapCopyIsOneHundred() {
        XCTAssertEqual(AppConfig.wordCapCopy, 100)
    }

    /// The client entitlement id must match the value the backend checks. If
    /// these drift, a paid user would never be recognized as paid.
    func testEntitlementIdMatchesContractDefault() {
        XCTAssertEqual(AppConfig.entitlementId, "premium")
    }

    /// The monthly StoreKit product id is namespaced under the bundle id so it is
    /// unambiguous in App Store Connect.
    func testMonthlyProductIdIsNamespaced() {
        XCTAssertTrue(AppConfig.monthlyProductId.hasPrefix("app.gist"))
    }

    // MARK: - Pure value-type behavior

    /// The typed `MessageRole` round-trips to the wire `role` string exactly as
    /// the API contract specifies (`user` / `assistant`, lowercase).
    func testWireRoleMappingFromTypedRole() {
        let userTurn = ChatRequest.Wire(role: .user, content: "Capital of France?")
        let assistantTurn = ChatRequest.Wire(role: .assistant, content: "Paris.")

        XCTAssertEqual(userTurn.role, "user")
        XCTAssertEqual(assistantTurn.role, "assistant")
        XCTAssertEqual(userTurn.content, "Capital of France?")
    }

    /// `MessageRole.isUser` drives bubble alignment in the UI; verify the pure
    /// branch logic.
    func testMessageRoleIsUserFlag() {
        XCTAssertTrue(MessageRole.user.isUser)
        XCTAssertFalse(MessageRole.assistant.isUser)
    }

    /// Unknown error codes from a future backend must decode to `.unknown`
    /// instead of throwing, so an older client never crashes on a new code.
    func testUnknownErrorCodeDecodesToUnknown() throws {
        let json = Data(#""some_future_code""#.utf8)
        let decoded = try JSONDecoder().decode(ErrorCode.self, from: json)
        XCTAssertEqual(decoded, .unknown)
    }
}
