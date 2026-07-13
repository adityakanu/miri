import XCTest
@testable import MiriCore

private actor DeliveryFakeAdapter: AgentAdapter {
    nonisolated let id = "fake"; nonisolated let capabilities: AdapterCapabilities = []
    var currentStatus: TargetStatus
    var received: [String] = []
    init(status: TargetStatus) { currentStatus = status }
    func connect() async throws {}; func disconnect() async {}
    func status() async -> TargetStatus { currentStatus }
    func sendUserMessage(_ text: String) async throws -> DeliveryReceipt { received.append(text); return .init(messageID: UUID()) }
    func setStatus(_ status: TargetStatus) { currentStatus = status }
    func cancelTurn() async throws {}
    nonisolated func events() -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
}

final class DeliveryCoordinatorTests: XCTestCase {
    func testRequiresReceiptForDelivered() async throws {
        let registry = AdapterRegistry(); await registry.register(DeliveryFakeAdapter(status: .ready), for: "target")
        let coordinator = DeliveryCoordinator(adapters: registry)
        let target = TargetDefinition(id: "target", name: "Target", adapter: "fake")
        let outcome = await coordinator.deliver("hello", to: .init(target: target, source: .configuredDefault))
        if case .delivered = outcome {} else { XCTFail("expected delivery receipt") }
    }
    func testDisconnectedMessageGoesToMemoryOutbox() async {
        let registry = AdapterRegistry(); await registry.register(DeliveryFakeAdapter(status: .disconnected), for: "target")
        let outcome = await DeliveryCoordinator(adapters: registry).deliver("hello", to: .init(target: .init(id: "target", name: "Target", adapter: "fake"), source: .configuredDefault))
        if case .outboxed(let entry) = outcome { XCTAssertEqual(entry.text, "hello") } else { XCTFail("expected outbox") }
    }

    func testQueuedMessageDrainsWhenAdapterBecomesReady() async {
        let registry = AdapterRegistry(); let adapter = DeliveryFakeAdapter(status: .busy)
        await registry.register(adapter, for: "target")
        let coordinator = DeliveryCoordinator(adapters: registry)
        let target = TargetDefinition(id: "target", name: "Target", adapter: "fake")
        let outcome = await coordinator.deliver("queued", to: .init(target: target, source: .configuredDefault))
        if case .queued = outcome {} else { return XCTFail("expected queue") }
        await adapter.setStatus(.ready)
        let drained = await coordinator.drainQueue(for: "target")
        if case .delivered? = drained {} else { XCTFail("expected drained delivery") }
        let received = await adapter.received
        XCTAssertEqual(received, ["queued"])
    }

    func testOutboxRetryRemovesOldEntry() async {
        let registry = AdapterRegistry(); let adapter = DeliveryFakeAdapter(status: .disconnected)
        await registry.register(adapter, for: "target")
        let coordinator = DeliveryCoordinator(adapters: registry)
        let target = TargetDefinition(id: "target", name: "Target", adapter: "fake")
        let failed = await coordinator.deliver("retry me", to: .init(target: target, source: .configuredDefault))
        guard case .outboxed(let entry) = failed else { return XCTFail("expected outbox") }
        await adapter.setStatus(.ready)
        _ = await coordinator.retryOutbox(id: entry.id, to: .init(target: target, source: .configuredDefault))
        let remainingEntries = await coordinator.outboxEntries()
        let received = await adapter.received
        XCTAssertTrue(remainingEntries.isEmpty)
        XCTAssertEqual(received, ["retry me"])
    }

    func testConfiguredConfirmationDoesNotReplaceQueueUntilApproved() async {
        let registry = AdapterRegistry(); let adapter = DeliveryFakeAdapter(status: .busy)
        await registry.register(adapter, for: "target")
        let coordinator = DeliveryCoordinator(adapters: registry)
        let target = TargetDefinition(id: "target", name: "Target", adapter: "fake", queueReplacement: "confirm")
        _ = await coordinator.deliver("first", to: .init(target: target, source: .configuredDefault))
        let second = await coordinator.deliver("second", to: .init(target: target, source: .configuredDefault))
        if case .confirmationRequired(let pending) = second { XCTAssertEqual(pending.text, "second") }
        else { XCTFail("expected confirmation") }
        let approved = await coordinator.deliver("second", to: .init(target: target, source: .configuredDefault), queuePolicy: .replace)
        if case .queued(let replacement) = approved { XCTAssertEqual(replacement.text, "second") }
        else { XCTFail("expected replacement queue") }
    }
}
