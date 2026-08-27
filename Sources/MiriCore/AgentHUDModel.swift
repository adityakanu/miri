import Foundation

/// What a session is doing, in the terms the HUD shows the user.
public enum AgentHUDState: String, Equatable, Sendable {
    case needsApproval
    case needsAnswer
    case failed
    case working
    case ready
    case disconnected

    /// Attention first, then activity. Drives row order.
    var rank: Int {
        switch self {
        case .needsApproval: 0
        case .needsAnswer: 1
        case .failed: 2
        case .working: 3
        case .ready: 4
        case .disconnected: 5
        }
    }

    public var label: String {
        switch self {
        case .needsApproval: "Needs approval"
        case .needsAnswer: "Needs answer"
        case .failed: "Failed"
        case .working: "Working"
        case .ready: "Ready"
        case .disconnected: "Disconnected"
        }
    }

    public var needsAttention: Bool {
        self == .needsApproval || self == .needsAnswer || self == .failed
    }
}

public struct AgentHUDRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let project: String?
    public let state: AgentHUDState
    public let isMuted: Bool
    public let matchesForeground: Bool
    public let lastActiveAt: Date

    public var accessibilityLabel: String {
        [name, project, state.label.lowercased()]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// The Agent HUD's contents, derived purely from live sessions and whatever is
/// waiting on the user.
///
/// Kept free of AppKit so ordering, attention, and overflow are testable
/// without a window server.
public struct AgentHUDModel: Equatable, Sendable {
    /// The panel is sized for five rows; more remain reachable by scrolling.
    public static let maximumVisibleRows = 5

    public let rows: [AgentHUDRow]

    public init(
        sessions: [SessionPresence],
        attention: AttentionQueue,
        foregroundTargetIDs: Set<String> = [],
        mutedTargetIDs: Set<String> = [],
        now: Date = .now
    ) {
        let waiting = attention.pending(at: now)
        rows = sessions
            .filter { !$0.isExpired(at: now) }
            .map { session in
                let requests = waiting.filter { $0.target.id == session.target.id }
                let state: AgentHUDState
                if requests.contains(where: { $0.request.kind == .approval }) {
                    state = .needsApproval
                } else if !requests.isEmpty {
                    state = .needsAnswer
                } else {
                    switch session.status {
                    case .failed: state = .failed
                    case .busy: state = .working
                    case .ready, .connecting: state = .ready
                    case .disconnected: state = .disconnected
                    }
                }
                return AgentHUDRow(
                    id: session.target.id,
                    name: session.target.name,
                    project: session.target.project,
                    state: state,
                    // Muting silences speech; it never hides that an agent is
                    // blocked, or a muted agent could wait forever unnoticed.
                    isMuted: mutedTargetIDs.contains(session.target.id),
                    matchesForeground: foregroundTargetIDs.contains(session.target.id),
                    lastActiveAt: session.lastActiveAt
                )
            }
            .sorted { left, right in
                if left.state.rank != right.state.rank { return left.state.rank < right.state.rank }
                if left.matchesForeground != right.matchesForeground { return left.matchesForeground }
                if left.lastActiveAt != right.lastActiveAt { return left.lastActiveAt > right.lastActiveAt }
                return left.id < right.id
            }
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var visibleRowCount: Int { min(rows.count, Self.maximumVisibleRows) }
    public var hiddenRowCount: Int { max(0, rows.count - Self.maximumVisibleRows) }
    public var attentionCount: Int { rows.filter(\.state.needsAttention).count }

    /// Header summary, e.g. "3 agents need attention".
    public var summary: String {
        if rows.isEmpty { return "No agent sessions" }
        let waiting = attentionCount
        if waiting == 0 { return rows.count == 1 ? "1 agent session" : "\(rows.count) agent sessions" }
        return waiting == 1 ? "1 agent needs attention" : "\(waiting) agents need attention"
    }
}
