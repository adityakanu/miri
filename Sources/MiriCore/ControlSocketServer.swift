import Foundation

public final class ControlSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (VoiceStatusRequest) async -> ControlResponse
    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.miri.control-socket")
    private var descriptor: Int32 = -1
    private var running = false

    public init(path: String = MiriPaths.socketPath, handler: @escaping Handler) { self.path = path; self.handler = handler }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0); guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0); _ = path.utf8.withContiguousStorageIfAvailable { bytes.copyBytes(from: $0) } }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(descriptor, 8) == 0 else { let code = errno; stop(); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        chmod(path, 0o600); running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() { running = false; if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR); close(descriptor); descriptor = -1 }; unlink(path) }
    deinit { stop() }

    private func acceptLoop() {
        while running {
            let client = accept(descriptor, nil, nil); guard client >= 0 else { continue }
            var data = Data(); var byte: UInt8 = 0
            while read(client, &byte, 1) == 1, byte != 0x0A, data.count < 16_384 { data.append(byte) }
            if let request = try? JSONDecoder().decode(VoiceStatusRequest.self, from: data) {
                let handler = handler
                Task {
                    let response = await handler(request)
                    if let encoded = try? JSONEncoder().encode(response) { _ = encoded.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }; var newline: UInt8 = 0x0A; _ = write(client, &newline, 1) }
                    close(client)
                }
            } else { close(client) }
        }
    }
}
