import Foundation

public final class MiriLogger: @unchecked Sendable {
    public enum Level: String, Sendable { case info = "INFO", warning = "WARN", error = "ERROR" }

    public let fileURL: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    public init(fileURL: URL = MiriPaths.logFile) {
        self.fileURL = fileURL
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            handle = try FileHandle(forWritingTo: fileURL)
            try handle?.seekToEnd()
        } catch {
            handle = nil
        }
    }

    deinit { try? handle?.close() }

    public func log(_ message: String) { log(.info, message) }

    public func log(_ level: Level, _ message: String) {
        lock.withLock {
            guard let handle else { return }
            let safeMessage = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try? handle.write(contentsOf: Data("\(timestamp) [\(level.rawValue)] \(safeMessage)\n".utf8))
            try? handle.synchronize()
        }
    }
}
