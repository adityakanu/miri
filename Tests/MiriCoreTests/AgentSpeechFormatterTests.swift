import XCTest
@testable import MiriCore

final class AgentSpeechFormatterTests: XCTestCase {
    func testRemovesCodeLinksAndPrivatePaths() {
        let input = """
        Done. [Open docs](https://example.com).
        ```swift
        print("secret")
        ```
        See /Users/name/private/file.swift
        Next step is testing.
        """
        XCTAssertEqual(AgentSpeechFormatter.spokenText(from: input), "Done. Open docs. Next step is testing.")
    }

    func testTruncatesAtReadableBoundary() {
        let input = "First sentence. Second sentence is much longer than limit. Third sentence."
        let spoken = AgentSpeechFormatter.spokenText(from: input, maxCharacters: 35)
        XCTAssertEqual(spoken, "First sentence. Full response is available in Miri.")
    }
}
