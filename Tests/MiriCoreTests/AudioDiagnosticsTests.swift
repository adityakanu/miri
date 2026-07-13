import XCTest
@testable import MiriCore

final class AudioDiagnosticsTests: XCTestCase {
    func testDetectsQuietAndShortAudio() throws {
        let samples = [Float](repeating: 0.001, count: 16_000)
        let metrics = try XCTUnwrap(samples.withUnsafeBytes { AudioSignalMetrics.analyze(float32LE: Data($0)) })
        XCTAssertEqual(metrics.durationSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(metrics.qualityMessage, "Microphone input is very quiet")
    }
    func testHealthyAudioHasNoWarning() {
        let samples = [Float](repeating: 0.1, count: 16_000)
        let metrics = samples.withUnsafeBytes { AudioSignalMetrics.analyze(float32LE: Data($0)) }
        XCTAssertNil(metrics?.qualityMessage)
    }
}
