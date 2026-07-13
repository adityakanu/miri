import AppKit
import Foundation

public enum AdapterError: Error, Equatable, LocalizedError {
    case processFailed(Int32, String), noRunningTurn
    public var errorDescription: String? { switch self { case .processFailed(let status, let message): "Command exited with status \(status): \(message)"; case .noRunningTurn: "No turn is running" } }
}

public enum CommandOutputMode: Sendable { case discard, text, claudeStreamJSON }

public final class ClipboardAdapter: AgentAdapter, @unchecked Sendable {
    public let id: String
    public let capabilities: AdapterCapabilities = []
    private let pasteboard: NSPasteboard
    public init(id: String = "clipboard", pasteboard: NSPasteboard = .general) { self.id = id; self.pasteboard = pasteboard }
    public func connect() async throws {}
    public func disconnect() async {}
    public func status() async -> TargetStatus { .ready }
    public func sendUserMessage(_ text: String) async throws -> DeliveryReceipt {
        await MainActor.run { pasteboard.clearContents(); pasteboard.setString(text, forType: .string) }
        return .init(messageID: UUID(), disposition: .copied)
    }
    public func cancelTurn() async throws { throw AdapterError.noRunningTurn }
    public func events() -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
}

public actor GenericCommandAdapter: AgentAdapter {
    public nonisolated let id: String
    public nonisolated let capabilities: AdapterCapabilities = [.cancellation]
    private let executable: URL
    private let arguments: [String]
    private let workingDirectory: URL?
    private let outputMode: CommandOutputMode
    private var process: Process?
    private var monitorTask: Task<Void, Never>?
    private var cancelling = false
    private var continuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    public init(id: String, executable: URL, arguments: [String] = [], workingDirectory: URL? = nil, outputMode: CommandOutputMode = .discard) { self.id = id; self.executable = executable; self.arguments = arguments; self.workingDirectory = workingDirectory; self.outputMode = outputMode }
    public func connect() async throws {}
    public func disconnect() async { cancelling = true; process?.terminate(); monitorTask?.cancel(); monitorTask = nil; process = nil }
    public func status() async -> TargetStatus { process == nil ? .ready : .busy }
    public func sendUserMessage(_ text: String) async throws -> DeliveryReceipt {
        guard process == nil else { throw AdapterError.processFailed(-1, "command is already running") }
        let process = Process(); let input = Pipe(); let output = Pipe(); let error = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = workingDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        try process.run(); self.process = process; cancelling = false
        let outputTask = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let errorTask = Task.detached { error.fileHandleForReading.readDataToEndOfFile() }
        // The transcript is data on stdin, never shell syntax or an argument.
        input.fileHandleForWriting.write(Data(text.utf8)); input.fileHandleForWriting.closeFile()
        monitorTask = Task.detached { [weak self] in
            process.waitUntilExit()
            let outputData = await outputTask.value
            let errorData = await errorTask.value
            await self?.finished(process: process, status: process.terminationStatus, output: outputData, error: errorData)
        }
        return .init(messageID: UUID())
    }
    public func cancelTurn() async throws { guard let process else { throw AdapterError.noRunningTurn }; cancelling = true; process.terminate() }
    public nonisolated func events() -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in Task { await self.addContinuation(continuation) } }
    }
    private func addContinuation(_ continuation: AsyncStream<AgentEvent>.Continuation) { let id = UUID(); continuations[id] = continuation; continuation.onTermination = { _ in Task { await self.removeContinuation(id) } } }
    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }
    private func emit(_ event: AgentEvent) { continuations.values.forEach { $0.yield(event) } }

    private func finished(process completedProcess: Process, status: Int32, output: Data, error: Data) {
        guard process === completedProcess else { return }
        process = nil; monitorTask = nil
        if cancelling { cancelling = false; emit(.status(.ready)); return }
        guard status == 0 else {
            let message = String(decoding: error, as: UTF8.self)
            emit(.failed(message.isEmpty ? "Command exited with status \(status)" : message)); return
        }
        if let response = Self.response(from: output, mode: outputMode), !response.isEmpty { emit(.responseCompleted(response)) }
        emit(.completed)
    }

    static func response(from data: Data, mode: CommandOutputMode) -> String? {
        switch mode {
        case .discard: return nil
        case .text: return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        case .claudeStreamJSON:
            var assistantParts: [String] = []
            var result: String?
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if value["type"] as? String == "result", let text = value["result"] as? String { result = text }
                guard value["type"] as? String == "assistant",
                      let message = value["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                assistantParts += content.compactMap { item in
                    guard item["type"] as? String == "text" else { return nil }
                    return item["text"] as? String
                }
            }
            return result ?? assistantParts.joined()
        }
    }
}
