import XCTest
@testable import MiriCore

/// Dictation and clipboard targets are sinks: they accept text and never reply.
/// Miri must not show a "waiting for response" overlay for them, because no
/// completion event is ever coming and the overlay stays on screen.
final class SinkTargetTests: XCTestCase {
    func testSinkAdaptersDoNotClaimTheyReply() {
        XCTAssertFalse(
            FocusedAppAdapter().capabilities.contains(.respondsToMessages),
            "the dictation target never emits agent events"
        )
        XCTAssertFalse(
            ClipboardAdapter().capabilities.contains(.respondsToMessages),
            "the clipboard target never emits agent events"
        )
    }

    func testConversationalAdaptersDeclareThatTheyReply() {
        let codex = CodexAppServerAdapter(
            id: "codex",
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectory: FileManager.default.temporaryDirectory,
            threadID: nil
        )
        XCTAssertTrue(codex.capabilities.contains(.respondsToMessages))

        let hermes = HermesAdapter(
            id: "hermes",
            endpoint: URL(string: "http://127.0.0.1:8080")!,
            sessionID: "s"
        )
        XCTAssertTrue(hermes.capabilities.contains(.respondsToMessages))
    }

    /// A sink's event stream must finish immediately rather than staying open,
    /// which is the other way a target can look like it is still thinking.
    func testSinkEventStreamsFinishImmediately() async {
        for stream in [FocusedAppAdapter().events(), ClipboardAdapter().events()] {
            var received = 0
            for await _ in stream { received += 1 }
            XCTAssertEqual(received, 0)
        }
    }
}
