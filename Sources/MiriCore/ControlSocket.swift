import Foundation

public enum VoiceStatusKind: String, Codable, Sendable { case progress, completion, question, blocker, warning }
public struct VoiceStatusRequest: Codable, Sendable {
    public let text: String; public let priority: Int; public let interruptible: Bool
    public let kind: VoiceStatusKind?
    public let targetID: String?
    public let sourceWorkingDirectory: String?
    public init(text: String, priority: Int = 0, interruptible: Bool = true, kind: VoiceStatusKind? = nil, targetID: String? = nil, sourceWorkingDirectory: String? = nil) {
        self.text = text; self.priority = priority; self.interruptible = interruptible; self.kind = kind
        self.targetID = targetID; self.sourceWorkingDirectory = sourceWorkingDirectory
    }
}
public struct ControlResponse: Codable, Equatable, Sendable {
    public let accepted: Bool; public let message: String
    public init(accepted: Bool, message: String) { self.accepted = accepted; self.message = message }
}

public enum MiriPaths {
    public static var socketPath: String { (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/") + "miri/control.sock" }
    public static var configPath: String { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/miri/config.toml").path }
    public static var logsDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Miri", directoryHint: .isDirectory) }
    public static var logFile: URL { logsDirectory.appending(path: "miri.log") }
    public static var applicationSupport: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Miri", directoryHint: .isDirectory) }
    public static var modelsDirectory: URL { applicationSupport.appending(path: "Models", directoryHint: .isDirectory) }
    public static var cachesDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Miri", directoryHint: .isDirectory) }
}

/// Resolves an agent CLI. Config override first, then the user's login-shell
/// PATH, then the common install prefixes. Version managers (mise, asdf,
/// volta, fnm) only ever appear on the login PATH.
public enum ExecutableResolver {
    public static func find(_ name: String, override: String? = nil) -> URL? {
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        if let found = loginShellPath(name) { return found }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func loginShellPath(_ name: String) -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l runs the login profile so version-manager shims are on PATH.
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

public enum ControlClient {
    @discardableResult public static func send(_ request: VoiceStatusRequest, path: String = MiriPaths.socketPath) throws -> ControlResponse {
        let data = try JSONEncoder().encode(request) + Data([0x0A])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0); _ = path.utf8.withContiguousStorageIfAvailable { bytes.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        try data.withUnsafeBytes { raw in guard write(fd, raw.baseAddress, raw.count) == raw.count else { throw POSIXError(.EIO) } }
        var responseData = Data(); var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != 0x0A, responseData.count < 16_384 { responseData.append(byte) }
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: responseData) else { throw POSIXError(.EPROTO) }
        return response
    }
}
