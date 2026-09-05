import Foundation

/// Installs Miri's voice-interaction skill file for coding agents that read
/// `SKILL.md` from a well-known directory (Codex, Claude Code).
///
/// Registering `miri-mcp` as an MCP server (`CodexMCPInstaller`) only makes
/// the `voice_status`/`voice_ask` tools callable — it does not teach an agent
/// *when* to call them, how to phrase a question for speech, or that an
/// unanswered `voice_ask` must never be read as approval. Without the skill
/// file, every agent improvises that contract from the bare tool
/// descriptions. This installs the same file the repository ships at
/// `skills/miri-voice/SKILL.md` into each agent's real skill directory.
public enum SkillInstaller {
    public static let skillName = "miri-voice"

    public struct AgentTarget: Equatable, Sendable {
        public let agent: AgentSessionSummary.Agent
        /// The agent's root skills directory, e.g. `~/.codex/skills`.
        public let skillsDirectory: URL
        public init(agent: AgentSessionSummary.Agent, skillsDirectory: URL) {
            self.agent = agent
            self.skillsDirectory = skillsDirectory
        }
    }

    /// Codex reads `~/.codex/skills/<name>/SKILL.md`; Claude Code reads
    /// `~/.claude/skills/<name>/SKILL.md`. Hermes has no filesystem skill
    /// convention (it is driven over its own REST API), so it is omitted.
    public static func knownTargets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentTarget] {
        [
            .init(agent: .codex, skillsDirectory: home.appending(path: ".codex/skills", directoryHint: .isDirectory)),
            .init(agent: .claude, skillsDirectory: home.appending(path: ".claude/skills", directoryHint: .isDirectory)),
        ]
    }

    /// True when the agent's own home directory already exists, i.e. the
    /// agent has been run at least once on this Mac. Installing a skill file
    /// for an agent that was never installed would create `~/.codex` or
    /// `~/.claude` out of nothing for no benefit.
    public static func isAgentPresent(_ target: AgentTarget) -> Bool {
        FileManager.default.fileExists(atPath: target.skillsDirectory.deletingLastPathComponent().path)
    }

    /// Writes `content` to every present agent's skill directory. Returns the
    /// agents it actually wrote to. Overwrites an existing copy so a Miri
    /// update can ship a corrected skill file; the destination is Miri's own
    /// named subdirectory, never touching another skill an agent might have.
    @discardableResult
    public static func install(
        content: String,
        targets: [AgentTarget] = knownTargets()
    ) throws -> [AgentSessionSummary.Agent] {
        var installed: [AgentSessionSummary.Agent] = []
        for target in targets where isAgentPresent(target) {
            let directory = target.skillsDirectory.appending(path: skillName, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try content.write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            installed.append(target.agent)
        }
        return installed
    }

    /// Reads the skill file text Miri ships. `build-community.sh` copies
    /// `skills/miri-voice/SKILL.md` into `Contents/Resources/` for the
    /// packaged app, where `Bundle.main` finds it directly. `swift run
    /// miri-app` has no such bundle, so it falls back to the checked-out
    /// source location captured at compile time.
    public static func bundledSkillContent(
        bundle: Bundle = .main,
        sourceFile: String = #filePath
    ) -> String {
        if let url = bundle.url(forResource: "miri-voice-SKILL", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        // sourceFile is .../<repo>/Sources/MiriCore/SkillInstaller.swift.
        let devPath = URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "skills/miri-voice/SKILL.md")
        if let content = try? String(contentsOf: devPath, encoding: .utf8) { return content }
        return Self.fallbackContent
    }

    /// Minimal fallback so a broken resource lookup degrades to a short
    /// working skill rather than installing nothing at all.
    static let fallbackContent = """
    ---
    name: miri-voice
    description: Use when working under Miri voice control. Report progress and ask blocking questions by voice.
    ---

    Use the `voice_ask` MCP tool to ask a blocking question and get a spoken
    reply without ending your turn. Use `voice_status` to speak progress or
    completion without waiting. Never treat \"no answer from the user\" as
    approval — it means the user did not respond.
    """
}
