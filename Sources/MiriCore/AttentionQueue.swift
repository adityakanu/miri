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

public actor AttentionQueue {
    private var itemsByID: [String: AttentionItem] = [:]

    public init() {}

    public var pending: [AttentionItem] {
        pending(at: .now)
    }

    public func pending(at date: Date) -> [AttentionItem] {
        removeExpired(at: date)
        return itemsByID.values.sorted(by: Self.precedes)
    }

    public func item(requestID: String, at date: Date = .now) -> AttentionItem? {
        guard let item = itemsByID[requestID] else { return nil }
        guard !item.isExpired(at: date) else {
            itemsByID.removeValue(forKey: requestID)
            return nil
        }
        return item
    }

    public func add(_ item: AttentionItem) {
        itemsByID[item.id] = item
    }

    @discardableResult
    public func remove(id: String) -> AttentionItem? {
        itemsByID.removeValue(forKey: id)
    }

    public func removeAll(targetID: String) {
        itemsByID = itemsByID.filter { $0.value.target.id != targetID }
    }

    private func removeExpired(at date: Date) {
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
