import XCTest
@testable import MiriCore

private func makeTarget(_ id: String, adapter: String = "codex", session: String? = nil, enabled: Bool = true) -> TargetDefinition {
    TargetDefinition(id: id, name: id, adapter: adapter, session: session, enabled: enabled)
}

private func makeSummary(_ id: String, agent: AgentSessionSummary.Agent = .codex, at seconds: TimeInterval) -> AgentSessionSummary {
    AgentSessionSummary(
        id: id,
        agent: agent,
        title: id,
        lastActiveAt: Date(timeIntervalSince1970: seconds)
    )
}

private func makeLive(_ id: String, agent: AgentSessionSummary.Agent = .codex, pid: pid_t = 100, cwd: String? = nil) -> LiveAgentSession {
    LiveAgentSession(id: id, agent: agent, processID: pid, workingDirectory: cwd)
}

final class SessionCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: - Merging

    /// The whole point of the merge: transcript mtime cannot tell a finished
    /// conversation from a running one, so a running session must not be
    /// ranked below a more recently *written* dead one.
    func testARunningSessionOutranksAMoreRecentlyModifiedDeadOne() {
        let rows = SessionCatalog.merge(
            discovered: [
                makeSummary("dead", at: 9_999),
                makeSummary("alive", at: 1),
            ],
            live: [makeLive("alive")],
            targets: [],
            now: now
        )
        XCTAssertEqual(rows.map(\.id), ["alive", "dead"])
        XCTAssertTrue(rows[0].isRunningNow)
        XCTAssertFalse(rows[1].isRunningNow)
    }

    /// A conversation started seconds ago may not have a flushed transcript
    /// yet, and it is exactly the one the user wants.
    func testALiveSessionDiscoveryHasNotSeenIsStillListed() {
        let rows = SessionCatalog.merge(
            discovered: [],
            live: [makeLive("brand-new", cwd: "/Users/me/Developer/miri")],
            targets: [],
            now: now
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isRunningNow)
        XCTAssertEqual(rows[0].summary.title, "miri")
        XCTAssertEqual(rows[0].summary.lastActiveAt, now)
    }

    func testASessionIsNotDuplicatedWhenBothSourcesSeeIt() {
        let rows = SessionCatalog.merge(
            discovered: [makeSummary("shared", at: 5_000)],
            live: [makeLive("shared")],
            targets: [],
            now: now
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isRunningNow)
        // Discovery's richer title survives; only liveness is taken from the scan.
        XCTAssertEqual(rows[0].summary.title, "shared")
    }

    func testAnExistingTargetIsPairedWithItsSession() {
        let rows = SessionCatalog.merge(
            discovered: [makeSummary("s1", at: 1)],
            live: [],
            targets: [makeTarget("codex-s1", session: "s1")],
            now: now
        )
        XCTAssertEqual(rows[0].existingTargetID, "codex-s1")
        XCTAssertTrue(rows[0].isAdded)
    }

    func testDeadSessionsKeepRecencyOrdering() {
        let rows = SessionCatalog.merge(
            discovered: [makeSummary("old", at: 1), makeSummary("newer", at: 500)],
            live: [],
            targets: [],
            now: now
        )
        XCTAssertEqual(rows.map(\.id), ["newer", "old"])
    }

    // MARK: - Writer conflict

    /// A live Codex thread is held by the Codex process that makes it live, so
    /// `thread/resume` cannot win. The UI must be able to say so up front.
    func testARunningCodexSessionIsFlaggedAsConflicting() {
        let rows = SessionCatalog.merge(
            discovered: [],
            live: [makeLive("c1", agent: .codex)],
            targets: [],
            now: now
        )
        XCTAssertTrue(rows[0].conflictsWithRunningProcess)
    }

    /// Claude Code takes a session ID per invocation and holds no writer lock.
    func testARunningClaudeSessionIsNotFlagged() {
        let rows = SessionCatalog.merge(
            discovered: [],
            live: [makeLive("k1", agent: .claude)],
            targets: [],
            now: now
        )
        XCTAssertFalse(rows[0].conflictsWithRunningProcess)
    }

    func testANonRunningCodexSessionIsNotFlagged() {
        let rows = SessionCatalog.merge(
            discovered: [makeSummary("c2", at: 1)],
            live: [],
            targets: [],
            now: now
        )
        XCTAssertFalse(rows[0].conflictsWithRunningProcess)
    }

    // MARK: - Foreground resolution

    /// The rule this unlocks was previously unreachable: no caller ever passed
    /// `foregroundTargetIDs`, so `ContextResolver`'s foreground branch was dead.
    func testAgentLaunchedFromTheFrontmostTerminalIsForeground() {
        // terminal(500) → shell(600) → codex(700)
        let parents: ProcessAncestry.ParentMap = [700: 600, 600: 500, 500: 1]
        let ids = SessionCatalog.foregroundTargetIDs(
            live: [makeLive("s1", pid: 700)],
            targets: [makeTarget("codex-s1", session: "s1")],
            frontmostPID: 500,
            parents: parents
        )
        XCTAssertEqual(ids, ["codex-s1"])
    }

    func testAnAgentUnderADifferentApplicationIsNotForeground() {
        let parents: ProcessAncestry.ParentMap = [700: 600, 600: 400, 400: 1, 500: 1]
        let ids = SessionCatalog.foregroundTargetIDs(
            live: [makeLive("s1", pid: 700)],
            targets: [makeTarget("codex-s1", session: "s1")],
            frontmostPID: 500,
            parents: parents
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testNoFrontmostApplicationYieldsNoForegroundTargets() {
        let ids = SessionCatalog.foregroundTargetIDs(
            live: [makeLive("s1", pid: 700)],
            targets: [makeTarget("codex-s1", session: "s1")],
            frontmostPID: nil,
            parents: [700: 500]
        )
        XCTAssertTrue(ids.isEmpty)
    }

    /// A live session with no configured target cannot be routed to, so it must
    /// not contribute a foreground ID.
    func testALiveSessionWithNoTargetContributesNothing() {
        let ids = SessionCatalog.foregroundTargetIDs(
            live: [makeLive("s1", pid: 700)],
            targets: [makeTarget("unrelated", session: "other")],
            frontmostPID: 500,
            parents: [700: 500]
        )
        XCTAssertTrue(ids.isEmpty)
    }
}

final class ProcessAncestryTests: XCTestCase {
    func testAProcessIsItsOwnAncestor() {
        XCTAssertTrue(ProcessAncestry.isDescendant(100, of: 100, in: [:]))
    }

    func testDescendantIsFoundThroughIntermediateProcesses() {
        XCTAssertTrue(ProcessAncestry.isDescendant(400, of: 100, in: [400: 300, 300: 200, 200: 100]))
    }

    func testUnrelatedProcessesAreNotDescendants() {
        XCTAssertFalse(ProcessAncestry.isDescendant(400, of: 999, in: [400: 300, 300: 200, 200: 1]))
    }

    /// A malformed map must terminate rather than spin the walk forever.
    func testACycleTerminatesInsteadOfLooping() {
        XCTAssertFalse(ProcessAncestry.isDescendant(1, of: 999, in: [1: 2, 2: 3, 3: 1]))
    }

    func testTheWalkStopsAtTheRoot() {
        XCTAssertFalse(ProcessAncestry.isDescendant(5, of: 999, in: [5: 1, 1: 0]))
    }
}

final class LiveSessionPreferenceTests: XCTestCase {
    /// `proc_listpids` order is not meaningful, so keeping the first-seen
    /// process picked an arbitrary working directory for the session label.
    func testAKnownWorkingDirectoryBeatsAnUnknownOne() {
        let withoutCWD = makeLive("s", pid: 900, cwd: nil)
        let withCWD = makeLive("s", pid: 100, cwd: "/Users/me/project")
        XCTAssertEqual(LiveSessionScanner.preferred(withoutCWD, withCWD).processID, 100)
        XCTAssertEqual(LiveSessionScanner.preferred(withCWD, withoutCWD).processID, 100)
    }

    /// In a supervisor/child pair the child is spawned later and is the process
    /// actually running the conversation.
    func testTheChildProcessWinsWhenBothKnowTheirDirectory() {
        let parent = makeLive("s", pid: 100, cwd: "/a")
        let child = makeLive("s", pid: 900, cwd: "/a")
        XCTAssertEqual(LiveSessionScanner.preferred(parent, child).processID, 900)
        XCTAssertEqual(LiveSessionScanner.preferred(child, parent).processID, 900)
    }

    func testTheFirstCandidateIsKeptWhenThereIsNoIncumbent() {
        XCTAssertEqual(LiveSessionScanner.preferred(nil, makeLive("s", pid: 42)).processID, 42)
    }

    /// Hermes runs one process for every conversation, so its absence from a
    /// scan says nothing and must never expire its presence.
    func testLivenessIsOnlyDetectableForPerSessionAgents() {
        XCTAssertTrue(LiveSessionScanner.canDetectLiveness("codex"))
        XCTAssertTrue(LiveSessionScanner.canDetectLiveness("claude"))
        XCTAssertFalse(LiveSessionScanner.canDetectLiveness("hermes"))
        XCTAssertFalse(LiveSessionScanner.canDetectLiveness("clipboard"))
    }
}

final class CodexWriterConflictTests: XCTestCase {
    func testAWriterConflictBecomesAnActionableError() {
        let raw = CodexAppServerError.rpc(-32_000, "thread already has an active writer")
        let classified = CodexAppServerError.classify(raw, threadID: "t1")
        guard case CodexAppServerError.threadBusyElsewhere(let id) = classified else {
            return XCTFail("expected a writer-conflict error")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertTrue(classified.localizedDescription.contains("open in Codex"))
    }

    /// An unrelated RPC failure must not be relabelled as a writer conflict, or
    /// a real error would be hidden behind misleading advice.
    func testAnUnrelatedRPCErrorIsPassedThroughUnchanged() {
        let raw = CodexAppServerError.rpc(-32_601, "method not found")
        guard case CodexAppServerError.rpc(let code, _) = CodexAppServerError.classify(raw, threadID: "t1") else {
            return XCTFail("expected the original error")
        }
        XCTAssertEqual(code, -32_601)
    }

    func testANonRPCErrorIsPassedThroughUnchanged() {
        let raw = CodexAppServerError.timedOut("thread/resume")
        guard case CodexAppServerError.timedOut = CodexAppServerError.classify(raw, threadID: "t1") else {
            return XCTFail("expected the original error")
        }
    }
}

final class HermesEndpointConfigurationTests: XCTestCase {
    /// Hermes discovery was circular: the endpoint came only from an existing
    /// Hermes target, but a target is what you build *from* discovery. A
    /// `[hermes]` section breaks the loop, so it must parse without warnings.
    func testAHermesEndpointSectionParsesCleanly() throws {
        let result = try MiriConfigurationParser.parse(
            """
            version = 1
            input_mode = "push_to_talk"

            [hermes]
            endpoint = "http://127.0.0.1:8642"
            """
        )
        XCTAssertEqual(
            result.configuration.sections["hermes"]?["endpoint"],
            .string("http://127.0.0.1:8642")
        )
        XCTAssertTrue(
            result.warnings.filter { $0.severity == .warning }.isEmpty,
            "a documented setting must not warn: \(result.warnings)"
        )
    }

    /// The allowlist still has to reject typos, or it is not doing its job.
    func testAnUnknownHermesKeyStillWarns() throws {
        let result = try MiriConfigurationParser.parse(
            """
            version = 1
            input_mode = "push_to_talk"

            [hermes]
            endpiont = "http://127.0.0.1:8642"
            """
        )
        XCTAssertFalse(result.warnings.isEmpty)
    }
}
