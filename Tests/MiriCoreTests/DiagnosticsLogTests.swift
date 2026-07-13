import Foundation
import XCTest
@testable import MiriCore

final class DiagnosticsLogTests: XCTestCase {
    func testLoggerCreatesAndAppendsToPrivateLogFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = directory.appending(path: "miri.log")
        let logger = MiriLogger(fileURL: file)
        logger.log("started")
        logger.log(.error, "failed\nwithout multiline injection")

        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(contents.contains("[INFO] started"))
        XCTAssertTrue(contents.contains("[ERROR] failed without multiline injection"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
