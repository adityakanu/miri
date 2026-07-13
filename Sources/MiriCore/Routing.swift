import Foundation

public struct TargetDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var agent: String?
    public var adapter: String
    public var workingDirectory: String?
    public var project: String?
    public var session: String?
    public var endpoint: String?
    public var hotkey: String?
    public var queueReplacement: String
    public var enabled: Bool
    public var capabilities: AdapterCapabilities

    public init(id: String, name: String, agent: String? = nil, adapter: String, workingDirectory: String? = nil, project: String? = nil, session: String? = nil, endpoint: String? = nil, hotkey: String? = nil, enabled: Bool = true, queueReplacement: String = "reject", capabilities: AdapterCapabilities = []) {
        self.id = id; self.name = name; self.agent = agent; self.adapter = adapter
        self.workingDirectory = workingDirectory; self.project = project; self.session = session
        self.endpoint = endpoint; self.hotkey = hotkey; self.enabled = enabled; self.queueReplacement = queueReplacement
        self.capabilities = capabilities
    }
}

public struct TargetRegistry: Sendable {
    private var targetsByID: [String: TargetDefinition]
    public init(targets: [TargetDefinition]) { targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) }) }
    public var targets: [TargetDefinition] { targetsByID.values.sorted { $0.id < $1.id } }
    public func target(id: String?) -> TargetDefinition? { id.flatMap { targetsByID[$0] }.flatMap { $0.enabled ? $0 : nil } }
    public func target(hotkey: String?) -> TargetDefinition? { guard let hotkey else { return nil }; return targets.first { $0.enabled && $0.hotkey?.lowercased() == hotkey.lowercased() } }
    public mutating func update(_ target: TargetDefinition) { targetsByID[target.id] = target }
    public mutating func remove(id: String) { targetsByID.removeValue(forKey: id) }
}

public enum RoutingSource: String, Equatable, Sendable { case dedicatedHotkey, activeSelection, configuredDefault }
public struct RecordingTargetSnapshot: Equatable, Sendable {
    public let recordingID: UUID
    public let target: TargetDefinition
    public let source: RoutingSource
    public let capturedAt: Date
    public init(recordingID: UUID = UUID(), target: TargetDefinition, source: RoutingSource, capturedAt: Date = .now) { self.recordingID = recordingID; self.target = target; self.source = source; self.capturedAt = capturedAt }
}
public enum RoutingError: Error, Equatable, LocalizedError {
    case noTarget
    public var errorDescription: String? { "No enabled target is configured; the transcript was kept in the outbox." }
}
public struct TargetRouter: Sendable {
    public var registry: TargetRegistry
    public var defaultTargetID: String?
    public init(registry: TargetRegistry, defaultTargetID: String? = nil) { self.registry = registry; self.defaultTargetID = defaultTargetID }
    public func snapshot(dedicatedHotkey: String? = nil, activeTargetID: String? = nil, recordingID: UUID = UUID(), now: Date = .now) throws -> RecordingTargetSnapshot {
        if let target = registry.target(hotkey: dedicatedHotkey) { return .init(recordingID: recordingID, target: target, source: .dedicatedHotkey, capturedAt: now) }
        if let target = registry.target(id: activeTargetID) { return .init(recordingID: recordingID, target: target, source: .activeSelection, capturedAt: now) }
        if let target = registry.target(id: defaultTargetID) { return .init(recordingID: recordingID, target: target, source: .configuredDefault, capturedAt: now) }
        throw RoutingError.noTarget
    }
}

public struct QueuedVoiceMessage: Identifiable, Equatable, Sendable {
    public let id: UUID; public let targetID: String; public var text: String; public let createdAt: Date
    public init(id: UUID = UUID(), targetID: String, text: String, createdAt: Date = .now) { self.id = id; self.targetID = targetID; self.text = text; self.createdAt = createdAt }
}
public enum QueueReplacementPolicy: Sendable { case reject, replace, requireConfirmation }

public extension TargetDefinition {
    var queueReplacementPolicy: QueueReplacementPolicy {
        switch queueReplacement { case "replace": .replace; case "confirm": .requireConfirmation; default: .reject }
    }
}
public enum VoiceQueueError: Error, Equatable, LocalizedError {
    case occupied, confirmationRequired
    public var errorDescription: String? {
        switch self {
        case .occupied: "A voice message is already queued for this target"
        case .confirmationRequired: "Replacing the queued voice message requires confirmation"
        }
    }
}
public enum VoiceQueueResult: Equatable, Sendable { case enqueued, replaced(QueuedVoiceMessage) }
public actor PerTargetVoiceQueue {
    private var messages: [String: QueuedVoiceMessage] = [:]
    public init() {}
    public func enqueue(_ message: QueuedVoiceMessage, policy: QueueReplacementPolicy, confirmed: Bool = false) throws -> VoiceQueueResult {
        guard let old = messages[message.targetID] else { messages[message.targetID] = message; return .enqueued }
        switch policy {
        case .reject: throw VoiceQueueError.occupied
        case .requireConfirmation where !confirmed: throw VoiceQueueError.confirmationRequired
        case .replace, .requireConfirmation: messages[message.targetID] = message; return .replaced(old)
        }
    }
    public func message(for targetID: String) -> QueuedVoiceMessage? { messages[targetID] }
    public func dequeue(for targetID: String) -> QueuedVoiceMessage? { messages.removeValue(forKey: targetID) }
}

public struct OutboxEntry: Identifiable, Equatable, Sendable {
    public let id: UUID; public var text: String; public let intendedTargetID: String?; public let failure: String; public let createdAt: Date
    public init(id: UUID = UUID(), text: String, intendedTargetID: String?, failure: String, createdAt: Date = .now) { self.id = id; self.text = text; self.intendedTargetID = intendedTargetID; self.failure = failure; self.createdAt = createdAt }
}
public actor TranscriptOutbox {
    private var storage: [UUID: OutboxEntry] = [:]
    public init() {}
    @discardableResult public func add(text: String, intendedTargetID: String?, failure: String) -> OutboxEntry { let entry = OutboxEntry(text: text, intendedTargetID: intendedTargetID, failure: failure); storage[entry.id] = entry; return entry }
    public func entries() -> [OutboxEntry] { storage.values.sorted { $0.createdAt < $1.createdAt } }
    public func entry(id: UUID) -> OutboxEntry? { storage[id] }
    public func textForCopy(id: UUID) -> String? { storage[id]?.text }
    public func edit(id: UUID, text: String) -> OutboxEntry? { guard var entry = storage[id] else { return nil }; entry.text = text; storage[id] = entry; return entry }
    @discardableResult public func discard(id: UUID) -> OutboxEntry? { storage.removeValue(forKey: id) }
    public func removeAfterSuccessfulRetry(id: UUID) { storage.removeValue(forKey: id) }
    public func clear() { storage.removeAll() }
}
