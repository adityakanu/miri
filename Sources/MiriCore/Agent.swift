import Foundation

public enum TargetStatus: String, Codable, Sendable { case disconnected, connecting, ready, busy, failed }
public struct AdapterCapabilities: OptionSet, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let cancellation = Self(rawValue: 1 << 0)
    public static let streaming = Self(rawValue: 1 << 1)
    public static let attachments = Self(rawValue: 1 << 2)
    public static let interactiveRequests = Self(rawValue: 1 << 3)
}
public struct AgentInteractionRequest: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case question, approval }
    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String?
    public let createdAt: Date
    public init(id: String = UUID().uuidString, kind: Kind, title: String, detail: String? = nil, createdAt: Date = .now) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.createdAt = createdAt
    }
}
public enum AgentInteractionResponse: Codable, Equatable, Sendable {
    case text(String), approve, deny
}
public enum VoiceApprovalParser {
    public static func parse(_ transcript: String) -> AgentInteractionResponse? {
        let normalized = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        if ["approve request", "miri approve request"].contains(normalized) { return .approve }
        if ["deny request", "miri deny request", "decline request"].contains(normalized) { return .deny }
        return nil
    }
}
public struct DeliveryReceipt: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable { case delivered, copied, queued }
    public let messageID: UUID; public let acceptedAt: Date; public let disposition: Disposition
    public init(messageID: UUID, acceptedAt: Date = .now, disposition: Disposition = .delivered) {
        self.messageID = messageID; self.acceptedAt = acceptedAt; self.disposition = disposition
    }
}
public enum AgentEvent: Codable, Equatable, Sendable {
    case status(TargetStatus), responseDelta(String), responseCompleted(String), interactionRequested(AgentInteractionRequest), completed, failed(String)
}
public protocol AgentAdapter: Sendable {
    var id: String { get }
    var capabilities: AdapterCapabilities { get }
    func connect() async throws
    func disconnect() async
    func status() async -> TargetStatus
    func sendUserMessage(_ text: String) async throws -> DeliveryReceipt
    func cancelTurn() async throws
    func respond(to requestID: String, with response: AgentInteractionResponse) async throws
    func events() -> AsyncStream<AgentEvent>
}

public extension AgentAdapter {
    func respond(to requestID: String, with response: AgentInteractionResponse) async throws {
        throw AdapterError.unsupportedInteraction
    }
}
