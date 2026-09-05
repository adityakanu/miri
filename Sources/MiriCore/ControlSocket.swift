import Foundation

public enum VoiceStatusKind: String, Codable, Sendable { case progress, completion, question, blocker, warning }
public struct VoiceStatusRequest: Codable, Sendable {
    public let text: String; public let priority: Int; public let interruptible: Bool
    public let kind: VoiceStatusKind?
    public let targetID: String?
    public let sourceWorkingDirectory: String?
    /// Hold the connection open until the user answers, instead of returning
    /// as soon as the text has been spoken. This is what lets an agent ask a
    /// question mid-turn and resume with its context intact, rather than
    /// ending its turn and being restarted cold by the reply.
    public let awaitReply: Bool?
    /// How long to wait for that answer. Clamped by the server.
    public let replyTimeoutSeconds: Double?

    public init(
        text: String,
        priority: Int = 0,
        interruptible: Bool = true,
        kind: VoiceStatusKind? = nil,
        targetID: String? = nil,
        sourceWorkingDirectory: String? = nil,
        awaitReply: Bool? = nil,
        replyTimeoutSeconds: Double? = nil
    ) {
        self.text = text; self.priority = priority; self.interruptible = interruptible; self.kind = kind
        self.targetID = targetID; self.sourceWorkingDirectory = sourceWorkingDirectory
        self.awaitReply = awaitReply; self.replyTimeoutSeconds = replyTimeoutSeconds
    }
}

/// Bounds on how long an agent may park a connection waiting for the user.
/// Long enough to walk away from the desk, short enough that a forgotten
/// request cannot pin a socket and an agent turn open indefinitely.
public enum VoiceReplyTimeout {
    public static let `default`: Double = 600
    public static let maximum: Double = 1_800
    public static func clamped(_ requested: Double?) -> Double {
        min(max(requested ?? `default`, 5), maximum)
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public let accepted: Bool; public let message: String
    /// What the user said, when the caller asked to wait for it. `nil` means
    /// no answer arrived — the caller must decide for itself rather than
    /// treating silence as consent.
    public let reply: String?
    public init(accepted: Bool, message: String, reply: String? = nil) {
        self.accepted = accepted; self.message = message; self.reply = reply
    }
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
    /// How long to wait for Miri's response before giving up. A parked
    /// `awaitReply` request legitimately takes minutes, but an unbounded read
    /// would hang the agent forever if Miri died mid-answer, so callers pass
    /// their own budget rather than blocking indefinitely.
    public static let defaultReadTimeout: TimeInterval = 30

    @discardableResult public static func send(
        _ request: VoiceStatusRequest,
        path: String = MiriPaths.socketPath,
        readTimeout: TimeInterval = defaultReadTimeout
    ) throws -> ControlResponse {
        _ = SIGPIPEProtection.ignoreOnce
        let data = try JSONEncoder().encode(request) + Data([0x0A])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0); _ = path.utf8.withContiguousStorageIfAvailable { bytes.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        var timeout = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // If Miri closes its end mid-write, write(2) raises SIGPIPE by
        // default and would kill this short-lived helper process outright.
        // SO_NOSIGPIPE turns that into an ordinary EPIPE the guard below
        // already surfaces as EIO.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        try data.withUnsafeBytes { raw in guard write(fd, raw.baseAddress, raw.count) == raw.count else { throw POSIXError(.EIO) } }
        var responseData = Data(); var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count == 1 {
                if byte == 0x0A { break }
                responseData.append(byte)
                if responseData.count >= 16_384 { break }
                continue
            }
            // 0 is a clean close; EAGAIN/EWOULDBLOCK is the read timeout above.
            if count == 0 { break }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ETIMEDOUT)
        }
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: responseData) else { throw POSIXError(.EPROTO) }
        return response
    }
}
