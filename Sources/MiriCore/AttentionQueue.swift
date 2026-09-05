import Foundation

public struct AttentionItem: Identifiable, Equatable, Sendable {
    public var id: String { request.id }
    public let request: AgentInteractionRequest
    public let target: TargetDefinition
    public let adapterBacked: Bool
    public let expiresAt: Date?

    /// How long an approval stays answerable when the caller does not say.
    /// An agent that blocks and then dies emits nothing, so without a default
    /// its request waits forever and captures a much later utterance. Kept
    /// short because an approval blocks a live RPC the agent is sitting on.
    public static let approvalLifetime: TimeInterval = 300

    /// How long a question or blocker stays answerable. Long tasks are the
    /// point: an agent that works for half an hour and then asks something
    /// must still be answerable when the user comes back to the desk. Expiring
    /// it at the approval timeout silently re-routes that reply to whichever
    /// session happens to be recent instead.
    public static let questionLifetime: TimeInterval = 3_600

    public static func defaultLifetime(for kind: AgentInteractionRequest.Kind) -> TimeInterval {
        switch kind {
        case .approval: approvalLifetime
        case .question: questionLifetime
        }
    }

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
            ?? request.createdAt.addingTimeInterval(Self.defaultLifetime(for: request.kind))
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
        // Reads already filter by expiry; sweeping on write is what stops the
        // dictionary growing forever behind an agent that never answers.
        // Swept against the incoming request's own clock rather than wall time,
        // so the queue stays deterministic under an injected date.
        removeExpired(at: item.request.createdAt)
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
