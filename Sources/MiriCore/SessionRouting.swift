import Foundation

/// A live agent session Miri currently knows about.
///
/// Presence is deliberately ephemeral: sessions come and go with the agents
/// that own them, so they expire instead of accumulating in config.toml.
public struct SessionPresence: Identifiable, Equatable, Sendable {
    public var id: String { target.id }

    public let target: TargetDefinition
    public var status: TargetStatus
    public var lastActiveAt: Date
    public var lastUserInteractionAt: Date?
    public var expiresAt: Date

    public init(
        target: TargetDefinition,
        status: TargetStatus,
        lastActiveAt: Date,
        lastUserInteractionAt: Date? = nil,
        expiresAt: Date
    ) {
        self.target = target
        self.status = status
        self.lastActiveAt = lastActiveAt
        self.lastUserInteractionAt = lastUserInteractionAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool { expiresAt <= date }

    /// How long an agent stays listed as live after its last observed
    /// activity. Presence is refreshed by every agent event, so this only
    /// expires sessions that have genuinely gone quiet.
    public static let liveWindow: TimeInterval = 900
}

/// Why Miri chose a destination. Surfaced in the overlay and logs so an
/// automatic choice is never mysterious.
public enum RoutingReason: String, Equatable, Sendable {
    case explicit
    case pendingRequest
    case foregroundContext
    case recentSession
    case pinnedDefault
}

public enum ContextResolution: Equatable, Sendable {
    case resolved(RecordingTargetSnapshot, RoutingReason)
    /// Several candidates are equally plausible; ask rather than guess.
    case needsSelection([String])
    case noTarget
}

/// Chooses where the next utterance goes.
///
/// Deterministic and pure so the decision can be tested without a microphone,
/// an agent, or a window server.
public enum ContextResolver {
    /// How long a session stays a plausible implicit destination after you
    /// last spoke to it.
    public static let recentWindow: TimeInterval = 300

    public static func resolve(
        explicitTarget: TargetDefinition? = nil,
        attention: [AttentionItem] = [],
        sessions: [SessionPresence] = [],
        foregroundTargetIDs: Set<String> = [],
        pinnedDefault: TargetDefinition? = nil,
        now: Date = .now,
        recordingID: UUID = UUID()
    ) -> ContextResolution {
        func snapshot(_ target: TargetDefinition, _ source: RoutingSource, _ reason: RoutingReason) -> ContextResolution {
            .resolved(.init(recordingID: recordingID, target: target, source: source, capturedAt: now), reason)
        }

        if let explicitTarget {
            return snapshot(explicitTarget, .activeSelection, .explicit)
        }

        // An expired request must never capture the microphone: the agent has
        // already stopped waiting for that answer.
        let waiting = attention.filter { !$0.isExpired(at: now) }
        if waiting.count == 1, let only = waiting.first {
            return snapshot(only.target, .activeSelection, .pendingRequest)
        }
        if waiting.count > 1 {
            return .needsSelection(waiting.map(\.id))
        }

        let live = sessions.filter { !$0.isExpired(at: now) }
        let foreground = live.filter { foregroundTargetIDs.contains($0.target.id) }
        if foreground.count == 1, let only = foreground.first {
            return snapshot(only.target, .activeSelection, .foregroundContext)
        }

        let recent = live
            .compactMap { session -> (SessionPresence, Date)? in
                guard let spokenAt = session.lastUserInteractionAt,
                      now.timeIntervalSince(spokenAt) <= recentWindow else { return nil }
                return (session, spokenAt)
            }
            .sorted { $0.1 > $1.1 }
        if let mostRecent = recent.first?.0 {
            return snapshot(mostRecent.target, .activeSelection, .recentSession)
        }

        if let pinnedDefault {
            return snapshot(pinnedDefault, .configuredDefault, .pinnedDefault)
        }
        return .noTarget
    }
}
