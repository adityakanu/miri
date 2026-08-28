import Foundation

/// One row in the session picker: a conversation the user can speak to, with an
/// honest answer to "is this running right now?".
///
/// Discovery from transcript timestamps cannot tell a session that ended an
/// hour ago from one still open. `LiveSessionScanner` can, but its results only
/// reached the menu bar. This type is where the two are joined, so every
/// surface shows the same ranked list and a running session is never buried
/// under stale ones.
public struct CatalogedSession: Identifiable, Equatable, Sendable {
    public let summary: AgentSessionSummary
    /// True when a process holding this session's transcript is running now.
    public let isRunningNow: Bool
    /// The configured target that routes to this session, when one exists.
    public let existingTargetID: String?

    public init(
        summary: AgentSessionSummary,
        isRunningNow: Bool,
        existingTargetID: String? = nil
    ) {
        self.summary = summary
        self.isRunningNow = isRunningNow
        self.existingTargetID = existingTargetID
    }

    public var id: String { summary.id }
    public var agent: AgentSessionSummary.Agent { summary.agent }
    public var isAdded: Bool { existingTargetID != nil }

    /// True when speaking to this session cannot work while it stays running.
    ///
    /// Codex owns the thread-store writer for a thread it has open, so
    /// `thread/resume` on a *live* Codex session always loses. Claude Code
    /// takes a session ID per invocation and has no such lock, and Hermes has
    /// no process-level identity at all, so neither conflicts.
    public var conflictsWithRunningProcess: Bool {
        isRunningNow && summary.agent == .codex
    }

    public var subtitle: String {
        [
            isRunningNow ? "Running now" : nil,
            summary.projectName,
            isAdded ? nil : "not yet added",
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    public var accessibilityLabel: String {
        "\(summary.title), \(summary.agent.displayName)\(isRunningNow ? ", running now" : "")"
    }
}

/// Joins the two independent session sources into one ranked catalog.
///
/// Pure so the ranking can be tested without a process table, a transcript
/// tree, or a network.
public enum SessionCatalog {
    /// Merges live and discovered sessions, running sessions first.
    ///
    /// A live session that discovery never found still appears: the scanner is
    /// the more trustworthy source, and a brand-new conversation whose
    /// transcript has not been flushed yet is exactly the one the user is most
    /// likely to want. Its title falls back to the project directory, which is
    /// how someone thinks about a terminal session anyway.
    public static func merge(
        discovered: [AgentSessionSummary],
        live: [LiveAgentSession],
        targets: [TargetDefinition],
        now: Date = .now
    ) -> [CatalogedSession] {
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targetBySession = Dictionary(
            targets.compactMap { target in target.session.map { ($0, target.id) } },
            uniquingKeysWith: { first, _ in first }
        )

        var rows: [CatalogedSession] = discovered.map { summary in
            CatalogedSession(
                summary: summary,
                isRunningNow: liveByID[summary.id] != nil,
                existingTargetID: targetBySession[summary.id]
            )
        }

        let known = Set(discovered.map(\.id))
        for session in live where !known.contains(session.id) {
            rows.append(
                CatalogedSession(
                    summary: AgentSessionSummary(
                        id: session.id,
                        agent: session.agent,
                        title: session.projectName ?? "\(session.agent.displayName) session",
                        workingDirectory: session.workingDirectory,
                        // Running now, so the recency ordering should place it
                        // at the top of its group rather than at the bottom.
                        lastActiveAt: now
                    ),
                    isRunningNow: true,
                    existingTargetID: targetBySession[session.id]
                )
            )
        }

        return rows.sorted { left, right in
            if left.isRunningNow != right.isRunningNow { return left.isRunningNow }
            if left.summary.lastActiveAt != right.summary.lastActiveAt {
                return left.summary.lastActiveAt > right.summary.lastActiveAt
            }
            return left.id < right.id
        }
    }

    /// Target IDs whose session belongs to the frontmost application.
    ///
    /// Feeds `ContextResolver.foregroundTargetIDs`, which was previously always
    /// empty — meaning the resolver's foreground rule could never fire.
    public static func foregroundTargetIDs(
        live: [LiveAgentSession],
        targets: [TargetDefinition],
        frontmostPID: pid_t?,
        parents: ProcessAncestry.ParentMap
    ) -> Set<String> {
        guard let frontmostPID else { return [] }
        let foregroundSessions = live
            .filter { ProcessAncestry.isDescendant($0.processID, of: frontmostPID, in: parents) }
            .map(\.id)
        guard !foregroundSessions.isEmpty else { return [] }
        let sessions = Set(foregroundSessions)
        return Set(targets.filter { $0.session.map(sessions.contains) ?? false }.map(\.id))
    }
}
