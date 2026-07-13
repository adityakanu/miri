import Foundation

public enum TargetStatus: String, Codable, Sendable { case disconnected, connecting, ready, busy, failed }
public struct AdapterCapabilities: OptionSet, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let cancellation = Self(rawValue: 1 << 0)
    public static let streaming = Self(rawValue: 1 << 1)
    public static let attachments = Self(rawValue: 1 << 2)
}
public struct DeliveryReceipt: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable { case delivered, copied, queued }
    public let messageID: UUID; public let acceptedAt: Date; public let disposition: Disposition
    public init(messageID: UUID, acceptedAt: Date = .now, disposition: Disposition = .delivered) {
        self.messageID = messageID; self.acceptedAt = acceptedAt; self.disposition = disposition
    }
}
public enum AgentEvent: Codable, Equatable, Sendable {
    case status(TargetStatus), responseDelta(String), responseCompleted(String), completed, failed(String)
}
public protocol AgentAdapter: Sendable {
    var id: String { get }
    var capabilities: AdapterCapabilities { get }
    func connect() async throws
    func disconnect() async
    func status() async -> TargetStatus
    func sendUserMessage(_ text: String) async throws -> DeliveryReceipt
    func cancelTurn() async throws
    func events() -> AsyncStream<AgentEvent>
}
