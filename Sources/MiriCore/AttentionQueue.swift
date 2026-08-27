import Foundation

public struct AttentionItem: Identifiable, Equatable, Sendable {
    public var id: String { request.id }
    public let request: AgentInteractionRequest
    public let target: TargetDefinition
    public let adapterBacked: Bool
    public let expiresAt: Date?

    public init(
        request: AgentInteractionRequest,
        target: TargetDefinition,
        adapterBacked: Bool,
        expiresAt: Date? = nil
    ) {
        self.request = request
        self.target = target
        self.adapterBacked = adapterBacked
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

/// Everything currently waiting on the user, keyed by request ID.
///
/// Keying by request rather than by target is the point: one agent can raise a
/// question and an approval at once, and two agents can wait simultaneously.
/// A value type so the main-actor UI can hold it without actor hops.
public struct AttentionQueue: Equatable, Sendable {
    private var itemsByID: [String: AttentionItem] = [:]

    public init() {}

    public var isEmpty: Bool { itemsByID.isEmpty }

    /// Unexpired requests, approvals first, then oldest first.
    public func pending(at date: Date = .now) -> [AttentionItem] {
        itemsByID.values
            .filter { !$0.isExpired(at: date) }
            .sorted(by: Self.precedes)
    }

    /// Returns the request only while it is still answerable, so a delayed
    /// transcript cannot approve something the agent already withdrew.
    public func item(requestID: String, at date: Date = .now) -> AttentionItem? {
        guard let item = itemsByID[requestID], !item.isExpired(at: date) else { return nil }
        return item
    }

    public mutating func add(_ item: AttentionItem) {
        itemsByID[item.id] = item
    }

    @discardableResult
    public mutating func remove(id: String) -> AttentionItem? {
        itemsByID.removeValue(forKey: id)
    }

    public mutating func removeAll(targetID: String) {
        itemsByID = itemsByID.filter { $0.value.target.id != targetID }
    }

    public mutating func removeQuestions(targetID: String) {
        itemsByID = itemsByID.filter { $0.value.target.id != targetID || $0.value.request.kind != .question }
    }

    public mutating func removeExpired(at date: Date = .now) {
        itemsByID = itemsByID.filter { !$0.value.isExpired(at: date) }
    }

    private static func precedes(_ left: AttentionItem, _ right: AttentionItem) -> Bool {
        let leftPriority = left.request.kind == .approval ? 0 : 1
        let rightPriority = right.request.kind == .approval ? 0 : 1
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        if left.request.createdAt != right.request.createdAt {
            return left.request.createdAt < right.request.createdAt
        }
        return left.id < right.id
    }
}
