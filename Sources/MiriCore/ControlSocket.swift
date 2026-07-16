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

public enum ControlClient {
    @discardableResult public static func send(_ request: VoiceStatusRequest) throws -> ControlResponse {
        let data = try JSONEncoder().encode(request) + Data([0x0A])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard MiriPaths.socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0); _ = MiriPaths.socketPath.utf8.withContiguousStorageIfAvailable { bytes.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        try data.withUnsafeBytes { raw in guard write(fd, raw.baseAddress, raw.count) == raw.count else { throw POSIXError(.EIO) } }
        var responseData = Data(); var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != 0x0A, responseData.count < 16_384 { responseData.append(byte) }
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: responseData) else { throw POSIXError(.EPROTO) }
        return response
    }
}
