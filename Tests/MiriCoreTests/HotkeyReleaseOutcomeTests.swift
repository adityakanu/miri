import XCTest
@testable import MiriCore

/// A tap too short to open the microphone used to be silently swallowed, so
/// the shortcut looked broken. These pin the outcome of a release.
final class HotkeyReleaseOutcomeTests: XCTestCase {
    func testAHeldPressThatReachedListeningFinishesTheRecording() {
        XCTAssertEqual(
            HotkeyReleaseOutcome.resolve(isListening: true, heldFor: 1.5),
            .finishRecording
        )
    }

    /// Even a brief press finishes normally once recording actually started:
    /// the audio exists, so it must not be thrown away with a hint.
    func testAShortPressThatStillStartedRecordingIsNotTreatedAsATap() {
        XCTAssertEqual(
            HotkeyReleaseOutcome.resolve(isListening: true, heldFor: 0.05),
            .finishRecording
        )
    }

    func testATapTooShortToRecordExplainsTheGesture() {
        XCTAssertEqual(
            HotkeyReleaseOutcome.resolve(isListening: false, heldFor: 0.05),
            .explainHold
        )
    }

    /// A long press that never reached listening already showed its own error
    /// (no microphone permission, model still loading). Adding a hold hint on
    /// top would blame the user for the app's failure.
    func testALongPressThatFailedToStartIsLeftToItsOwnError() {
        XCTAssertEqual(
            HotkeyReleaseOutcome.resolve(isListening: false, heldFor: 4),
            .ignore
        )
    }

    func testAReleaseWithNoMeasuredPressIsIgnored() {
        XCTAssertEqual(
            HotkeyReleaseOutcome.resolve(isListening: false, heldFor: nil),
            .ignore
        )
    }

    func testTheThresholdBoundaryIsNotATap() {
        XCTAssertEqual(
            HotkeyReleaseOutcome.resolve(
                isListening: false,
                heldFor: HotkeyReleaseOutcome.minimumHold
            ),
            .ignore
        )
    }
}
