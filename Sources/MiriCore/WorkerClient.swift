import Foundation
import MiriIPC

public enum WorkerClientError: Error, LocalizedError {
    case notRunning, closed, invalidJSON
    public var errorDescription: String? { switch self { case .notRunning: "Speech worker is not running"; case .closed: "Speech worker connection closed"; case .invalidJSON: "Could not encode worker request" } }
}

/// Stdio client for the replaceable speech process. Requests and events use the
/// exact same frames as a future Unix-socket worker transport.
public actor WorkerClient {
    public private(set) var state: WorkerSupervisor.State = .stopped
    public private(set) var diagnostic: String?
    private var process: Process?
    private var input: FileHandle?
    private var decoder = FrameStreamDecoder()
    private var continuations: [UUID: AsyncStream<IPCFrame>.Continuation] = [:]
    private var launch: (URL, [String], URL?, [String: String]?)?
    private var restartAttempt = 0
    private var intentionallyStopped = false

    public init() {}
    public nonisolated func events() -> AsyncStream<IPCFrame> {
        AsyncStream { continuation in Task { await self.add(continuation) } }
    }

    public func start(executable: URL, arguments: [String] = [], workingDirectory: URL? = nil, environment: [String: String]? = nil) throws {
        guard process == nil else { return }; state = .starting; intentionallyStopped = false
        let initialLaunch = launch == nil
        launch = (executable, arguments, workingDirectory, environment)
        let process = Process(); let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = workingDirectory
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, configured in configured } }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        process.terminationHandler = { [weak self] process in Task { await self?.terminated(process.terminationStatus) } }
        do { try process.run() } catch { state = .failed(error.localizedDescription); throw error }
        self.process = process; input = stdin.fileHandleForWriting; state = .running; diagnostic = nil
        if initialLaunch { restartAttempt = 0 }
        let output = stdout.fileHandleForReading
        Task.detached { [weak self] in
            while true {
                let data = output.availableData
                guard !data.isEmpty else { break }
                await self?.accept(data)
            }
        }
        let errorOutput = stderr.fileHandleForReading
        Task.detached { [weak self] in
            while true {
                let data = errorOutput.availableData
                guard !data.isEmpty else { break }
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty { await self?.recordDiagnostic(message) }
            }
        }
    }

    @discardableResult public func send(messageType: MessageType, requestID: String = UUID().uuidString, sessionID: String? = nil, payload: Data = Data("{}".utf8), kind: PayloadKind = .json) throws -> String {
        guard state == .running, let input else { throw WorkerClientError.notRunning }
        let frame = IPCFrame(header: .init(requestID: requestID, sessionID: sessionID, kind: kind, messageType: messageType.rawValue), payload: payload)
        try input.write(contentsOf: FrameCodec.encode(frame)); return requestID
    }

    @discardableResult public func sendJSON<T: Encodable & Sendable>(_ messageType: MessageType, body: T, requestID: String = UUID().uuidString, sessionID: String? = nil) throws -> String {
        try send(messageType: messageType, requestID: requestID, sessionID: sessionID, payload: JSONEncoder().encode(body))
    }

    public func stop() {
        intentionallyStopped = true; launch = nil
        input?.closeFile(); process?.terminate(); input = nil; process = nil; state = .stopped
        continuations.values.forEach { $0.finish() }; continuations.removeAll()
    }

    private func accept(_ data: Data) {
        do { for frame in try decoder.append(data) { continuations.values.forEach { $0.yield(frame) } } }
        catch { failed(error) }
    }
    private func failed(_ error: Error) { state = .failed(error.localizedDescription) }
    private func recordDiagnostic(_ message: String) { diagnostic = String(message.suffix(2_000)) }
    private func terminated(_ status: Int32) {
        input = nil; process = nil
        guard !intentionallyStopped, let launch else { state = .stopped; return }
        let detail = diagnostic.map { ": \($0)" } ?? ""
        state = .failed("Worker exited with status \(status)\(detail)")
        guard restartAttempt < 3 else { continuations.values.forEach { $0.finish() }; return }
        restartAttempt += 1; let delay = restartAttempt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            do {
                try await self.start(executable: launch.0, arguments: launch.1, workingDirectory: launch.2, environment: launch.3)
                _ = try await self.sendJSON(.hello, body: ["peer": "Miri.app.recovery"])
                _ = try await self.sendJSON(.health, body: EmptyBody())
            }
            catch { await self.failed(error) }
        }
    }
    private func add(_ continuation: AsyncStream<IPCFrame>.Continuation) { let id = UUID(); continuations[id] = continuation; continuation.onTermination = { _ in Task { await self.remove(id) } } }
    private func remove(_ id: UUID) { continuations.removeValue(forKey: id) }
}
