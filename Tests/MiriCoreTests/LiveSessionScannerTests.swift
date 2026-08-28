import XCTest
@testable import MiriCore

final class LiveSessionScannerTests: XCTestCase {
    // MARK: - Session identifiers from open files

    func testCodexSessionIDComesFromTheOpenRolloutTranscript() {
        // Shape observed from a running `codex` process on macOS.
        let files = [
            "/Users/me/.codex/tmp/arg0/codex-arg0qw2cw9/.lock",
            "/Users/me/.codex/sessions/2026/08/04/rollout-2026-08-04T20-22-08-019fcd42-b351-7332-94f1-c5ea0f4dfce3.jsonl",
            "/Users/me/.codex/thread-writer-locks/019fcd42-b351-7332-94f1-c5ea0f4dfce3.lock",
        ]
        XCTAssertEqual(
            LiveSessionScanner.sessionIdentifier(agent: .codex, openFiles: files),
            "019fcd42-b351-7332-94f1-c5ea0f4dfce3"
        )
    }

    func testClaudeSessionIDComesFromTheProjectTranscriptName() {
        let id = "3f1a2b4c-5d6e-4f70-8192-a3b4c5d6e7f8"
        let files = ["/Users/me/.claude/projects/-Users-me-Developer-app/\(id).jsonl"]
        XCTAssertEqual(LiveSessionScanner.sessionIdentifier(agent: .claude, openFiles: files), id)
    }

    /// The rollout filename embeds a hyphen-separated timestamp before the
    /// UUID, so naive splitting recovers the wrong identifier.
    func testTimestampPrefixIsNotMistakenForTheIdentifier() {
        let name = "rollout-2026-08-04T20-22-08-019fcd42-b351-7332-94f1-c5ea0f4dfce3"
        XCTAssertEqual(LiveSessionScanner.trailingUUID(of: name), "019fcd42-b351-7332-94f1-c5ea0f4dfce3")
    }

    func testATranscriptOutsideTheAgentDirectoryIsIgnored() {
        // A UUID-named JSONL the agent merely happens to have open is not a
        // session; requiring the directory keeps an unrelated file from
        // becoming a bogus routing destination.
        let files = ["/Users/me/Downloads/019fcd42-b351-7332-94f1-c5ea0f4dfce3.jsonl"]
        XCTAssertNil(LiveSessionScanner.sessionIdentifier(agent: .codex, openFiles: files))
        XCTAssertNil(LiveSessionScanner.sessionIdentifier(agent: .claude, openFiles: files))
    }

    func testANonUUIDTranscriptNameIsRejected() {
        let files = ["/Users/me/.claude/projects/-Users-me-app/notes.jsonl"]
        XCTAssertNil(LiveSessionScanner.sessionIdentifier(agent: .claude, openFiles: files))
    }

    func testAProcessHoldingNoTranscriptHasNoSession() {
        XCTAssertNil(LiveSessionScanner.sessionIdentifier(agent: .codex, openFiles: ["/dev/null"]))
        XCTAssertNil(LiveSessionScanner.sessionIdentifier(agent: .codex, openFiles: []))
    }

    /// Hermes runs one application process rather than one per conversation,
    /// so it must not be guessed at from open files.
    func testHermesYieldsNoProcessLevelSession() {
        let files = ["/Users/me/.hermes/sessions/019fcd42-b351-7332-94f1-c5ea0f4dfce3.jsonl"]
        XCTAssertNil(LiveSessionScanner.sessionIdentifier(agent: .hermes, openFiles: files))
    }

    // MARK: - Scanning this machine

    /// The scan reads the real process table. It must never trap, never
    /// require a permission prompt, and must stay well inside the idle-CPU
    /// budget documented in docs/benchmarks.md.
    func testScanningIsSafeAndFastOnThisMachine() {
        let start = Date()
        let sessions = LiveSessionScanner.scan()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.5, "a live-session scan must not stall the menu")
        // Whatever is running, every returned session is well formed.
        for session in sessions {
            XCTAssertFalse(session.id.isEmpty)
            XCTAssertGreaterThan(session.processID, 0)
            XCTAssertNotEqual(session.agent, .hermes)
        }
        // Sessions are the unit the user picks, so they must be unique even
        // when a supervisor and its child both hold the transcript open.
        XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
    }

    func testProjectNameIsTheLastPathComponent() {
        let session = LiveAgentSession(
            id: "abc",
            agent: .codex,
            processID: 42,
            workingDirectory: "/Users/me/Developer/miri"
        )
        XCTAssertEqual(session.projectName, "miri")
    }
}
