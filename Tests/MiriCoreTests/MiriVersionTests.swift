import Foundation
@testable import MiriCore
import XCTest

final class MiriVersionTests: XCTestCase {
    func testReportedVersionsUseCurrentRelease() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expected = "0.1.4"
        let codexSource = try String(contentsOf: root.appending(path: "Sources/MiriCore/CodexAppServerAdapter.swift"), encoding: .utf8)
        let mcpSource = try String(contentsOf: root.appending(path: "Sources/MiriMCP/main.swift"), encoding: .utf8)
        let plistData = try Data(contentsOf: root.appending(path: "App/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])

        XCTAssertEqual(MiriVersion.current, expected)
        XCTAssertTrue(codexSource.contains("\"version\": MiriVersion.current"))
        XCTAssertTrue(mcpSource.contains("\"version\": MiriVersion.current"))
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, expected)
    }
}
