import Foundation

public enum StatusPolicyError: Error, Equatable, LocalizedError {
    case empty, tooLong, sensitive, duplicate, rateLimited
    public var errorDescription: String? {
        switch self {
        case .empty: "Status text is empty"
        case .tooLong: "Status text exceeds 180 characters"
        case .sensitive: "Status text appears to contain a secret or code"
        case .duplicate: "Duplicate status"
        case .rateLimited: "Status rate limit exceeded"
        }
    }
}

public actor StatusPolicy {
    private var recent: [(String, Date)] = []
    private let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public func validate(_ request: VoiceStatusRequest) throws {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StatusPolicyError.empty }
        guard text.count <= 180 else { throw StatusPolicyError.tooLong }
        let blocked = ["BEGIN PRIVATE KEY", "API_KEY=", "sk-", "```", "func ", "class ", "import ",
                       "/Users/", "/var/", "Traceback (most recent call last)", "fatal error:"]
        guard !blocked.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { throw StatusPolicyError.sensitive }
        let timestamp = now(); recent.removeAll { timestamp.timeIntervalSince($0.1) > 30 }
        guard !recent.contains(where: { $0.0 == text && timestamp.timeIntervalSince($0.1) < 10 }) else { throw StatusPolicyError.duplicate }
        guard recent.count < 6 else { throw StatusPolicyError.rateLimited }
        recent.append((text, timestamp))
    }
}
