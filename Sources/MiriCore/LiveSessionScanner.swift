import Darwin
import Foundation

/// An agent session that is running *right now*, identified from the operating
/// system rather than inferred from file timestamps.
public struct LiveAgentSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let agent: AgentSessionSummary.Agent
    public let processID: pid_t
    /// The directory the agent process is running in.
    public let workingDirectory: String?

    public init(
        id: String,
        agent: AgentSessionSummary.Agent,
        processID: pid_t,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.processID = processID
        self.workingDirectory = workingDirectory
    }

    public var projectName: String? {
        workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

/// A live session together with the configured target that routes to it, if
/// one exists yet.
///
/// A session found in the process table is not automatically a target: the
/// user may never have spoken to it. Pairing the two lets one menu row both
/// select a known session and adopt a new one.
public struct LiveSessionRow: Identifiable, Equatable, Sendable {
    public let session: LiveAgentSession
    public let existingTarget: TargetDefinition?

    public init(session: LiveAgentSession, existingTarget: TargetDefinition?) {
        self.session = session
        self.existingTarget = existingTarget
    }

    public var id: String { session.id }

    /// Prefers the project directory, which is how someone thinks about a
    /// terminal session, over a UUID they have never seen.
    public var title: String {
        existingTarget?.name
            ?? session.projectName
            ?? "\(session.agent.displayName) \(session.id.prefix(8))"
    }

    public var subtitle: String {
        [session.agent.displayName, existingTarget == nil ? "not yet added" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    public var accessibilityLabel: String {
        "\(title), \(session.agent.displayName), running now"
    }
}

/// Finds the agent sessions that are live on this Mac.
///
/// Session lists reconstructed from transcript modification times cannot tell a
/// conversation that ended an hour ago from one still running, which is exactly
/// the distinction needed to put the right session at the top of the menu. The
/// operating system already knows: a running agent holds its session transcript
/// open for the lifetime of the process.
///
/// So the scan walks the process table, keeps processes whose executable name
/// belongs to a supported agent, and reads their open files to recover the
/// session identifier. Everything used here — `proc_listpids`, `proc_name`,
/// `proc_pidinfo` — is public libproc, and reading the working directory and
/// open files of a *same-user* process needs no entitlement and no permission
/// prompt. Measured at well under 2 ms for a full pass on a 500-process system.
///
/// Read-only: nothing here writes to, signals, or attaches to another process.
public enum LiveSessionScanner {
    /// Executable names that identify a supported agent. Compared
    /// case-insensitively against the process name.
    ///
    /// Hermes runs as a single application process rather than one process per
    /// conversation, so it exposes no per-session identifier here and is
    /// discovered through its REST API instead.
    static let agentExecutables: [String: AgentSessionSummary.Agent] = [
        "codex": .codex,
        "claude": .claude,
    ]

    /// Whether absence from a scan is meaningful for this adapter.
    ///
    /// Only agents that run one process per conversation can be observed this
    /// way. Hermes runs a single application process, so "not in the scan"
    /// tells us nothing about it and must never be read as "not running".
    public static func canDetectLiveness(_ adapter: String) -> Bool {
        agentExecutables.values.map(\.rawValue).contains(adapter)
    }

    public static func scan() -> [LiveAgentSession] {
        var candidates: [String: LiveAgentSession] = [:]
        for pid in processIdentifiers() {
            guard let agent = agentExecutables[executableName(of: pid).lowercased()] else { continue }
            let files = openFilePaths(of: pid)
            guard let id = sessionIdentifier(agent: agent, openFiles: files) else { continue }
            let candidate = LiveAgentSession(
                id: id,
                agent: agent,
                processID: pid,
                workingDirectory: workingDirectory(of: pid)
            )
            // A supervisor and its child can both hold the transcript open, and
            // `proc_listpids` order is not meaningful, so keeping whichever
            // arrived first picked an arbitrary process — and with it an
            // arbitrary working directory. Resolve it deterministically
            // instead.
            candidates[id] = preferred(candidates[id], candidate)
        }
        return candidates.values.sorted { $0.processID < $1.processID }
    }

    /// Chooses between two processes holding the same session transcript.
    ///
    /// A known working directory beats an unknown one, because that string is
    /// the session's label and its foreground match. Otherwise the higher PID
    /// wins: in a supervisor/child pair the child is spawned later, and the
    /// child is the process actually running the conversation.
    static func preferred(_ existing: LiveAgentSession?, _ candidate: LiveAgentSession) -> LiveAgentSession {
        guard let existing else { return candidate }
        switch (existing.workingDirectory, candidate.workingDirectory) {
        case (nil, .some): return candidate
        case (.some, nil): return existing
        default: return candidate.processID > existing.processID ? candidate : existing
        }
    }

    /// Recovers the session identifier from the files a process holds open.
    ///
    /// Codex writes `sessions/<date>/rollout-<timestamp>-<uuid>.jsonl`; Claude
    /// Code writes `projects/<encoded-path>/<uuid>.jsonl`. Both keep the file
    /// open while the session is alive, so the filename is the identifier.
    /// Exposed for testing with fabricated paths, since a test cannot conjure a
    /// running agent.
    static func sessionIdentifier(
        agent: AgentSessionSummary.Agent,
        openFiles: [String]
    ) -> String? {
        for path in openFiles where path.hasSuffix(".jsonl") {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            switch agent {
            case .codex:
                guard path.contains("/sessions/"), let uuid = trailingUUID(of: name) else { continue }
                return uuid
            case .claude:
                guard path.contains("/projects/"), isUUID(name) else { continue }
                return name
            case .hermes:
                continue
            }
        }
        return nil
    }

    /// `rollout-2026-08-04T20-22-08-019fcd42-b351-7332-94f1-c5ea0f4dfce3` →
    /// the trailing UUID. The prefix contains hyphen-separated date parts, so
    /// the identifier is taken as the last five hyphen-separated groups rather
    /// than by splitting the whole name.
    static func trailingUUID(of name: String) -> String? {
        let parts = name.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let candidate = parts.suffix(5).joined(separator: "-")
        return isUUID(candidate) ? candidate : nil
    }

    static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    // MARK: - libproc

    private static func processIdentifiers() -> [pid_t] {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, size)
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func executableName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return buffer.withUnsafeBufferPointer {
            $0.baseAddress.map { String(cString: $0) } ?? ""
        }
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDVNODEPATHINFO, 0, &info,
            Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )
        guard size > 0 else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    private static func openFilePaths(of pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(size) / MemoryLayout<proc_fdinfo>.size
        )
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
        guard written > 0 else { return [] }

        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(written) / MemoryLayout<proc_fdinfo>.size)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let got = proc_pidfdinfo(
                pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard got > 0 else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}
