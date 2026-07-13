import XCTest
@testable import MiriCore

final class ConfigurationRoutingTests: XCTestCase {
    private let example = """
    version = 1
    default_target = "codex-miri"
    input_mode = "push_to_talk"
    mystery = true
    [ui]
    overlay = "notch"
    show_transcript_preview = false
    [audio]
    speech_volume = 0.85
    [[targets]]
    id = "codex-miri"
    name = "Codex - Miri"
    adapter = "codex"
    working_directory = "~/Developer/miri"
    hotkey = "option+shift+c"
    """

    func testParsesScopeConfigurationAndWarnsUnknownKeys() throws {
        let result = try MiriConfigurationParser.parse(example, file: "test.toml")
        XCTAssertEqual(result.configuration.defaultTarget, "codex-miri")
        XCTAssertEqual(result.configuration.targets.first?.workingDirectory, "~/Developer/miri")
        XCTAssertEqual(result.configuration.sections["audio"]?["speech_volume"], .number(0.85))
        XCTAssertEqual(result.warnings.first?.line, 4)
    }

    func testValidationIncludesFileAndLine() {
        XCTAssertThrowsError(try MiriConfigurationParser.parse("version = 2", file: "bad.toml")) { error in
            let validation = error as? ConfigurationValidationError
            XCTAssertEqual(validation?.diagnostics.first?.file, "bad.toml")
            XCTAssertEqual(validation?.diagnostics.first?.line, 1)
        }
    }

    func testRejectsDuplicateHotkeysWithLineSpecificDiagnostic() {
        let source = """
        version = 1
        [hotkeys]
        active_target = "option+space"
        [[targets]]
        id = "a"
        name = "A"
        adapter = "clipboard"
        hotkey = "OPTION + SPACE"
        """
        XCTAssertThrowsError(try MiriConfigurationParser.parse(source, file: "keys.toml")) { error in
            let diagnostics = (error as? ConfigurationValidationError)?.diagnostics ?? []
            XCTAssertTrue(diagnostics.contains { $0.line == 8 && $0.message.contains("conflicts") })
        }
    }

    func testRoutingPrecedenceAndSnapshotIsolation() throws {
        let dedicated = TargetDefinition(id: "dedicated", name: "Dedicated", adapter: "clipboard", hotkey: "option+d")
        let active = TargetDefinition(id: "active", name: "Active", adapter: "clipboard")
        let fallback = TargetDefinition(id: "default", name: "Default", adapter: "clipboard")
        var router = TargetRouter(registry: .init(targets: [dedicated, active, fallback]), defaultTargetID: fallback.id)
        let snapshot = try router.snapshot(dedicatedHotkey: "OPTION+D", activeTargetID: active.id)
        XCTAssertEqual(snapshot.target.id, dedicated.id); XCTAssertEqual(snapshot.source, .dedicatedHotkey)
        router.registry.remove(id: dedicated.id)
        XCTAssertEqual(snapshot.target.id, dedicated.id)
        XCTAssertEqual(try router.snapshot(activeTargetID: active.id).target.id, active.id)
        XCTAssertEqual(try router.snapshot().target.id, fallback.id)
    }

    func testQueueRequiresConfirmationThenReplaces() async throws {
        let queue = PerTargetVoiceQueue(); let first = QueuedVoiceMessage(targetID: "a", text: "first")
        _ = try await queue.enqueue(first, policy: .reject)
        do { _ = try await queue.enqueue(.init(targetID: "a", text: "second"), policy: .requireConfirmation); XCTFail("expected confirmation") }
        catch { XCTAssertEqual(error as? VoiceQueueError, .confirmationRequired) }
        let replacement = QueuedVoiceMessage(targetID: "a", text: "second")
        let result = try await queue.enqueue(replacement, policy: .requireConfirmation, confirmed: true)
        XCTAssertEqual(result, .replaced(first))
        let current = await queue.message(for: "a")
        XCTAssertEqual(current?.text, "second")
    }

    func testMemoryOutboxSupportsEditAndDiscard() async {
        let outbox = TranscriptOutbox(); let entry = await outbox.add(text: "helo", intendedTargetID: "a", failure: "offline")
        let edited = await outbox.edit(id: entry.id, text: "hello")
        XCTAssertEqual(edited?.text, "hello")
        let discarded = await outbox.discard(id: entry.id)
        let remaining = await outbox.entries()
        XCTAssertNotNil(discarded); XCTAssertTrue(remaining.isEmpty)
    }

    func testGenericCommandReceivesTranscriptOnStdin() async throws {
        let adapter = GenericCommandAdapter(id: "cat", executable: URL(fileURLWithPath: "/usr/bin/grep"), arguments: ["literal transcript"])
        let receipt = try await adapter.sendUserMessage("literal transcript\n")
        XCTAssertEqual(receipt.disposition, .delivered)
    }
}
