import XCTest
@testable import MiriCore

/// Covers the approval path, where every stop-ship on this branch lived.
///
/// The queue types were tested in isolation while the decisions were made in
/// `AppController`, so nothing failed when a deny was silently swallowed.
/// `AppController.resolveApprovalTranscript` now delegates to `ApprovalOutcome`,
/// so these exercise the logic the app actually runs.
final class ApprovalOutcomeTests: XCTestCase {
    private struct DeadPipe: Error, LocalizedError {
        var errorDescription: String? { "broken pipe" }
    }

    /// The stop-ship: `respond` used `try?`, so a deny that never left the
    /// machine reported "Denied for codex-miri" — the worst possible failure
    /// direction on a permission boundary.
    func testAFailedSendIsNeverReportedAsSuccess() async {
        let outcome = await ApprovalOutcome.resolve(transcript: "deny request") { _ in
            throw DeadPipe()
        }

        XCTAssertFalse(outcome.reportsSuccess, "a decision that failed to send must not report success")
        XCTAssertTrue(
            outcome.requestRemainsPending,
            "a decision that failed to send must leave the request answerable"
        )
        let message = outcome.statusMessage(targetName: "codex-miri")
        XCTAssertFalse(message.hasPrefix("Denied"), "a lost deny must not read as a delivered one")
        XCTAssertTrue(message.contains("still waiting"))
    }

    func testADeliveredDecisionClearsTheRequestAndReportsIt() async {
        var sent: [AgentInteractionResponse] = []
        let outcome = await ApprovalOutcome.resolve(transcript: "approve request") { sent.append($0) }

        XCTAssertEqual(sent, [.approve])
        XCTAssertEqual(outcome, .delivered(.approve))
        XCTAssertTrue(outcome.reportsSuccess)
        XCTAssertFalse(outcome.requestRemainsPending)
        XCTAssertEqual(outcome.statusMessage(targetName: "codex-miri"), "Approved for codex-miri")
    }

    func testADeliveredDenialIsReportedAsADenial() async {
        let outcome = await ApprovalOutcome.resolve(transcript: "deny request") { _ in }

        XCTAssertEqual(outcome, .delivered(.deny))
        XCTAssertEqual(outcome.statusMessage(targetName: "codex-miri"), "Denied for codex-miri")
    }

    /// An ambiguous transcript must send nothing at all — not a default.
    func testAnUnrecognisedTranscriptSendsNothingAndKeepsTheRequest() async {
        var attempts = 0
        let outcome = await ApprovalOutcome.resolve(transcript: "uh, maybe later") { _ in attempts += 1 }

        XCTAssertEqual(attempts, 0, "an unrecognised transcript must not send any decision")
        XCTAssertEqual(outcome, .notUnderstood)
        XCTAssertFalse(outcome.reportsSuccess)
        XCTAssertTrue(outcome.requestRemainsPending)
    }
}
