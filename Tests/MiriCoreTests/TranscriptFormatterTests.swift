import XCTest
@testable import MiriCore

final class TranscriptFormatterTests: XCTestCase {
    /// Guards the whole point of the feature: dictating code must not produce
    /// spelled-out numbers. If the native NeMo library ever stops being linked,
    /// this fails rather than silently regressing to spoken form.
    func testSpokenNumbersBecomeWrittenForm() {
        XCTAssertTrue(TranscriptFormatter.isAvailable, "FluidAudio's ITN library must be linked")
        XCTAssertEqual(TranscriptFormatter.written("make the port eight thousand and eighty"), "make the port 8080")
        XCTAssertEqual(TranscriptFormatter.written("set the timeout to thirty seconds"), "set the timeout to 30 seconds")
        XCTAssertEqual(TranscriptFormatter.written("add a retry with three attempts"), "add a retry with 3 attempts")
    }

    /// Voice approvals are parsed from the raw transcript, but normalization
    /// must not corrupt them even if that ordering ever changes.
    func testApprovalPhrasesSurviveNormalization() {
        for phrase in ["approve request", "deny request", "approve", "deny"] {
            let written = TranscriptFormatter.written(phrase)
            XCTAssertEqual(
                VoiceApprovalParser.parse(written),
                VoiceApprovalParser.parse(phrase),
                "normalization changed the meaning of '\(phrase)'"
            )
        }
    }

    func testEmptyAndBlankInputStayEmpty() {
        XCTAssertEqual(TranscriptFormatter.written(""), "")
        XCTAssertEqual(TranscriptFormatter.written("   "), "")
    }

    /// Normalization must never swallow an utterance.
    func testOrdinaryProseIsPreserved() {
        let prose = "refactor the delivery coordinator and add a test"
        XCTAssertEqual(TranscriptFormatter.written(prose), prose)
    }
}
