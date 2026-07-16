import Foundation

public enum CodexAppServerError: Error, LocalizedError {
    case disconnected, unavailable(TargetStatus), invalidResponse, timedOut(String), rpc(Int, String), processExited(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .disconnected: "Codex app server is disconnected"
        case .unavailable(let status): "Codex target is \(status.rawValue)"
        case .invalidResponse: "Codex app server returned an invalid response"
        case .timedOut(let method): "Codex app server timed out during \(method)"
        case .rpc(let code, let message): "Codex app server error \(code): \(message)"
        case .processExited(let code, let detail): "Codex app server exited with status \(code): \(detail)"
        }
    }
}

public struct CodexThreadSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let preview: String
    public let workingDirectory: String
    public let createdAt: Date
    public let updatedAt: Date
    public let status: String

    public init(id: String, name: String?, preview: String, workingDirectory: String, createdAt: Date, updatedAt: Date, status: String) {
        self.id = id; self.name = name; self.preview = preview; self.workingDirectory = workingDirectory
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.status = status
    }

    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        let firstLine = preview.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine.isEmpty ? "Codex thread \(id.prefix(8))" : String(firstLine.prefix(72))
    }
}

/// Addressable Codex integration backed by the installed app-server JSON-RPC
/// schema. The managed CLI adapter remains available as a compatibility fallback.
public actor CodexAppServerAdapter: AgentAdapter {
    public nonisolated let id: String
    public nonisolated let capabilities: AdapterCapabilities = [.cancellation, .streaming, .interactiveRequests]
    private enum RPCID: Sendable { case integer(Int), string(String) }
    private struct PendingInteraction: Sendable { let rpcID: RPCID; let method: String }
    private let executable: URL
    private let workingDirectory: URL
    private let configuredThreadID: String?
    private let opensThread: Bool
    private var threadID: String?
    private var activeTurnID: String?
    private var process: Process?
    private var input: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var requestTimeouts: [Int: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var targetStatus: TargetStatus = .disconnected
    private var stderr = ""
    private var outputBuffer = Data()
    private var completionEmitted = false
    private var pendingInteractions: [String: PendingInteraction] = [:]
    private var intentionalShutdown = false
    private let traceEnabled = ProcessInfo.processInfo.environment["MIRI_CODEX_TRACE"] == "1"

    public init(id: String, executable: URL, workingDirectory: URL, threadID: String? = nil, opensThread: Bool = true) {
        self.id = id; self.executable = executable; self.workingDirectory = workingDirectory
        configuredThreadID = threadID; self.threadID = threadID; self.opensThread = opensThread
    }

    public func connect() async throws {
        guard process == nil else { return }; targetStatus = .connecting; emit(.status(.connecting))
        do {
            intentionalShutdown = false
            let process = Process(); let stdin = Pipe(); let stdout = Pipe(); let error = Pipe()
            process.executableURL = executable; process.arguments = ["app-server", "--stdio"]
            var environment = ProcessInfo.processInfo.environment
            environment["MIRI_TARGET_ID"] = id
            if let configuredThreadID { environment["MIRI_THREAD_ID"] = configuredThreadID }
            process.environment = environment
            process.currentDirectoryURL = workingDirectory; process.standardInput = stdin
            process.standardOutput = stdout; process.standardError = error
            process.terminationHandler = { [weak self] process in Task { await self?.terminated(process.terminationStatus) } }
            try process.run(); self.process = process; input = stdin.fileHandleForWriting
            trace("process started")
            outputHandle = stdout.fileHandleForReading; errorHandle = error.fileHandleForReading
            read(stdout.fileHandleForReading, isError: false); read(error.fileHandleForReading, isError: true)
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "miri", "title": "Miri", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true],
            ])
            trace("initialized")
            try notify("initialized", params: [:])
            if !opensThread {
                threadID = nil
            } else if let configuredThreadID {
                let result = try await request("thread/resume", params: ["threadId": configuredThreadID, "cwd": workingDirectory.path])
                threadID = try extractThreadID(result)
            } else {
                let result = try await request("thread/start", params: ["cwd": workingDirectory.path, "approvalPolicy": "on-request"])
                threadID = try extractThreadID(result)
            }
            trace("thread ready \(threadID ?? "none")")
            targetStatus = .ready; emit(.status(.ready))
        } catch {
            input?.closeFile(); process?.terminate(); input = nil; process = nil
            targetStatus = .failed; emit(.failed(error.localizedDescription)); emit(.status(.failed))
            throw error
        }
    }

    public func disconnect() async {
        intentionalShutdown = true
        declinePendingInteractions()
        outputHandle?.readabilityHandler = nil; errorHandle?.readabilityHandler = nil
        input?.closeFile(); process?.terminate(); input = nil; outputHandle = nil; errorHandle = nil; process = nil
        targetStatus = .disconnected; emit(.status(.disconnected))
    }
    public func status() async -> TargetStatus { targetStatus }

    public func listThreads(limit: Int = 30) async throws -> [CodexThreadSummary] {
        guard process != nil else { throw CodexAppServerError.disconnected }
        let result = try await request("thread/list", params: [
            "limit": max(1, min(limit, 100)),
            "sortKey": "recency_at",
            "sortDirection": "desc",
        ])
        guard let object = try json(result), let threads = object["data"] as? [[String: Any]] else { throw CodexAppServerError.invalidResponse }
        return threads.compactMap { thread in
            guard let id = thread["id"] as? String,
                  let preview = thread["preview"] as? String,
                  let cwd = thread["cwd"] as? String,
                  let created = thread["createdAt"] as? NSNumber,
                  let updated = thread["updatedAt"] as? NSNumber else { return nil }
            let status = (thread["status"] as? [String: Any])?["type"] as? String ?? "unknown"
            return CodexThreadSummary(
                id: id,
                name: thread["name"] as? String,
                preview: preview,
                workingDirectory: cwd,
                createdAt: Date(timeIntervalSince1970: created.doubleValue),
                updatedAt: Date(timeIntervalSince1970: updated.doubleValue),
                status: status
            )
        }
    }

    public func sendUserMessage(_ text: String) async throws -> DeliveryReceipt {
        guard let threadID else { throw CodexAppServerError.disconnected }
        guard targetStatus == .ready else { throw CodexAppServerError.unavailable(targetStatus) }
        let messageID = UUID()
        let result = try await request("turn/start", params: [
            "threadId": threadID,
            "input": [["type": "text", "text": text]],
            "clientUserMessageId": messageID.uuidString,
        ])
        trace("turn/start accepted")
        guard let object = try json(result), let turn = object["turn"] as? [String: Any], let turnID = turn["id"] as? String else { throw CodexAppServerError.invalidResponse }
        activeTurnID = turnID; completionEmitted = false; targetStatus = .busy; emit(.status(.busy))
        return .init(messageID: messageID)
    }

    public func cancelTurn() async throws {
        guard let threadID, let activeTurnID else { throw AdapterError.noRunningTurn }
        _ = try await request("turn/interrupt", params: ["threadId": threadID, "turnId": activeTurnID])
    }
    public func respond(to requestID: String, with response: AgentInteractionResponse) async throws {
        guard let pending = pendingInteractions.removeValue(forKey: requestID) else { throw AdapterError.unknownInteraction }
        let decision: String
        switch response {
        case .approve: decision = "accept"
        case .deny: decision = "decline"
        case .text: throw AdapterError.unsupportedInteraction
        }
        respond(id: pending.rpcID, result: ["decision": decision])
    }
    public nonisolated func events() -> AsyncStream<AgentEvent> { AsyncStream { continuation in Task { await self.add(continuation) } } }

    private func request(_ method: String, params: [String: Any]) async throws -> Data {
        guard let input else { throw CodexAppServerError.disconnected }
        let id = nextID; nextID += 1
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data([0x0A])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            requestTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await self?.timeoutRequest(id, method: method)
            }
            do { try input.write(contentsOf: data) }
            catch {
                pending.removeValue(forKey: id); requestTimeouts.removeValue(forKey: id)?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }
    private func notify(_ method: String, params: [String: Any]) throws {
        guard let input else { throw CodexAppServerError.disconnected }
        try input.write(contentsOf: JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params]) + Data([0x0A]))
    }
    private func read(_ handle: FileHandle, isError: Bool) {
        handle.readabilityHandler = { [weak self] readable in
            let data = readable.availableData
            if data.isEmpty { readable.readabilityHandler = nil; return }
            Task {
                if isError { await self?.captureError(data) }
                else { await self?.receiveOutput(data) }
            }
        }
    }
    private func receiveOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            if !line.isEmpty { receive(line) }
        }
    }
    private func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            requestTimeouts.removeValue(forKey: id)?.cancel()
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: CodexAppServerError.rpc(error["code"] as? Int ?? -1, error["message"] as? String ?? "Unknown error"))
            } else if let result = object["result"] { continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)) }
            else { continuation.resume(throwing: CodexAppServerError.invalidResponse) }
            return
        }
        guard let method = object["method"] as? String else { return }
        trace("event \(method)")
        let params = object["params"] as? [String: Any] ?? [:]
        if let requestID = rpcID(from: object["id"]) {
            let approvalMethods = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "applyPatchApproval", "execCommandApproval"]
            if approvalMethods.contains(method) {
                let interactionID = UUID().uuidString
                pendingInteractions[interactionID] = .init(rpcID: requestID, method: method)
                let action: String
                if method.contains("commandExecution") || method == "execCommandApproval" { action = "run a command" }
                else if method.contains("permissions") { action = "use additional permissions" }
                else { action = "change files" }
                let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                emit(.interactionRequested(.init(
                    id: interactionID,
                    kind: .approval,
                    title: "Codex requests permission to \(action)",
                    detail: reason.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
                )))
            } else {
                respondError(id: requestID, code: -32601, message: "Miri cannot answer this Codex request yet")
            }
            return
        }
        switch method {
        case "turn/started": targetStatus = .busy; emit(.status(.busy))
        case "turn/completed": completeTurnIfNeeded()
        case "item/agentMessage/delta": if let delta = params["delta"] as? String { emit(.responseDelta(delta)) }
        case "item/completed":
            if let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               ((item["phase"] as? String) == "final_answer" || item["phase"] == nil),
               let text = item["text"] as? String {
                emit(.responseCompleted(text))
                completeTurnIfNeeded()
            }
        case "error": emit(.failed(String(describing: params)))
        default: break
        }
    }
    private func rpcID(from value: Any?) -> RPCID? {
        if let value = value as? Int { return .integer(value) }
        if let value = value as? String { return .string(value) }
        return nil
    }
    private func jsonValue(for id: RPCID) -> Any { switch id { case .integer(let value): value; case .string(let value): value } }
    private func respond(id: RPCID, result: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": jsonValue(for: id), "result": result]) else { return }
        try? input.write(contentsOf: data + Data([0x0A]))
    }
    private func respondError(id: RPCID, code: Int, message: String) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": jsonValue(for: id), "error": ["code": code, "message": message]]) else { return }
        try? input.write(contentsOf: data + Data([0x0A]))
    }
    private func extractThreadID(_ data: Data) throws -> String {
        guard let object = try json(data), let thread = object["thread"] as? [String: Any], let id = thread["id"] as? String else { throw CodexAppServerError.invalidResponse }
        return id
    }
    private func json(_ data: Data) throws -> [String: Any]? { try JSONSerialization.jsonObject(with: data) as? [String: Any] }
    private func captureError(_ data: Data) { stderr = String((stderr + String(decoding: data, as: UTF8.self)).suffix(2_000)) }
    private func timeoutRequest(_ id: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        requestTimeouts.removeValue(forKey: id)?.cancel()
        continuation.resume(throwing: CodexAppServerError.timedOut(method))
    }
    private func terminated(_ code: Int32) {
        if intentionalShutdown {
            intentionalShutdown = false; process = nil; input = nil; outputHandle = nil; errorHandle = nil; targetStatus = .disconnected
            return
        }
        let error = CodexAppServerError.processExited(code, stderr)
        outputHandle?.readabilityHandler = nil; errorHandle?.readabilityHandler = nil
        process = nil; input = nil; outputHandle = nil; errorHandle = nil; targetStatus = .failed
        for task in requestTimeouts.values { task.cancel() }; requestTimeouts.removeAll()
        pendingInteractions.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }; pending.removeAll(); emit(.failed(error.localizedDescription)); emit(.status(.failed))
    }
    private func add(_ continuation: AsyncStream<AgentEvent>.Continuation) { let id = UUID(); continuations[id] = continuation; continuation.onTermination = { _ in Task { await self.remove(id) } } }
    private func remove(_ id: UUID) { continuations.removeValue(forKey: id) }
    private func emit(_ event: AgentEvent) { continuations.values.forEach { $0.yield(event) } }
    private func completeTurnIfNeeded() {
        activeTurnID = nil; targetStatus = .ready
        if !completionEmitted { completionEmitted = true; emit(.completed) }
        emit(.status(.ready))
    }
    private func trace(_ message: String) {
        guard traceEnabled else { return }
        FileHandle.standardError.write(Data("miri codex: \(message)\n".utf8))
    }
    private func declinePendingInteractions() {
        for pending in pendingInteractions.values { respond(id: pending.rpcID, result: ["decision": "decline"]) }
        pendingInteractions.removeAll()
    }
}
