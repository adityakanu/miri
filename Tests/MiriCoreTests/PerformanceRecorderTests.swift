import XCTest
@testable import MiriCore

final class PerformanceRecorderTests: XCTestCase {
    func testRecorderWritesOnlyMetricMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let recorder = PerformanceRecorder(url: url)
        recorder.record("overlay_response_ms", milliseconds: 12.5, sessionID: "session")
        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(value?["metric"] as? String, "overlay_response_ms")
        XCTAssertNil(value?["text"])
        try? FileManager.default.removeItem(at: url)
    }
}
