import XCTest
@testable import MiriCore

final class AgentTests: XCTestCase {
    func testCodexMCPInstallerUsesCLIWithoutEditingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "arguments.txt")
        let codex = directory.appending(path: "codex")
        let helper = directory.appending(path: "miri-mcp")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(log.path)\n".utf8).write(to: codex)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        try CodexMCPInstaller.install(codex: codex, helper: helper)

        let invocations = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(invocations, [
            "mcp get miri --json",
            "mcp remove miri",
            "mcp add miri -- \(helper.path)",
        ])
    }

    func testCodexApprovalRequestCanBeAcceptedThroughNeutralContract() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decisionFile = directory.appending(path: "decision.txt")
        let script = directory.appending(path: "fake-codex.py")
        let source = """
        #!/usr/bin/python3
        import json, sys
        decision_file = \(decisionFile.path.debugDescription)
        def send(value):
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            value = json.loads(line)
            method = value.get("method")
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":value["id"], "result":{}})
            elif method == "thread/start":
                send({"jsonrpc":"2.0", "id":value["id"], "result":{"thread":{"id":"thread-1"}}})
            elif method == "turn/start":
                send({"jsonrpc":"2.0", "id":value["id"], "result":{"turn":{"id":"turn-1"}}})
                send({"jsonrpc":"2.0", "id":"approval-rpc", "method":"item/commandExecution/requestApproval", "params":{"reason":"Network test"}})
            elif value.get("id") == "approval-rpc" and "result" in value:
                open(decision_file, "w").write(value["result"]["decision"])
                send({"jsonrpc":"2.0", "method":"turn/completed", "params":{}})
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let adapter = CodexAppServerAdapter(id: "codex-test", executable: script, workingDirectory: directory)
        let interactionTask = Task<AgentInteractionRequest?, Never> {
            for await event in adapter.events() {
                if case .interactionRequested(let request) = event { return request }
            }
            return nil
        }
        try await adapter.connect()
        _ = try await adapter.sendUserMessage("test")
        let request = await interactionTask.value
        XCTAssertEqual(request?.kind, .approval)
        XCTAssertEqual(request?.detail, "Network test")
        try await adapter.respond(to: try XCTUnwrap(request?.id), with: .approve)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: decisionFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try String(contentsOf: decisionFile, encoding: .utf8), "accept")
        await adapter.disconnect()
    }

    func testVoiceApprovalRequiresExplicitRequestPhrase() {
        XCTAssertEqual(VoiceApprovalParser.parse("Miri, approve request."), .approve)
        XCTAssertEqual(VoiceApprovalParser.parse("deny request"), .deny)
        XCTAssertNil(VoiceApprovalParser.parse("yes"))
        XCTAssertNil(VoiceApprovalParser.parse("approve"))
        XCTAssertNil(VoiceApprovalParser.parse("please approve the request"))
    }

    func testInteractionRequestAndStatusMetadataRoundTrip() throws {
        let interaction = AgentInteractionRequest(id: "approval-1", kind: .approval, title: "Permission needed", detail: "Network access")
        XCTAssertEqual(try JSONDecoder().decode(AgentInteractionRequest.self, from: JSONEncoder().encode(interaction)), interaction)
        let status = VoiceStatusRequest(text: "Which option?", priority: 1, kind: .question, targetID: "codex-main", sourceWorkingDirectory: "/tmp/project")
        let decoded = try JSONDecoder().decode(VoiceStatusRequest.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.kind, .question)
        XCTAssertEqual(decoded.targetID, "codex-main")
        XCTAssertEqual(decoded.sourceWorkingDirectory, "/tmp/project")
    }
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
