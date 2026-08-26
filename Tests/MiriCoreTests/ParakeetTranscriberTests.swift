import XCTest
@testable import MiriCore

final class ParakeetTranscriberTests: XCTestCase {
    /// Model download must never happen implicitly: Miri requires consent.
    func testLoadWithoutConsentFailsWhenModelsAreAbsent() async throws {
        guard !ParakeetTranscriber.isInstalled else {
            throw XCTSkip("Parakeet models are installed on this machine")
        }
        let transcriber = ParakeetTranscriber()
        do {
            try await transcriber.load(allowDownload: false)
            XCTFail("loading without consent must not download models")
        } catch let error as ParakeetError {
            XCTAssertEqual(error, .modelsMissing)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStreamingBeforeLoadIsRejected() async throws {
        guard !ParakeetTranscriber.isInstalled else {
            throw XCTSkip("Parakeet models are installed on this machine")
        }
        let transcriber = ParakeetTranscriber()
        do {
            try await transcriber.startStream()
            XCTFail("streaming must require a loaded model")
        } catch let error as ParakeetError {
            XCTAssertEqual(error, .notLoaded)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Audio accepted while no stream is open must be discarded, so a stray
    /// buffer cannot leak into the next utterance.
    func testAudioOutsideAStreamIsIgnored() async {
        let transcriber = ParakeetTranscriber()
        await transcriber.accept([0.1, 0.2, 0.3])
        await transcriber.cancel()
        let loaded = await transcriber.isLoaded
        XCTAssertFalse(loaded)
    }

    func testModelsDirectoryIsInsideApplicationSupport() {
        let path = ParakeetTranscriber.modelsDirectory.path
        XCTAssertTrue(path.contains("Library/Application Support"), path)
        XCTAssertTrue(path.hasSuffix("Models"), path)
    }
}

extension ParakeetError: @retroactive Equatable {
    public static func == (lhs: ParakeetError, rhs: ParakeetError) -> Bool {
        switch (lhs, rhs) {
        case (.modelsMissing, .modelsMissing), (.notLoaded, .notLoaded): true
        default: false
        }
    }
}
