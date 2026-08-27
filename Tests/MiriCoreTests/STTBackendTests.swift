import XCTest
@testable import MiriCore

final class STTBackendTests: XCTestCase {
    func testBackendRoundTripsThroughConfigurationValues() {
        for backend in STTBackend.allCases {
            XCTAssertEqual(STTBackend(configurationValue: backend.configurationValue), backend)
        }
    }

    /// Configurations written by older releases must keep working. Cloud and
    /// Moonshine were removed with the Python worker; both now resolve to the
    /// on-device model rather than failing to load.
    func testRetiredProvidersMigrateToOnDevice() {
        XCTAssertEqual(STTBackend(configurationValue: "moonshine"), .parakeet)
        XCTAssertEqual(STTBackend(configurationValue: "cloud"), .parakeet)
        XCTAssertEqual(STTBackend(configurationValue: "something-else"), .parakeet)
        XCTAssertEqual(STTBackend.supported(configurationValue: "cloud"), .parakeet)
    }

    func testTranscriptionIsAlwaysOnDevice() {
        XCTAssertTrue(STTBackend.parakeet.isOnDevice)
        XCTAssertEqual(STTBackend.supportedCases, [.parakeet])
    }

    /// A config file left over from a build that offered cloud transcription
    /// must still parse cleanly — the retired keys stay allowlisted so an
    /// upgrading user sees no unknown-key warnings and loses no other settings.
    func testRetiredCloudKeysStillParseWithoutWarnings() throws {
        let toml = """
        version = 1
        default_target = "clipboard"
        input_mode = "push_to_talk"

        [stt]
        provider = "cloud"
        cloud_base_url = "https://api.groq.com/openai/v1"
        cloud_model = "whisper-large-v3-turbo"
        cloud_language = "en"
        cloud_prompt = "Codex, SwiftUI"

        [agents]
        codex_path = "/opt/homebrew/bin/codex"

        [[targets]]
        id = "clipboard"
        name = "Clipboard"
        adapter = "clipboard"
        """
        let parsed = try MiriConfigurationParser.parse(toml, file: "test.toml")
        XCTAssertEqual(parsed.warnings, [], "A pre-existing config must not produce unknown-key warnings")

        let serialized = ConfigurationStore.serialize(parsed.configuration)
        let round = try MiriConfigurationParser.parse(String(decoding: serialized, as: UTF8.self), file: "rt.toml")
        XCTAssertEqual(round.warnings, [])
        XCTAssertEqual(round.configuration.sections["agents"]?["codex_path"], .string("/opt/homebrew/bin/codex"))
    }
}
