import XCTest
@testable import MiriIPC

final class ProtocolTests: XCTestCase {
    func testRoundTrip() throws {
        let frame = IPCFrame(header: .init(requestID: "r1", sessionID: "s1", kind: .json, messageType: "health"), payload: Data("{}".utf8))
        XCTAssertEqual(try FrameCodec.decode(FrameCodec.encode(frame)), frame)
    }
    func testRejectsVersion() throws {
        let frame = IPCFrame(header: .init(version: 2, requestID: "r", kind: .json, messageType: "health"), payload: Data())
        XCTAssertThrowsError(try FrameCodec.decode(FrameCodec.encode(frame)))
    }
    func testIncrementalStreamDecoding() throws {
        let first = try FrameCodec.encode(.init(header: .init(requestID: "1", kind: .json, messageType: "hello"), payload: Data()))
        let second = try FrameCodec.encode(.init(header: .init(requestID: "2", kind: .json, messageType: "health"), payload: Data()))
        let all = first + second; var decoder = FrameStreamDecoder()
        XCTAssertTrue(try decoder.append(all.prefix(5)).isEmpty)
        XCTAssertEqual(try decoder.append(all.dropFirst(5)).map(\.header.requestID), ["1", "2"])
    }
    func testMessageTypesCoverContract() {
        XCTAssertTrue(MessageType.allCases.contains(.transcriptFinal))
        XCTAssertTrue(MessageType.allCases.contains(.speechChunk))
        XCTAssertTrue(MessageType.allCases.contains(.modelProgress))
        XCTAssertTrue(MessageType.allCases.contains(.wakeDetected))
        XCTAssertTrue(MessageType.allCases.contains(.audioEndpoint))
        XCTAssertTrue(MessageType.allCases.contains(.modelInstall))
    }
}
