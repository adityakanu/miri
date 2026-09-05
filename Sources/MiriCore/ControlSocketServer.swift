import Foundation

public final class ControlSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (VoiceStatusRequest) async -> ControlResponse
    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.miri.control-socket")
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var running = false

    public init(path: String = MiriPaths.socketPath, handler: @escaping Handler) { self.path = path; self.handler = handler }

    private var isRunning: Bool { lock.withLock { running } }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0); _ = path.utf8.withContiguousStorageIfAvailable { bytes.copyBytes(from: $0) } }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { let code = errno; close(fd); unlink(path); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        chmod(path, 0o600)
        lock.withLock { descriptor = fd; running = true }
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            guard running else { return -1 }
            running = false
            let current = descriptor; descriptor = -1
            return current
        }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR); close(fd); unlink(path)
    }

    deinit { stop() }

    private func acceptLoop(_ listener: Int32) {
        while isRunning {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                // The listener was closed by stop(), or accept failed hard.
                // Either way, spinning here would burn a core.
                if errno == EINTR, isRunning { continue }
                return
            }
            // A client that connects and never sends a newline must not block
            // every later request; the loop is the only acceptor.
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // A client that disconnects before the handler writes its
            // response raises SIGPIPE on write(2), whose default action
            // terminates the process. SO_NOSIGPIPE turns that into a normal
            // EPIPE return, which the guarded writes below already handle.
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            guard let request = Self.readRequest(client) else { close(client); continue }
            let handler = handler
            Task {
                let response = await handler(request)
                if let encoded = try? JSONEncoder().encode(response) {
                    let wrote = encoded.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                    if wrote == encoded.count {
                        var newline: UInt8 = 0x0A
                        _ = write(client, &newline, 1)
                    }
                }
                close(client)
            }
        }
    }

    private static func readRequest(_ client: Int32) -> VoiceStatusRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count < 16_384 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return nil }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<newline])
                break
            }
            data.append(contentsOf: buffer[..<count])
        }
        return try? JSONDecoder().decode(VoiceStatusRequest.self, from: data)
    }
}
