import XCTest
@testable import MiriCore

/// Parsing is tested against the payload shape documented for Hermes'
/// `GET /api/sessions`. No live server was available, so these fix the contract
/// we coded to rather than proving the server matches it.
final class HermesSessionDiscoveryTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParsesDocumentedEnvelope() throws {
        let sessions = try HermesSessionDiscovery.parse(data("""
        {
          "object": "list",
          "data": [
            {
              "id": "20260501_143012_a1b2c3d4",
              "title": "Kubernetes deployment review",
              "started_at": "2026-05-01T14:30:12Z",
              "last_active_at": "2026-05-01T15:42:07Z"
            }
          ],
          "total": 42
        }
        """))

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.agent, .hermes)
        XCTAssertEqual(sessions.first?.id, "20260501_143012_a1b2c3d4")
        XCTAssertEqual(sessions.first?.title, "Kubernetes deployment review")
    }

    func testAcceptsABareArray() throws {
        let sessions = try HermesSessionDiscovery.parse(data("""
        [{"id": "s1", "title": "one", "last_active_at": "2026-05-01T15:42:07Z"}]
        """))
        XCTAssertEqual(sessions.map(\.id), ["s1"])
    }

    /// A session with no title must still be selectable.
    func testUntitledSessionsGetAReadableFallback() throws {
        let sessions = try HermesSessionDiscovery.parse(data(#"{"data":[{"id":"abcdef123456"}]}"#))
        XCTAssertEqual(sessions.first?.title, "Hermes session abcdef12")
    }

    func testRowsWithoutAnIDAreSkippedRatherThanCrashing() throws {
        let sessions = try HermesSessionDiscovery.parse(data("""
        {"data":[{"title":"no id"},{"id":"","title":"blank"},{"id":"ok","title":"good"}]}
        """))
        XCTAssertEqual(sessions.map(\.id), ["ok"])
    }

    func testSessionsAreSortedMostRecentFirst() throws {
        let sessions = try HermesSessionDiscovery.parse(data("""
        {"data":[
          {"id":"old","last_active_at":"2026-05-01T10:00:00Z"},
          {"id":"new","last_active_at":"2026-05-02T10:00:00Z"}
        ]}
        """))
        XCTAssertEqual(sessions.map(\.id), ["new", "old"])
    }

    func testFractionalSecondTimestampsParse() throws {
        let sessions = try HermesSessionDiscovery.parse(data("""
        {"data":[{"id":"s","last_active_at":"2026-05-01T15:42:07.123Z"}]}
        """))
        XCTAssertNotEqual(sessions.first?.lastActiveAt, .distantPast)
    }

    func testNonJSONResponseIsReportedAsMalformed() {
        XCTAssertThrowsError(try HermesSessionDiscovery.parse(data("<html>nope</html>"))) { error in
            XCTAssertEqual(error as? HermesSessionDiscovery.Failure, .malformedResponse)
        }
    }

    /// Hermes' API server is opt-in, so "not running" is the common case and
    /// must surface as unreachable rather than as an empty session list.
    func testUnreachableServerThrowsRatherThanReturningNothing() async {
        do {
            _ = try await HermesSessionDiscovery.sessions(
                // Reserved discard port: nothing will ever answer.
                endpoint: URL(string: "http://127.0.0.1:9")!,
                apiKey: "unused"
            )
            XCTFail("expected a failure")
        } catch let failure as HermesSessionDiscovery.Failure {
            guard case .unreachable = failure else {
                return XCTFail("expected .unreachable, got \(failure)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
