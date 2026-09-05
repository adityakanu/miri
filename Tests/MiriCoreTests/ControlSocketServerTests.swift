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

    /// `voice_ask` parks the agent's connection until the user speaks. The
    /// client must stay on the socket across that delay and return what the
    /// user actually said.
    func testAwaitingClientReceivesADelayedReply() throws {
        let path = temporarySocketPath()
        let server = ControlSocketServer(path: path) { request in
            guard request.awaitReply == true else { return .init(accepted: true, message: "spoke") }
            try? await Task.sleep(for: .milliseconds(600))
            return .init(accepted: true, message: "User replied", reply: "use postgres")
        }
        try server.start()
        defer { server.stop() }

        let response = try ControlClient.send(
            .init(text: "Which database?", kind: .question, awaitReply: true),
            path: path,
            readTimeout: 10
        )
        XCTAssertEqual(response.reply, "use postgres")
    }

    /// A parked request must never hang the agent forever. If Miri never
    /// answers, the read timeout has to surface as an error rather than
    /// blocking the agent's turn indefinitely.
    func testClientReadTimesOutInsteadOfHangingForever() throws {
        let path = temporarySocketPath()
        let server = ControlSocketServer(path: path) { _ in
            try? await Task.sleep(for: .seconds(30))
            return .init(accepted: true, message: "too late")
        }
        try server.start()
        defer { server.stop() }

        let started = Date()
        XCTAssertThrowsError(
            try ControlClient.send(.init(text: "Which database?", awaitReply: true), path: path, readTimeout: 1)
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// Older callers omit the new fields entirely; the server must still
    /// decode their requests.
    func testRequestWithoutAwaitFieldsStillDecodes() throws {
        let legacy = Data(#"{"text":"hello","priority":0,"interruptible":true}"#.utf8)
        let decoded = try JSONDecoder().decode(VoiceStatusRequest.self, from: legacy)
        XCTAssertEqual(decoded.text, "hello")
        XCTAssertNil(decoded.awaitReply)
    }

    func testReplyTimeoutIsClampedToSaneBounds() {
        XCTAssertEqual(VoiceReplyTimeout.clamped(nil), VoiceReplyTimeout.default)
        XCTAssertEqual(VoiceReplyTimeout.clamped(99_999), VoiceReplyTimeout.maximum)
        XCTAssertEqual(VoiceReplyTimeout.clamped(0), 5)
        XCTAssertEqual(VoiceReplyTimeout.clamped(120), 120)
    }

    /// Per-socket SO_NOSIGPIPE (set in acceptLoop) was observed insufficient
    /// on at least one CI runner: a client disconnect during
    /// testDisconnectedClientDoesNotCrashTheServer still killed the process
    /// with SIGPIPE even with that fix in place. The process-wide
    /// `signal(SIGPIPE, SIG_IGN)` is the reliable fix; this proves it is
    /// actually engaged by writing directly to a closed pipe with no socket
    /// options involved at all — SO_NOSIGPIPE cannot rescue this write, only
    /// the process-wide signal disposition can.
    func testProcessWideSIGPIPEIsIgnored() throws {
        _ = SIGPIPEProtection.ignoreOnce
        var fds: [Int32] = [0, 0]
        let created = fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress) }
        XCTAssertEqual(created, 0)
        let readEnd = fds[0], writeEnd = fds[1]
        close(readEnd) // No reader left: the next write must raise EPIPE.
        var byte: UInt8 = 1
        let result = write(writeEnd, &byte, 1)
        close(writeEnd)
        XCTAssertEqual(result, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    /// A client that connects, sends a request, and disconnects before the
    /// (possibly slow) handler writes its response used to raise SIGPIPE on
    /// the accepted socket, whose default action kills the whole process.
    /// Revert-to-RED: remove SIGPIPEProtection.ignoreOnce from both
    /// ControlSocketServer.start() and ControlClient.send() and this
    /// crashes the test process with signal 13 instead of completing —
    /// reproduced against a real CI runner where per-socket SO_NOSIGPIPE
    /// alone was not sufficient.
    func testDisconnectedClientDoesNotCrashTheServer() async throws {
        let path = temporarySocketPath()
        let server = ControlSocketServer(path: path) { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return .init(accepted: true, message: "reply after client is gone")
        }
        try server.start()
        defer { server.stop() }

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            _ = path.utf8.withContiguousStorageIfAvailable { bytes.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let request = Data(#"{"text":"hello","priority":0,"interruptible":true}"#.utf8) + Data([0x0A])
        _ = request.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        close(client)

        // Give the handler time to run past the client's disconnect and
        // attempt its write. A subsequent request on the same server proves
        // the process (and the accept loop) survived.
        try? await Task.sleep(for: .milliseconds(400))
        let response = try ControlClient.send(.init(text: "still alive"), path: path)
        XCTAssertTrue(response.accepted)
    }
}
