import XCTest
@testable import MiriCore

final class AgentTests: XCTestCase {
    func testClaudeStreamJSONExtractsFinalResponse() {
        let output = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}
        {"type":"result","result":"finished"}
        """
        XCTAssertEqual(GenericCommandAdapter.response(from: Data(output.utf8), mode: .claudeStreamJSON), "finished")
    }

    func testHermesSSEExtractsAssistantDeltas() {
        let stream = "data: {\"type\":\"assistant.delta\",\"delta\":\"Hello \"}\n\ndata: {\"type\":\"assistant.delta\",\"delta\":\"world\"}\n\n"
        XCTAssertEqual(HermesAdapter.decodeSSEText(Data(stream.utf8)), ["Hello ", "world"])
    }
    func testCapabilitiesAreComposable() {
        let capabilities: AdapterCapabilities = [.streaming, .cancellation]
        XCTAssertTrue(capabilities.contains(.streaming))
    }
    func testPathsUseMiriNamespace() { XCTAssertTrue(MiriPaths.configPath.hasSuffix("/.config/miri/config.toml")); XCTAssertTrue(MiriPaths.socketPath.hasSuffix("miri/control.sock")) }
    func testInteractionHappyPath() {
        var machine = InteractionMachine()
        XCTAssertEqual(machine.handle(.pressToTalk), .listening)
        XCTAssertEqual(machine.handle(.releaseToTalk), .transcribing)
        XCTAssertEqual(machine.handle(.transcriptReady), .delivering)
        XCTAssertEqual(machine.handle(.delivered), .idle)
    }
    func testCancellationAlwaysReturnsIdle() {
        var machine = InteractionMachine(); _ = machine.handle(.pressToTalk)
        XCTAssertEqual(machine.handle(.cancel), .idle)
    }
}
