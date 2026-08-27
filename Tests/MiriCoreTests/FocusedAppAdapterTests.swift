import XCTest
@testable import MiriCore

final class FocusedAppAdapterTests: XCTestCase {
    /// Collects what would have been typed, so the adapter is testable without
    /// a window server or Accessibility permission.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func record(_ chunk: String) { lock.lock(); storage.append(chunk); lock.unlock() }
        var chunks: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        var typed: String { chunks.joined() }
    }

    private func makeAdapter(permitted: Bool = true) -> (FocusedAppAdapter, Recorder) {
        let recorder = Recorder()
        let adapter = FocusedAppAdapter(
            id: "cursor",
            hasPermission: { permitted },
            post: { recorder.record($0) }
        )
        return (adapter, recorder)
    }

    func testTranscriptIsTypedIntoTheFocusedApp() async throws {
        let (adapter, recorder) = makeAdapter()
        let receipt = try await adapter.sendUserMessage("refactor the parser")

        XCTAssertEqual(recorder.typed, "refactor the parser")
        XCTAssertEqual(receipt.disposition, .delivered)
    }

    /// The utterance must survive chunking exactly — this is the whole contract.
    func testLongTranscriptIsReassembledExactly() async throws {
        let (adapter, recorder) = makeAdapter()
        let text = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 12)
            .trimmingCharacters(in: .whitespaces)
        _ = try await adapter.sendUserMessage(text)

        XCTAssertEqual(recorder.typed, text)
        XCTAssertGreaterThan(recorder.chunks.count, 1, "long text must actually be chunked")
    }

    /// CGEventKeyboardSetUnicodeString takes a UTF-16 buffer, so a chunk
    /// boundary must never land inside an emoji or combining sequence.
    func testChunkingNeverSplitsAGrapheme() {
        let text = "ship 🚀 now — café 👨‍👩‍👧‍👦 done"
        let chunks = FocusedAppAdapter.chunks(of: text)

        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertFalse(chunk.isEmpty)
            XCTAssertEqual(String(chunk.unicodeScalars), chunk, "chunk is not valid standalone text")
        }
    }

    /// A single character longer than the limit must still be emitted whole
    /// rather than dropped or split.
    func testOversizedGraphemeIsEmittedWhole() {
        let family = "👨‍👩‍👧‍👦"
        XCTAssertGreaterThan(family.utf16.count, 4)
        XCTAssertEqual(FocusedAppAdapter.chunks(of: family, limit: 4), [family])
    }

    /// Without Accessibility permission the utterance must fail loudly. Silently
    /// dropping it would look identical to a successful dictation.
    func testMissingAccessibilityPermissionFailsInsteadOfDroppingText() async {
        let (adapter, recorder) = makeAdapter(permitted: false)

        do {
            _ = try await adapter.sendUserMessage("this must not vanish")
            XCTFail("expected a permission error")
        } catch {
            XCTAssertEqual(error as? FocusedAppError, .accessibilityDenied)
        }
        XCTAssertTrue(recorder.chunks.isEmpty, "nothing may be typed without permission")

        let status = await adapter.status()
        XCTAssertEqual(status, .failed, "the target must show as unusable before the user speaks")
    }

    func testBlankTranscriptTypesNothing() async throws {
        let (adapter, recorder) = makeAdapter()
        _ = try await adapter.sendUserMessage("   ")
        XCTAssertTrue(recorder.chunks.isEmpty)
    }

    func testStatusIsReadyWhenPermissionIsGranted() async {
        let (adapter, _) = makeAdapter()
        let status = await adapter.status()
        XCTAssertEqual(status, .ready)
    }
}
