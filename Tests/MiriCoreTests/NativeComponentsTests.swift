import Carbon.HIToolbox
import XCTest
@testable import MiriCore

final class NativeComponentsTests: XCTestCase {
    func testOverlayFallbackIsTopCenteredBelowSafeArea() {
        let frame = StatusOverlayGeometry.frame(
            screenFrame: CGRect(x: 100, y: 50, width: 1_400, height: 900),
            safeAreaTop: 24,
            size: CGSize(width: 200, height: 40),
            margin: 8
        )
        XCTAssertEqual(frame.origin.x, 700)
        XCTAssertEqual(frame.origin.y, 878)
    }

    func testOverlayUsesNotchAuxiliaryGeometry() {
        let frame = StatusOverlayGeometry.frame(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            safeAreaTop: 38,
            auxiliaryTopLeft: CGRect(x: 0, y: 862, width: 630, height: 38),
            auxiliaryTopRight: CGRect(x: 810, y: 862, width: 630, height: 38),
            size: CGSize(width: 220, height: 46),
            margin: 8
        )
        XCTAssertEqual(frame.origin.x, 610)
        XCTAssertEqual(frame.origin.y, 808)
    }

    func testReduceMotionDisablesVisualAnimation() {
        let animated = StatusOverlayPresentation(state: .listening(target: "Codex - Miri"), reduceMotion: false)
        let reduced = StatusOverlayPresentation(state: .listening(target: "Codex - Miri"), reduceMotion: true)
        XCTAssertTrue(animated.animates)
        XCTAssertFalse(reduced.animates)
        XCTAssertEqual(reduced.accessibilityLabel, "Listening for Codex - Miri")
    }

    func testWorkerAudioFormatsAreStable() {
        XCTAssertEqual(MicrophoneCapture.workerSampleRate, 16_000)
        XCTAssertEqual(SpeechPCMPlayer.workerSampleRate, 24_000)
    }

    func testKeyboardShortcutRoundTripsThroughConfiguration() throws {
        let value = KeyboardShortcut.optionSpace
        XCTAssertEqual(try JSONDecoder().decode(KeyboardShortcut.self, from: JSONEncoder().encode(value)), value)
    }

    func testParsesConfiguredShortcut() throws {
        let shortcut = try KeyboardShortcut.parse("option+shift+c")
        XCTAssertEqual(shortcut.modifiers, UInt32(optionKey | shiftKey))
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_C))
        XCTAssertThrowsError(try KeyboardShortcut.parse("space"))
    }
}
