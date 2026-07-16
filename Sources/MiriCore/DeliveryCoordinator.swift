import Foundation

public actor AdapterRegistry {
    private var adapters: [String: any AgentAdapter] = [:]
    public init() {}
    public func register(_ adapter: any AgentAdapter, for targetID: String) { adapters[targetID] = adapter }
    public func unregister(targetID: String) async { if let adapter = adapters.removeValue(forKey: targetID) { await adapter.disconnect() } }
    public func disconnectAll() async {
        let current = adapters.values; adapters.removeAll()
        for adapter in current { await adapter.disconnect() }
    }
    public func adapter(for targetID: String) -> (any AgentAdapter)? { adapters[targetID] }
    public func statuses() async -> [String: TargetStatus] {
        var result: [String: TargetStatus] = [:]
        for (targetID, adapter) in adapters { result[targetID] = await adapter.status() }
        return result
    }
}

public enum DeliveryOutcome: Equatable, Sendable {
    case delivered(DeliveryReceipt), copied(DeliveryReceipt), queued(QueuedVoiceMessage), confirmationRequired(QueuedVoiceMessage), outboxed(OutboxEntry)
}

public actor DeliveryCoordinator {
    private let adapters: AdapterRegistry
    private let queue: PerTargetVoiceQueue
    private let outbox: TranscriptOutbox
    public init(adapters: AdapterRegistry, queue: PerTargetVoiceQueue = .init(), outbox: TranscriptOutbox = .init()) {
        self.adapters = adapters; self.queue = queue; self.outbox = outbox
    }

    public func deliver(_ text: String, to snapshot: RecordingTargetSnapshot, queuePolicy: QueueReplacementPolicy? = nil) async -> DeliveryOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .outboxed(await outbox.add(text: text, intendedTargetID: snapshot.target.id, failure: "Transcript was empty"))
        }
        guard let adapter = await adapters.adapter(for: snapshot.target.id) else {
            return .outboxed(await outbox.add(text: text, intendedTargetID: snapshot.target.id, failure: "No adapter is registered"))
        }
        let status = await adapter.status()
        if status == .busy {
            let message = QueuedVoiceMessage(targetID: snapshot.target.id, text: text)
            do { _ = try await queue.enqueue(message, policy: queuePolicy ?? snapshot.target.queueReplacementPolicy); return .queued(message) }
            catch VoiceQueueError.confirmationRequired { return .confirmationRequired(message) }
            catch { return .outboxed(await outbox.add(text: text, intendedTargetID: snapshot.target.id, failure: error.localizedDescription)) }
        }
        guard status == .ready else {
            return .outboxed(await outbox.add(text: text, intendedTargetID: snapshot.target.id, failure: "Target is \(status.rawValue)"))
        }
        do {
            let receipt = try await adapter.sendUserMessage(text)
            return receipt.disposition == .copied ? .copied(receipt) : .delivered(receipt)
        } catch {
            return .outboxed(await outbox.add(text: text, intendedTargetID: snapshot.target.id, failure: error.localizedDescription))
        }
    }

    public func drainQueue(for targetID: String) async -> DeliveryOutcome? {
        guard let message = await queue.message(for: targetID), let adapter = await adapters.adapter(for: targetID) else { return nil }
        guard await adapter.status() == .ready else { return nil }
        _ = await queue.dequeue(for: targetID)
        do {
            let receipt = try await adapter.sendUserMessage(message.text)
            return receipt.disposition == .copied ? .copied(receipt) : .delivered(receipt)
        } catch {
            return .outboxed(await outbox.add(text: message.text, intendedTargetID: targetID, failure: error.localizedDescription))
        }
    }

    public func outboxEntries() async -> [OutboxEntry] { await outbox.entries() }
    public func editOutbox(id: UUID, text: String) async -> OutboxEntry? { await outbox.edit(id: id, text: text) }
    public func discardOutbox(id: UUID) async { _ = await outbox.discard(id: id) }
    public func textForCopy(id: UUID) async -> String? { await outbox.textForCopy(id: id) }

    public func retryOutbox(id: UUID, to snapshot: RecordingTargetSnapshot) async -> DeliveryOutcome? {
        guard let entry = await outbox.entry(id: id) else { return nil }
        let outcome = await deliver(entry.text, to: snapshot)
        switch outcome {
        case .delivered, .copied, .queued: await outbox.removeAfterSuccessfulRetry(id: id)
        case .confirmationRequired: break
        case .outboxed: await outbox.removeAfterSuccessfulRetry(id: id)
        }
        return outcome
    }
}
