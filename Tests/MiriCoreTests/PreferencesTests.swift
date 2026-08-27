import XCTest
@testable import MiriCore

final class PreferencesTests: XCTestCase {
    func testReleaseSupportsOnlyLocalPushToTalkSpeech() {
        XCTAssertEqual(STTBackend.supportedCases, [.parakeet])
        XCTAssertEqual(MiriInputMode.supportedCases, [.pushToTalk])
        XCTAssertEqual(STTBackend.supported(configurationValue: "cloud"), .parakeet)
        XCTAssertEqual(MiriInputMode.supported(configurationValue: "wake_word"), .pushToTalk)
    }

    func testConfigurationValuesMapToTypedPreferences() {
        XCTAssertEqual(MiriInputMode(rawValue: "push_to_talk"), .pushToTalk)
        XCTAssertEqual(MiriInputMode(rawValue: "wake_word"), .wakeWord)
        XCTAssertNil(MiriInputMode(rawValue: "telepathy"))
    }

    func testFirstRunStepNavigationStopsAtBoundaries() {
        XCTAssertNil(FirstRunStep.welcome.previous)
        XCTAssertEqual(FirstRunStep.welcome.next, .microphone)
        XCTAssertEqual(FirstRunStep.privacy.previous, .targets)
        XCTAssertNil(FirstRunStep.privacy.next)
    }

    func testReadinessRequiresMicrophoneAndEnabledTarget() {
        let disabled = TargetDefinition(id: "codex", name: "Codex", adapter: "clipboard", enabled: false)
        var readiness = FirstRunReadiness(microphonePermission: .denied, targets: [disabled])
        XCTAssertFalse(readiness.canFinish)
        XCTAssertEqual(readiness.remainingRequirements.count, 2)

        let enabled = TargetDefinition(id: "codex", name: "Codex", adapter: "clipboard")
        readiness = FirstRunReadiness(microphonePermission: .granted, targets: [enabled])
        XCTAssertTrue(readiness.canFinish)
        XCTAssertTrue(readiness.remainingRequirements.isEmpty)
    }
}
