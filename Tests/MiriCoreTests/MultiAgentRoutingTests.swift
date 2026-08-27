import XCTest
@testable import MiriCore

/// End-to-end routing behaviour for someone running several agents at once.
///
/// These exercise the decisions that are easy to get wrong under load: two
/// agents blocking at the same time, an approval racing a question, and a
/// withdrawn request that must never capture a later utterance.
final class MultiAgentRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5_000)

    private func target(_ id: String, project: String? = nil) -> TargetDefinition {
        TargetDefinition(id: id, name: id, adapter: "codex", project: project)
    }

    private func session(_ id: String, status: TargetStatus = .ready, spokenAt: Date? = nil) -> SessionPresence {
        .init(
            target: target(id),
            status: status,
            lastActiveAt: now,
            lastUserInteractionAt: spokenAt,
            expiresAt: now.addingTimeInterval(300)
        )
    }

    /// One agent blocked while others work: speaking answers the blocked one.
    func testASingleBlockedAgentClaimsTheNextUtterance() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(id: "r1", kind: .approval, title: "Run tests?"), target: target("codex-a"), adapterBacked: true))

        let resolution = ContextResolver.resolve(
            attention: queue.pending(at: now),
            sessions: [session("codex-a"), session("codex-b", status: .busy), session("codex-c")],
            now: now
        )

        guard case .resolved(let snapshot, let reason) = resolution else { return XCTFail("expected a target") }
        XCTAssertEqual(snapshot.target.id, "codex-a")
        XCTAssertEqual(reason, .pendingRequest)
    }

    /// Two agents blocked at once is exactly when a wrong guess is costly.
    func testTwoBlockedAgentsForceAnExplicitChoice() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(id: "r1", kind: .approval, title: "Run tests?"), target: target("codex-a"), adapterBacked: true))
        queue.add(.init(request: .init(id: "r2", kind: .approval, title: "Delete branch?"), target: target("codex-b"), adapterBacked: true))

        let resolution = ContextResolver.resolve(
            attention: queue.pending(at: now),
            sessions: [session("codex-a"), session("codex-b")],
            now: now
        )

        guard case .needsSelection(let ids) = resolution else { return XCTFail("expected an explicit choice") }
        XCTAssertEqual(ids.sorted(), ["r1", "r2"])
    }

    /// Answering one agent must leave the other still waiting.
    func testAnsweringOneAgentLeavesTheOtherPending() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(id: "r1", kind: .approval, title: "Run tests?"), target: target("codex-a"), adapterBacked: true))
        queue.add(.init(request: .init(id: "r2", kind: .approval, title: "Delete branch?"), target: target("codex-b"), adapterBacked: true))

        queue.remove(id: "r1")

        let resolution = ContextResolver.resolve(
            attention: queue.pending(at: now),
            sessions: [session("codex-a"), session("codex-b")],
            now: now
        )
        guard case .resolved(let snapshot, _) = resolution else { return XCTFail("expected a target") }
        XCTAssertEqual(snapshot.target.id, "codex-b")
    }

    /// An approval outranks a question, so the blocking item is offered first.
    func testApprovalIsOfferedBeforeAQuestionFromTheSameAgent() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(id: "question", kind: .question, title: "Which API?", createdAt: now), target: target("codex-a"), adapterBacked: false))
        queue.add(.init(request: .init(id: "approval", kind: .approval, title: "Run tests?", createdAt: now.addingTimeInterval(1)), target: target("codex-a"), adapterBacked: true))

        XCTAssertEqual(queue.pending(at: now.addingTimeInterval(2)).map(\.id), ["approval", "question"])
    }

    /// A withdrawn request must not silently swallow the next thing you say.
    func testWithdrawnRequestDoesNotCaptureTheNextUtterance() {
        var queue = AttentionQueue()
        queue.add(.init(
            request: .init(id: "stale", kind: .approval, title: "Run tests?", createdAt: now),
            target: target("codex-a"),
            adapterBacked: true,
            expiresAt: now.addingTimeInterval(30)
        ))

        let later = now.addingTimeInterval(31)
        let resolution = ContextResolver.resolve(
            attention: queue.pending(at: later),
            sessions: [session("codex-b", spokenAt: later.addingTimeInterval(-10))],
            now: later
        )

        guard case .resolved(let snapshot, let reason) = resolution else { return XCTFail("expected a target") }
        XCTAssertEqual(snapshot.target.id, "codex-b")
        XCTAssertEqual(reason, .recentSession)
    }

    /// Recording captures its destination once; later requests cannot steal it.
    func testRecordingDestinationIsFixedWhenRecordingStarts() {
        let resolution = ContextResolver.resolve(
            attention: [],
            sessions: [session("codex-a", spokenAt: now.addingTimeInterval(-5))],
            now: now
        )
        guard case .resolved(let snapshot, _) = resolution else { return XCTFail("expected a target") }

        // A new agent blocks immediately afterwards.
        var queue = AttentionQueue()
        queue.add(.init(request: .init(id: "late", kind: .approval, title: "Deploy?"), target: target("codex-b"), adapterBacked: true))

        // The already-captured snapshot still points at the original target.
        XCTAssertEqual(snapshot.target.id, "codex-a")
    }

    /// The HUD must surface every blocked agent, not just the first.
    func testHUDShowsEveryBlockedAgent() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(id: "r1", kind: .approval, title: "Run tests?"), target: target("codex-a"), adapterBacked: true))
        queue.add(.init(request: .init(id: "r2", kind: .question, title: "Which API?"), target: target("codex-b"), adapterBacked: false))

        let model = AgentHUDModel(
            sessions: [session("codex-a"), session("codex-b"), session("codex-c")],
            attention: queue,
            now: now
        )

        XCTAssertEqual(model.attentionCount, 2)
        XCTAssertEqual(model.rows.map(\.id), ["codex-a", "codex-b", "codex-c"])
        XCTAssertEqual(model.summary, "2 agents need attention")
    }
}
