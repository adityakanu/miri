import XCTest
@testable import MiriCore

final class ConfigurationStoreTests: XCTestCase {
    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appending(path: "miri-config-tests-\(UUID().uuidString)/config.toml") }

    func testInitialLoadCreatesValidFileAndRoundTripsAtomicWrite() async throws {
        let url = temporaryURL(); let store = ConfigurationStore(url: url)
        let initial = try await store.load()
        XCTAssertEqual(initial.configuration.version, 1)
        var changed = initial.configuration
        changed.sections["ui"] = ["overlay": .string("notch")]
        try await store.write(changed)
        let loaded = try MiriConfigurationParser.parse(String(contentsOf: url, encoding: .utf8), file: url.path)
        XCTAssertEqual(loaded.configuration.sections["ui"]?["overlay"], .string("notch"))
    }

    func testWriteDetectsExternalConflict() async throws {
        let url = temporaryURL(); let store = ConfigurationStore(url: url)
        var configuration = try await store.load().configuration
        try Data("version = 1\n# external edit makes this signature different\n".utf8).write(to: url, options: .atomic)
        configuration.inputMode = "wake_word"
        do { try await store.write(configuration); XCTFail("expected conflict") }
        catch { XCTAssertTrue(error is ConfigurationConflictError) }
    }

    func testExternalValidAndInvalidEditsEmitEvents() async throws {
        let url = temporaryURL(); let store = ConfigurationStore(url: url); _ = try await store.load()
        let events = await store.events(); var iterator = events.makeAsyncIterator()
        try Data("version = 1\ninput_mode = \"wake_word\"\n".utf8).write(to: url, options: .atomic)
        await store.reloadIfChanged()
        if let event = await iterator.next(), case .loaded(let result) = event { XCTAssertEqual(result.configuration.inputMode, "wake_word") } else { XCTFail("expected reload") }
        try Data("version = 9\n".utf8).write(to: url, options: .atomic)
        await store.reloadIfChanged()
        if let event = await iterator.next(), case .diagnostics(let values) = event { XCTAssertFalse(values.isEmpty) } else { XCTFail("expected diagnostics") }
    }
}
