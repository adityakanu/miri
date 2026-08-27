import XCTest
@testable import MiriCore

final class HotkeyGestureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000)

    /// A quick tap is a deliberate gesture, not a failed recording.
    func testQuickTapOpensTheHUD() {
        let gesture = HotkeyGesture.classify(
            heldFor: 0.12,
            capturedAudio: false
        )
        XCTAssertEqual(gesture, .openHUD)
    }

    func testHoldingLongEnoughIsSpeech() {
        XCTAssertEqual(HotkeyGesture.classify(heldFor: 0.9, capturedAudio: true), .speak)
    }

    /// Audio already captured means the user spoke, however briefly; throwing it
    /// away to open a panel would lose a real utterance.
    func testShortPressThatCapturedSpeechIsStillSpeech() {
        XCTAssertEqual(HotkeyGesture.classify(heldFor: 0.12, capturedAudio: true), .speak)
    }

    func testThresholdIsInclusiveOfSpeech() {
        XCTAssertEqual(HotkeyGesture.classify(heldFor: HotkeyGesture.tapThreshold, capturedAudio: false), .speak)
    }
}
