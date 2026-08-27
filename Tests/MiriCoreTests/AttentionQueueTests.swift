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
}
