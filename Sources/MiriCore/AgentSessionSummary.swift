import Foundation

/// One discoverable agent conversation, whatever agent it belongs to.
///
/// Codex, Claude Code, and Hermes each expose sessions differently — JSON-RPC,
/// files on disk, and REST respectively — so discovery is normalized here and
/// the UI renders one kind of row instead of three.
public struct AgentSessionSummary: Identifiable, Equatable, Sendable {
    /// Which agent the session belongs to. The raw value is the adapter name
    /// written to `config.toml`, so a discovered session can be turned into a
    /// target without a lookup table.
    public enum Agent: String, CaseIterable, Sendable {
        case codex
        case claude
        case hermes

        public var displayName: String {
            switch self {
            case .codex: "Codex"
            case .claude: "Claude Code"
            case .hermes: "Hermes"
            }
        }

        /// Codex is the only adapter with live end-to-end validation.
        public var isExperimental: Bool { self != .codex }
    }

    public let id: String
    public let agent: Agent
    public let title: String
    /// Absolute path the session runs in, when the agent records one.
    public let workingDirectory: String?
    public let lastActiveAt: Date

    public init(
        id: String,
        agent: Agent,
        title: String,
        workingDirectory: String? = nil,
        lastActiveAt: Date
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.workingDirectory = workingDirectory
        self.lastActiveAt = lastActiveAt
    }

    /// Last path component of the working directory, for a compact row label.
    public var projectName: String? {
        workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Stable target ID so adding the same session twice is a no-op rather than
    /// a duplicate row in `config.toml`.
    public var suggestedTargetID: String { "\(agent.rawValue)-\(id.prefix(8))" }
}
