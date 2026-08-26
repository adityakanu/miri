import XCTest
@testable import MiriCore

final class ControlSocketServerTests: XCTestCase {
    private func temporarySocketPath() -> String {
        // sun_path is 104 bytes; the sandboxed TMPDIR plus a UUID overflows it.
        "/tmp/miri-t-\(UUID().uuidString.prefix(8))/c.sock"
    }

    /// A client that connects and never sends a newline previously blocked the
    /// single accept loop forever, wedging every later request.
    func testSilentClientDoesNotBlockLaterRequests() throws {
        let path = temporarySocketPath()
        let server = ControlSocketServer(path: path) { request in
            .init(accepted: true, message: "echo: \(request.text)")
        }
        try server.start()
        defer { server.stop() }

        let silent = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(silent, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            _ = path.utf8.withContiguousStorageIfAvailable { bytes.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(silent, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        defer { close(silent) }

        // The silent client holds its connection open with no newline. A well
        // behaved request must still be served.
        let response = try ControlClient.send(.init(text: "hello"), path: path)
        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.message, "echo: hello")
    }

    func testStopIsIdempotentAndRemovesSocketFile() throws {
        let path = temporarySocketPath()
        let server = ControlSocketServer(path: path) { _ in .init(accepted: true, message: "ok") }
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
