import XCTest
@testable import MiriCore

final class AttentionQueueTests: XCTestCase {
    private let target = TargetDefinition(id: "codex-miri", name: "Codex · miri", adapter: "codex")

    func testKeepsMultipleRequestsFromOneTarget() {
        var queue = AttentionQueue()
        let question = AgentInteractionRequest(id: "question", kind: .question, title: "Which API?")
        let approval = AgentInteractionRequest(id: "approval", kind: .approval, title: "Run tests?")

        queue.add(.init(request: question, target: target, adapterBacked: false))
        queue.add(.init(request: approval, target: target, adapterBacked: true))

        XCTAssertEqual(queue.pending().map(\.request.id), ["approval", "question"])
    }

    func testRemovingOneRequestDoesNotRemoveItsSiblings() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(id: "first", kind: .approval, title: "Run tests?"), target: target, adapterBacked: true))
        queue.add(.init(request: .init(id: "second", kind: .approval, title: "Change files?"), target: target, adapterBacked: true))

        queue.remove(id: "first")

        XCTAssertEqual(queue.pending().map(\.request.id), ["second"])
    }

    /// A delayed transcript must not approve a request the agent withdrew.
    func testLookupFailsClosedWhenRequestHasExpired() {
        var queue = AttentionQueue()
        let now = Date(timeIntervalSince1970: 100)
        let request = AgentInteractionRequest(id: "approval", kind: .approval, title: "Run tests?", createdAt: now)
        queue.add(.init(request: request, target: target, adapterBacked: true, expiresAt: now.addingTimeInterval(5)))

        XCTAssertEqual(queue.item(requestID: "approval", at: now.addingTimeInterval(4))?.id, "approval")
        XCTAssertNil(queue.item(requestID: "approval", at: now.addingTimeInterval(5)))
        XCTAssertTrue(queue.pending(at: now.addingTimeInterval(5)).isEmpty)
    }

    /// Production never passed an expiry, so `isExpired` was always false and
    /// a hung agent's request waited forever, ready to capture a much later
    /// utterance. Requests must expire by default.
    func testRequestsExpireWithoutTheCallerAskingForIt() {
        var queue = AttentionQueue()
        let now = Date(timeIntervalSince1970: 100)
        let request = AgentInteractionRequest(id: "approval", kind: .approval, title: "Run tests?", createdAt: now)
        queue.add(.init(request: request, target: target, adapterBacked: true))

        let lifetime = AttentionItem.approvalLifetime
        XCTAssertNotNil(queue.item(requestID: "approval", at: now.addingTimeInterval(lifetime - 1)))
        XCTAssertNil(
            queue.item(requestID: "approval", at: now.addingTimeInterval(lifetime)),
            "a request with no explicit expiry must not stay answerable forever"
        )
    }

    /// A long autonomous task is the whole point of the blocker flow: an agent
    /// works for half an hour, then asks something. Expiring that question on
    /// the approval timeout would silently re-route the user's reply to
    /// whichever session happened to be recent instead.
    func testQuestionsOutliveApprovals() {
        var queue = AttentionQueue()
        let now = Date(timeIntervalSince1970: 100)
        let question = AgentInteractionRequest(id: "question", kind: .question, title: "Which database?", createdAt: now)
        queue.add(.init(request: question, target: target, adapterBacked: false))

        XCTAssertGreaterThan(AttentionItem.questionLifetime, AttentionItem.approvalLifetime)
        XCTAssertNotNil(
            queue.item(requestID: "question", at: now.addingTimeInterval(AttentionItem.approvalLifetime + 1)),
            "a blocker raised by a long-running task must still be answerable after the approval timeout"
        )
        XCTAssertNil(queue.item(requestID: "question", at: now.addingTimeInterval(AttentionItem.questionLifetime)))
    }

    /// Disconnecting an agent must clear everything it was waiting on.
    func testRemovingATargetClearsOnlyItsOwnRequests() {
        var queue = AttentionQueue()
        let other = TargetDefinition(id: "codex-other", name: "Codex · other", adapter: "codex")
        queue.add(.init(request: .init(id: "mine", kind: .approval, title: "Run tests?"), target: target, adapterBacked: true))
        queue.add(.init(request: .init(id: "theirs", kind: .approval, title: "Deploy?"), target: other, adapterBacked: true))

        queue.removeAll(targetID: target.id)

        XCTAssertEqual(queue.pending().map(\.id), ["theirs"])
    }

    /// Answering a question resolves it, but a pending approval still stands.
    func testClearingQuestionsLeavesApprovalsPending() {
        var queue = AttentionQueue()
        queue.add(.init(request: .init(id: "question", kind: .question, title: "Which API?"), target: target, adapterBacked: false))
        queue.add(.init(request: .init(id: "approval", kind: .approval, title: "Run tests?"), target: target, adapterBacked: true))

        queue.removeQuestions(targetID: target.id)

        XCTAssertEqual(queue.pending().map(\.id), ["approval"])
    }
}
