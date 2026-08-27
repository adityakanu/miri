import Foundation

public struct AttentionItem: Identifiable, Equatable, Sendable {
    public var id: String { request.id }
    public let request: AgentInteractionRequest
    public let target: TargetDefinition
    public let adapterBacked: Bool

    public init(request: AgentInteractionRequest, target: TargetDefinition, adapterBacked: Bool) {
        self.request = request
        self.target = target
        self.adapterBacked = adapterBacked
    }
}

public actor AttentionQueue {
    private var items: [AttentionItem] = []

    public init() {}

    public var pending: [AttentionItem] {
        items.sorted {
            let left = $0.request.kind == .approval ? 0 : 1
            let right = $1.request.kind == .approval ? 0 : 1
            return left == right ? $0.request.createdAt < $1.request.createdAt : left < right
        }
    }

    public func add(_ item: AttentionItem) {
        items.removeAll { $0.id == item.id }
        items.append(item)
    }

    @discardableResult
    public func remove(id: String) -> AttentionItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    public func removeAll(targetID: String) {
        items.removeAll { $0.target.id == targetID }
    }
}
