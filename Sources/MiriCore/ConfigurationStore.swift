import Foundation

public enum ConfigurationStoreEvent: Sendable {
    case loaded(ConfigurationLoadResult)
    case diagnostics([ConfigurationDiagnostic])
    case conflict(ConfigurationConflictError)
}

public struct ConfigurationConflictError: Error, Equatable, Sendable, LocalizedError {
    public let path: String
    public let message: String
    public init(path: String, message: String = "The configuration changed on disk after it was loaded") { self.path = path; self.message = message }
    public var errorDescription: String? { "\(path): \(message). Reload it before saving, or explicitly overwrite it." }
}

public actor ConfigurationStore {
    private struct FileSignature: Equatable { let modificationDate: Date; let size: UInt64; let fileNumber: UInt64 }
    public let url: URL
    private var loadedSignature: FileSignature?
    private var lastSeenSignature: FileSignature?
    private var continuations: [UUID: AsyncStream<ConfigurationStoreEvent>.Continuation] = [:]
    private var watchTask: Task<Void, Never>?

    public init(url: URL = URL(fileURLWithPath: MiriPaths.configPath)) { self.url = url }

    public func events() -> AsyncStream<ConfigurationStoreEvent> {
        AsyncStream { continuation in addContinuation(continuation) }
    }

    /// Loads the file, creating a documented minimal configuration if it does not exist.
    @discardableResult public func load(createIfMissing: Bool = true) throws -> ConfigurationLoadResult {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard createIfMissing else { throw CocoaError(.fileNoSuchFile) }
            let clipboard = TargetDefinition(id: "clipboard", name: "Clipboard", adapter: "clipboard")
            let configuration = MiriConfiguration(defaultTarget: clipboard.id, targets: [clipboard])
            // The reference providers keep first launch functional before the user
            // explicitly approves model downloads. installModels() atomically switches
            // this configuration to Moonshine, Pocket TTS, and Silero afterwards.
            try writeData(Self.serialize(configuration))
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        do {
            let result = try MiriConfigurationParser.parse(source, file: url.path)
            let signature = try fileSignature(); loadedSignature = signature; lastSeenSignature = signature
            emit(.loaded(result)); return result
        } catch let error as ConfigurationValidationError {
            lastSeenSignature = try? fileSignature(); emit(.diagnostics(error.diagnostics)); throw error
        }
    }

    /// Atomically saves settings. By default it refuses to overwrite any external edit
    /// made since the last successful load/write.
    public func write(_ configuration: MiriConfiguration, overwriteExternalChanges: Bool = false) throws {
        let current = try? fileSignature()
        if !overwriteExternalChanges, let loadedSignature, current != loadedSignature {
            let conflict = ConfigurationConflictError(path: url.path); emit(.conflict(conflict)); throw conflict
        }
        let data = Self.serialize(configuration)
        // Validate before replacing the user's last known-good file.
        let result = try MiriConfigurationParser.parse(String(decoding: data, as: UTF8.self), file: url.path)
        try writeData(data)
        let signature = try fileSignature(); loadedSignature = signature; lastSeenSignature = signature
        emit(.loaded(result))
    }

    /// Polling is intentionally used here: editors commonly replace TOML files via
    /// rename, which makes a watcher attached to the original inode unreliable.
    public func startWatching(interval: Duration = .milliseconds(500)) {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await self?.reloadIfChanged()
            }
        }
    }
    public func stopWatching() { watchTask?.cancel(); watchTask = nil }

    public func reloadIfChanged() {
        guard let signature = try? fileSignature(), signature != lastSeenSignature else { return }
        lastSeenSignature = signature
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let result = try MiriConfigurationParser.parse(source, file: url.path)
            loadedSignature = signature; emit(.loaded(result))
        } catch let error as ConfigurationValidationError { emit(.diagnostics(error.diagnostics)) }
        catch {
            emit(.diagnostics([.init(file: url.path, line: 1, severity: .error, message: error.localizedDescription)]))
        }
    }

    public static func serialize(_ configuration: MiriConfiguration) -> Data {
        var lines = ["version = \(configuration.version)"]
        if let target = configuration.defaultTarget { lines.append("default_target = \(quoted(target))") }
        lines.append("input_mode = \(quoted(configuration.inputMode))")
        for section in configuration.sections.keys.sorted() {
            lines.append(""); lines.append("[\(section)]")
            for key in configuration.sections[section]!.keys.sorted() { lines.append("\(key) = \(render(configuration.sections[section]![key]!))") }
        }
        for target in configuration.targets {
            lines.append(""); lines.append("[[targets]]"); lines.append("id = \(quoted(target.id))"); lines.append("name = \(quoted(target.name))")
            if let agent = target.agent { lines.append("agent = \(quoted(agent))") }
            lines.append("adapter = \(quoted(target.adapter))")
            if let value = target.workingDirectory { lines.append("working_directory = \(quoted(value))") }
            if let value = target.project { lines.append("project = \(quoted(value))") }
            if let value = target.session { lines.append("session = \(quoted(value))") }
            if let value = target.endpoint { lines.append("endpoint = \(quoted(value))") }
            if let value = target.hotkey { lines.append("hotkey = \(quoted(value))") }
            if target.queueReplacement != "reject" { lines.append("queue_replacement = \(quoted(target.queueReplacement))") }
            if !target.enabled { lines.append("enabled = false") }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func writeData(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
    }
    private func fileSignature() throws -> FileSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return .init(modificationDate: attributes[.modificationDate] as? Date ?? .distantPast, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
    private func addContinuation(_ continuation: AsyncStream<ConfigurationStoreEvent>.Continuation) {
        let id = UUID(); continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeContinuation(id) } }
    }
    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }
    private func emit(_ event: ConfigurationStoreEvent) { continuations.values.forEach { $0.yield(event) } }
    private static func quoted(_ string: String) -> String { "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\"" }
    private static func render(_ value: ConfigurationValue) -> String { switch value { case .string(let value): quoted(value); case .integer(let value): String(value); case .number(let value): String(value); case .boolean(let value): String(value) } }
}
