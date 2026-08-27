import XCTest
@testable import MiriCore

private func makeTarget(_ id: String, name: String? = nil, project: String? = nil) -> TargetDefinition {
    TargetDefinition(id: id, name: name ?? id, adapter: "codex", project: project)
}

final class AgentHUDTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)

    func testSessionsNeedingAttentionSortAboveEverythingElse() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(kind: .approval, title: "Run tests?"), target: makeTarget("waiting"), adapterBacked: true))

        let rows = AgentHUDModel(
            sessions: [
                .init(target: makeTarget("busy"), status: .busy, lastActiveAt: now, expiresAt: now.addingTimeInterval(60)),
                .init(target: makeTarget("waiting"), status: .ready, lastActiveAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(60)),
                .init(target: makeTarget("idle"), status: .ready, lastActiveAt: now.addingTimeInterval(-30), expiresAt: now.addingTimeInterval(60)),
            ],
            attention: queue,
            now: now
        ).rows

        XCTAssertEqual(rows.map(\.id), ["waiting", "busy", "idle"])
        XCTAssertEqual(rows.first?.state, .needsApproval)
    }

    func testForegroundSessionOutranksMerelyRecentOnes() {
        let rows = AgentHUDModel(
            sessions: [
                .init(target: makeTarget("recent"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(60)),
                .init(target: makeTarget("front"), status: .ready, lastActiveAt: now.addingTimeInterval(-120), expiresAt: now.addingTimeInterval(60)),
            ],
            attention: AttentionQueue(),
            foregroundTargetIDs: ["front"],
            now: now
        ).rows

        XCTAssertEqual(rows.map(\.id), ["front", "recent"])
    }

    /// The panel shows five rows; the rest stay reachable rather than vanishing.
    func testOverflowIsReportedRatherThanSilentlyDropped() {
        let sessions = (1...8).map { index in
            SessionPresence(
                target: makeTarget("s\(index)"),
                status: .ready,
                lastActiveAt: now.addingTimeInterval(-Double(index)),
                expiresAt: now.addingTimeInterval(60)
            )
        }
        let model = AgentHUDModel(sessions: sessions, attention: AttentionQueue(), now: now)

        XCTAssertEqual(model.rows.count, 8)
        XCTAssertEqual(model.visibleRowCount, 5)
        XCTAssertEqual(model.hiddenRowCount, 3)
    }

    func testMutedSessionStillShowsItsAttentionBadge() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(kind: .question, title: "Which API?"), target: makeTarget("muted"), adapterBacked: false))

        let rows = AgentHUDModel(
            sessions: [.init(target: makeTarget("muted"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(60))],
            attention: queue,
            mutedTargetIDs: ["muted"],
            now: now
        ).rows

        XCTAssertEqual(rows.first?.state, .needsAnswer)
        XCTAssertTrue(rows.first?.isMuted == true)
    }

    func testRowsDescribeThemselvesForVoiceOver() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(kind: .approval, title: "Run tests?"), target: makeTarget("codex-miri", name: "Codex", project: "miri"), adapterBacked: true))

        let row = AgentHUDModel(
            sessions: [.init(target: makeTarget("codex-miri", name: "Codex", project: "miri"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(60))],
            attention: queue,
            now: now
        ).rows.first

        XCTAssertEqual(row?.accessibilityLabel, "Codex, miri, needs approval")
    }

    func testEmptyDirectoryIsAnExplicitState() {
        let model = AgentHUDModel(sessions: [], attention: AttentionQueue(), now: now)
        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.rows.isEmpty)
    }
}
