import XCTest
@testable import MiriCore

/// `approvalResult(for:response:)` is the pure piece behind
/// `CodexAppServerAdapter.respond`. Codex's app-server exposes five distinct
/// approval RPC methods with different response schemas; sending the wrong
/// shape makes Codex silently reject the decision over the wire while Miri
/// reports it as delivered. These pin the shape against the real Codex
/// JSON schemas (verified with `codex app-server generate-json-schema`).
final class CodexApprovalResultTests: XCTestCase {
    func testCommandExecutionUsesAcceptDeclineStrings() throws {
        let approve = try CodexAppServerAdapter.approvalResult(for: "item/commandExecution/requestApproval", response: .approve)
        XCTAssertEqual(approve["decision"] as? String, "accept")
        let deny = try CodexAppServerAdapter.approvalResult(for: "item/commandExecution/requestApproval", response: .deny)
        XCTAssertEqual(deny["decision"] as? String, "decline")
    }

    func testFileChangeUsesAcceptDeclineStrings() throws {
        let approve = try CodexAppServerAdapter.approvalResult(for: "item/fileChange/requestApproval", response: .approve)
        XCTAssertEqual(approve["decision"] as? String, "accept")
        let deny = try CodexAppServerAdapter.approvalResult(for: "item/fileChange/requestApproval", response: .deny)
        XCTAssertEqual(deny["decision"] as? String, "decline")
    }

    /// The legacy ReviewDecision schema does NOT accept "accept"/"decline":
    /// approval is the bare string "approved"; denial is an object with a
    /// "denied" key. Revert-to-RED: sending {"decision":"decline"} here is
    /// what the previous code did and is invalid against the real schema.
    func testLegacyExecApprovalUsesApprovedOrDeniedObject() throws {
        let approve = try CodexAppServerAdapter.approvalResult(for: "execCommandApproval", response: .approve)
        XCTAssertEqual(approve["decision"] as? String, "approved")
        let deny = try CodexAppServerAdapter.approvalResult(for: "execCommandApproval", response: .deny)
        XCTAssertNotEqual(deny["decision"] as? String, "decline")
        XCTAssertNotNil((deny["decision"] as? [String: Any])?["denied"])
    }

    func testApplyPatchApprovalUsesApprovedOrDeniedObject() throws {
        let approve = try CodexAppServerAdapter.approvalResult(for: "applyPatchApproval", response: .approve)
        XCTAssertEqual(approve["decision"] as? String, "approved")
        let deny = try CodexAppServerAdapter.approvalResult(for: "applyPatchApproval", response: .deny)
        XCTAssertNotNil((deny["decision"] as? [String: Any])?["denied"])
    }

    /// Permissions requests require a specific GrantedPermissionProfile that
    /// Miri has no basis to synthesize from a voice approve/deny. Throwing
    /// here (rather than sending a bare decision Codex would reject) is what
    /// keeps ApprovalOutcome reporting `.notDelivered` and the request
    /// answerable, instead of a lost decision looking delivered.
    func testPermissionsRequestIsRejectedRatherThanGuessed() {
        XCTAssertThrowsError(try CodexAppServerAdapter.approvalResult(for: "item/permissions/requestApproval", response: .approve))
    }
}
