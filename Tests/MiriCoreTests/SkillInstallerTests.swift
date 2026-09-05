import XCTest
@testable import MiriCore

/// SkillInstaller is the gap between "voice_status/voice_ask are callable"
/// (CodexMCPInstaller registers the MCP server) and "an agent knows when and
/// how to use them" — without the skill file on disk, an agent improvises the
/// contract from bare tool descriptions alone.
final class SkillInstallerTests: XCTestCase {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// The skill installs only for agents that have actually been run on this
    /// Mac (their home directory already exists). Installing for an agent
    /// that was never used would create ~/.codex or ~/.claude from nothing.
    func testInstallsOnlyForAgentsAlreadyPresent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        // .claude is deliberately absent.

        let targets = SkillInstaller.knownTargets(home: home)
        let installed = try SkillInstaller.install(content: "---\nname: miri-voice\n---\nbody", targets: targets)

        XCTAssertEqual(installed, [.codex])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: ".codex/skills/miri-voice/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/miri-voice/SKILL.md").path))
    }

    func testInstallsForBothAgentsWhenBothArePresent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)

        let installed = try SkillInstaller.install(content: "content", targets: SkillInstaller.knownTargets(home: home))

        XCTAssertEqual(Set(installed), [.codex, .claude])
    }

    /// A Miri update must be able to correct a previously installed skill
    /// file, not just install it once and never touch it again.
    func testReinstallOverwritesAnExistingCopy() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        let targets = SkillInstaller.knownTargets(home: home)

        _ = try SkillInstaller.install(content: "old content", targets: targets)
        _ = try SkillInstaller.install(content: "new content", targets: targets)

        let written = try String(contentsOf: home.appending(path: ".codex/skills/miri-voice/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(written, "new content")
    }

    /// The bundled skill file must be the real, checked-in one — not a stub —
    /// so agents get the actual voice_ask/voice_status guidance.
    func testBundledSkillContentIsTheRealSkillFile() {
        let content = SkillInstaller.bundledSkillContent()
        XCTAssertTrue(content.contains("name: miri-voice"))
        XCTAssertTrue(content.contains("voice_ask"))
        XCTAssertTrue(content.contains("Never read silence as consent"))
    }
}
