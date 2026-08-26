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

    /// Regression: `load` awaits inside the actor, so concurrent callers used to
    /// slip past the `manager == nil` guard and compile the CoreML encoder
    /// twice, blocking the app for ~16 s. Loading must be shared, not repeated.
    func testConcurrentLoadsDoNotDuplicateWork() async throws {
        try XCTSkipUnless(ParakeetTranscriber.isInstalled, "requires installed Parakeet models")
        let transcriber = ParakeetTranscriber()
        let started = Date()
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try await transcriber.load(allowDownload: false) }
            }
            while let _ = try? await group.next() {}
        }
        let elapsed = Date().timeIntervalSince(started)
        let loaded = await transcriber.isLoaded
        XCTAssertTrue(loaded)
        // Four serial compiles would take well over a minute on the machine
        // that produced the original 16 s log line.
        XCTAssertLessThan(elapsed, 40, "concurrent loads appear to have duplicated model compilation")
    }
}
