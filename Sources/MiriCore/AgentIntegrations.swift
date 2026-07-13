import Foundation

/// Managed CLI fallbacks are addressable and safe: transcript bytes are always stdin,
/// never interpolated into a shell command. Native/app-server transports can replace
/// these wrappers without changing routing or UI contracts.
public actor CodexAdapter: AgentAdapter {
    public nonisolated let id: String
    public nonisolated let capabilities: AdapterCapabilities = [.cancellation]
    private let command: GenericCommandAdapter
    public init(id: String, executable: URL, workingDirectory: URL, sessionID: String? = nil) {
        self.id = id
        var arguments = ["exec"]
        if let sessionID { arguments += ["resume", sessionID, "-"] } else { arguments += ["-"] }
        command = GenericCommandAdapter(id: id + ".command", executable: executable, arguments: arguments, workingDirectory: workingDirectory)
    }
    public func connect() async throws { try await command.connect() }
    public func disconnect() async { await command.disconnect() }
    public func status() async -> TargetStatus { await command.status() }
    public func sendUserMessage(_ text: String) async throws -> DeliveryReceipt { try await command.sendUserMessage(text) }
    public func cancelTurn() async throws { try await command.cancelTurn() }
    public nonisolated func events() -> AsyncStream<AgentEvent> { command.events() }
}

public actor ClaudeCodeAdapter: AgentAdapter {
    public nonisolated let id: String
    public nonisolated let capabilities: AdapterCapabilities = [.cancellation]
    private let command: GenericCommandAdapter
    public init(id: String, executable: URL, workingDirectory: URL, sessionID: String? = nil) {
        self.id = id
        var arguments = ["--print", "--output-format", "stream-json", "--input-format", "text"]
        if let sessionID { arguments += ["--resume", sessionID] }
        command = GenericCommandAdapter(id: id + ".command", executable: executable, arguments: arguments, workingDirectory: workingDirectory, outputMode: .claudeStreamJSON)
    }
    public func connect() async throws { try await command.connect() }
    public func disconnect() async { await command.disconnect() }
    public func status() async -> TargetStatus { await command.status() }
    public func sendUserMessage(_ text: String) async throws -> DeliveryReceipt { try await command.sendUserMessage(text) }
    public func cancelTurn() async throws { try await command.cancelTurn() }
    public nonisolated func events() -> AsyncStream<AgentEvent> { command.events() }
}

public actor HermesAdapter: AgentAdapter {
    public nonisolated let id: String
    public nonisolated let capabilities: AdapterCapabilities = [.cancellation, .streaming]
    private let endpoint: URL
    private let sessionID: String
    private let apiKey: String?
    private var connected = false
    private var turnTask: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    public init(id: String, endpoint: URL, sessionID: String, apiKey: String? = ProcessInfo.processInfo.environment["HERMES_API_SERVER_KEY"]) {
        self.id = id; self.endpoint = endpoint; self.sessionID = sessionID; self.apiKey = apiKey
    }
    public func connect() async throws {
        guard !connected else { return }
        guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""), !sessionID.isEmpty else {
            throw URLError(.badURL)
        }
        connected = true
        emit(.status(.ready))
    }
    public func disconnect() async { turnTask?.cancel(); turnTask = nil; connected = false; emit(.status(.disconnected)) }
    public func status() async -> TargetStatus { !connected ? .disconnected : (turnTask == nil ? .ready : .busy) }
    public func sendUserMessage(_ text: String) async throws -> DeliveryReceipt {
        guard connected else { throw URLError(.notConnectedToInternet) }
        guard turnTask == nil else { throw AdapterError.processFailed(-1, "Hermes turn is already running") }
        let id = UUID()
        let url = endpoint
            .appending(path: "api/sessions")
            .appending(path: sessionID)
            .appending(path: "chat/stream")
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": text])
        emit(.status(.busy))
        turnTask = Task { [weak self] in await self?.perform(request) }
        return .init(messageID: id)
    }

    private func perform(_ request: URLRequest) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            turnTask = nil
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw AdapterError.processFailed(Int32((response as? HTTPURLResponse)?.statusCode ?? -1), String(decoding: data, as: UTF8.self))
            }
            let parts = Self.decodeSSEText(data)
            for part in parts { emit(.responseDelta(part)) }
            if !parts.isEmpty { emit(.responseCompleted(parts.joined())) }
            emit(.completed); emit(.status(.ready))
        } catch {
            guard !Task.isCancelled else { turnTask = nil; emit(.status(.ready)); return }
            turnTask = nil; emit(.failed(error.localizedDescription)); emit(.status(.ready))
        }
    }
    public func cancelTurn() async throws {
        guard let turnTask else { throw AdapterError.noRunningTurn }
        turnTask.cancel(); self.turnTask = nil; emit(.status(.ready))
    }
    public nonisolated func events() -> AsyncStream<AgentEvent> { AsyncStream { continuation in Task { await self.add(continuation) } } }
    private func add(_ continuation: AsyncStream<AgentEvent>.Continuation) { let id = UUID(); eventContinuations[id] = continuation; continuation.onTermination = { _ in Task { await self.remove(id) } } }
    private func remove(_ id: UUID) { eventContinuations.removeValue(forKey: id) }
    private func emit(_ event: AgentEvent) { eventContinuations.values.forEach { $0.yield(event) } }

    static func decodeSSEText(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard body != "[DONE]", let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
                for key in ["delta", "text", "content", "message"] {
                    if let text = json[key] as? String, !text.isEmpty { return text }
                    if let nested = json[key] as? [String: Any] {
                        for nestedKey in ["text", "content", "delta"] {
                            if let text = nested[nestedKey] as? String, !text.isEmpty { return text }
                        }
                    }
                }
                return nil
            }
    }
}
