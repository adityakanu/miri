import XCTest
@testable import MiriCore

final class AttentionQueueTests: XCTestCase {
    func testKeepsMultipleRequestsFromOneTarget() async {
        let queue = AttentionQueue()
        let target = TargetDefinition(id: "codex-miri", name: "Codex · miri", adapter: "codex")
        let question = AgentInteractionRequest(id: "question", kind: .question, title: "Which API?")
        let approval = AgentInteractionRequest(id: "approval", kind: .approval, title: "Run tests?")

        await queue.add(.init(request: question, target: target, adapterBacked: false))
        await queue.add(.init(request: approval, target: target, adapterBacked: true))

        let pending = await queue.pending
        XCTAssertEqual(pending.map(\.request.id), ["approval", "question"])
    }

    func testRemovingOneRequestDoesNotRemoveItsSiblings() async {
        let queue = AttentionQueue()
        let target = TargetDefinition(id: "codex-miri", name: "Codex · miri", adapter: "codex")
        let first = AgentInteractionRequest(id: "first", kind: .approval, title: "Run tests?")
        let second = AgentInteractionRequest(id: "second", kind: .approval, title: "Change files?")

        await queue.add(.init(request: first, target: target, adapterBacked: true))
        await queue.add(.init(request: second, target: target, adapterBacked: true))
        _ = await queue.remove(id: "first")

        let pending = await queue.pending
        XCTAssertEqual(pending.map(\.request.id), ["second"])
    }

    func testLookupFailsClosedWhenRequestHasExpired() async {
        let queue = AttentionQueue()
        let now = Date(timeIntervalSince1970: 100)
        let target = TargetDefinition(id: "codex-miri", name: "Codex · miri", adapter: "codex")
        let request = AgentInteractionRequest(id: "approval", kind: .approval, title: "Run tests?", createdAt: now)
        await queue.add(.init(request: request, target: target, adapterBacked: true, expiresAt: now.addingTimeInterval(5)))

        let live = await queue.item(requestID: "approval", at: now.addingTimeInterval(4))
        let expired = await queue.item(requestID: "approval", at: now.addingTimeInterval(5))

        XCTAssertEqual(live?.id, "approval")
        XCTAssertNil(expired)
        let pending = await queue.pending(at: now.addingTimeInterval(5))
        XCTAssertTrue(pending.isEmpty)
    }
}
