import XCTest
@testable import MiriCore

final class StatusPolicyTests: XCTestCase {
    func testRejectsSecretsAndCode() async {
        let policy = StatusPolicy()
        do { try await policy.validate(.init(text: "API_KEY=secret")); XCTFail("expected rejection") }
        catch { XCTAssertEqual(error as? StatusPolicyError, .sensitive) }
    }
    func testRejectsDuplicate() async throws {
        let policy = StatusPolicy(); try await policy.validate(.init(text: "Tests passed"))
        do { try await policy.validate(.init(text: "Tests passed")); XCTFail("expected duplicate") }
        catch { XCTAssertEqual(error as? StatusPolicyError, .duplicate) }
    }
}
