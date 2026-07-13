import Foundation

public final class PerformanceRecorder: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "dev.miri.performance-recorder")

    public init(url: URL = MiriPaths.logsDirectory.appending(path: "performance.jsonl")) {
        self.url = url
    }

    public func record(_ metric: String, milliseconds: Double, sessionID: String? = nil) {
        guard milliseconds >= 0, milliseconds.isFinite else { return }
        queue.async { [url] in
            var value: [String: Any] = ["metric": metric, "value": milliseconds, "captured_at": ISO8601DateFormatter().string(from: .now)]
            if let sessionID { value["session_id"] = sessionID }
            guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: data + Data([0x0A])); try handle.close()
            } catch { return }
        }
    }
}
