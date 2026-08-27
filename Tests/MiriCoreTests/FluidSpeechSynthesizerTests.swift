import XCTest
@testable import MiriCore

final class FluidSpeechSynthesizerTests: XCTestCase {
    /// PocketTTS caches under ~/.cache/fluidaudio on macOS, not Application
    /// Support. Pointing at the wrong root made "delete models" silently leave
    /// half a gigabyte of voice weights on disk.
    func testModelsDirectoryIsTheMacOSTTSCacheRoot() {
        let path = FluidSpeechSynthesizer.modelsDirectory.path
        XCTAssertTrue(path.hasSuffix(".cache/fluidaudio/Models"), path)
        XCTAssertFalse(path.contains("Application Support"), path)
    }

    /// Parakeet and PocketTTS live under different roots, so a delete that only
    /// walks one of them cannot be complete.
    func testSpeechModelRootsAreDistinct() {
        XCTAssertNotEqual(
            FluidSpeechSynthesizer.modelsDirectory.standardizedFileURL,
            ParakeetTranscriber.modelsDirectory.standardizedFileURL
        )
    }

    /// Speaking must never trigger a ~520 MB download. The first agent reply
    /// previously did exactly that, with no consent prompt.
    func testLoadWithoutConsentFailsWhenVoiceIsAbsent() async throws {
        try XCTSkipIf(FluidSpeechSynthesizer.isInstalled, "Voice models are installed on this machine")
        let synthesizer = FluidSpeechSynthesizer()
        do {
            try await synthesizer.load(allowDownload: false)
            XCTFail("loading without consent must not download the voice")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .voiceMissing)
        }
    }

    func testSpeakingBeforeLoadIsRejected() async {
        let synthesizer = FluidSpeechSynthesizer()
        do {
            try await synthesizer.speak("hello", onFrame: { _ in }, onFinish: { _ in })
            XCTFail("speaking before load must be rejected")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .notLoaded)
        }
    }
}
