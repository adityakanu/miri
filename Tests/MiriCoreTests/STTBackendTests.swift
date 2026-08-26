import XCTest
@testable import MiriCore

final class STTBackendTests: XCTestCase {
    func testBackendRoundTripsThroughConfigurationValues() {
        for backend in STTBackend.allCases {
            XCTAssertEqual(STTBackend(configurationValue: backend.configurationValue), backend)
        }
        // Moonshine is the historical default; unknown values must not crash.
        XCTAssertEqual(STTBackend(configurationValue: "moonshine"), .local)
        XCTAssertEqual(STTBackend(configurationValue: "something-else"), .local)
        XCTAssertEqual(STTBackend(configurationValue: "parakeet"), .parakeet)
    }

    func testOnlyCloudLeavesTheDevice() {
        XCTAssertTrue(STTBackend.parakeet.isOnDevice)
        XCTAssertTrue(STTBackend.local.isOnDevice)
        XCTAssertFalse(STTBackend.cloud.isOnDevice)
    }

    func testValidationRejectsIncompleteOrNonHTTPEndpoints() {
        XCTAssertNil(STTCloudSettings().validationMessage)
        XCTAssertNotNil(STTCloudSettings(baseURL: "", model: "m").validationMessage)
        XCTAssertNotNil(STTCloudSettings(baseURL: "https://api.groq.com/openai/v1", model: "  ").validationMessage)
        XCTAssertNotNil(STTCloudSettings(baseURL: "ftp://example.com", model: "m").validationMessage)
        XCTAssertNotNil(STTCloudSettings(baseURL: "not a url", model: "m").validationMessage)
        // A local server is a legitimate "bring your own model" endpoint.
        XCTAssertTrue(STTCloudSettings(baseURL: "http://127.0.0.1:8080/v1", model: "whisper-1").isValid)
    }

    func testApplyingPresetFillsEndpointButCustomLeavesItAlone() {
        var settings = STTCloudSettings(baseURL: "http://old", model: "old")
        settings.apply(.groq)
        XCTAssertEqual(settings.baseURL, STTPreset.groq.baseURL)
        XCTAssertEqual(settings.model, STTPreset.groq.model)

        settings.apply(.custom)
        XCTAssertEqual(settings.baseURL, STTPreset.groq.baseURL, "Custom must not clear the user's endpoint")
    }

    func testSavedConfigurationReopensOnItsPreset() {
        XCTAssertEqual(STTPreset.matching(baseURL: STTPreset.groq.baseURL, model: STTPreset.groq.model).id, "groq")
        XCTAssertEqual(STTPreset.matching(baseURL: STTPreset.localServer.baseURL, model: "other").id, "local-server")
        XCTAssertEqual(STTPreset.matching(baseURL: "https://example.com/v1", model: "x").id, "custom")
    }

    func testLocalServerPresetNeedsNoCredential() {
        XCTAssertFalse(STTPreset.localServer.requiresKey)
        XCTAssertTrue(STTPreset.groq.requiresKey)
    }

    /// The parser uses a key allowlist, so every key the Speech tab writes must
    /// round-trip through serialize/parse without warnings or data loss.
    func testCloudKeysSurviveConfigurationRoundTripWithoutWarnings() throws {
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
        XCTAssertEqual(parsed.warnings, [], "Speech settings must not produce unknown-key warnings")

        let serialized = ConfigurationStore.serialize(parsed.configuration)
        let round = try MiriConfigurationParser.parse(String(decoding: serialized, as: UTF8.self), file: "rt.toml")
        XCTAssertEqual(round.warnings, [])
        XCTAssertEqual(round.configuration.sections["stt"]?["cloud_model"], .string("whisper-large-v3-turbo"))
        XCTAssertEqual(round.configuration.sections["stt"]?["cloud_prompt"], .string("Codex, SwiftUI"))
        XCTAssertEqual(round.configuration.sections["agents"]?["codex_path"], .string("/opt/homebrew/bin/codex"))
    }

    /// The key must never reach the configuration file.
    func testSerializedConfigurationNeverContainsTheAPIKey() throws {
        var configuration = MiriConfiguration(defaultTarget: "clipboard", targets: [.init(id: "clipboard", name: "Clipboard", adapter: "clipboard")])
        configuration.sections["stt"] = ["provider": .string("cloud"), "cloud_api_key_env": .string("MIRI_CLOUD_STT_KEY")]
        let text = String(decoding: ConfigurationStore.serialize(configuration), as: UTF8.self)
        XCTAssertFalse(text.contains("sk-"))
        XCTAssertTrue(text.contains("cloud_api_key_env"), "Only the variable name belongs in the file")
    }

    func testProbeBuildsAWellFormedSilentWAV() {
        let wav = CloudSTTProbe.silentWAV(seconds: 1)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav[8..<12], Data("WAVE".utf8))
        // 44-byte header plus one second of 16 kHz mono 16-bit silence.
        XCTAssertEqual(wav.count, 44 + 16_000 * 2)
    }
}

final class SecretStoreTests: XCTestCase {
    private let account = "unit-test-\(UUID().uuidString)"

    override func tearDown() {
        try? SecretStore.remove(account: account)
        super.tearDown()
    }

    func testSecretRoundTripsAndOverwrites() throws {
        try SecretStore.save("first-key", account: account)
        XCTAssertEqual(SecretStore.read(account: account), "first-key")
        XCTAssertTrue(SecretStore.hasSecret(account: account))

        try SecretStore.save("second-key", account: account)
        XCTAssertEqual(SecretStore.read(account: account), "second-key", "Saving again must replace, not duplicate")

        try SecretStore.remove(account: account)
        XCTAssertNil(SecretStore.read(account: account))
        XCTAssertFalse(SecretStore.hasSecret(account: account))
    }

    func testSavingBlankSecretClearsTheEntry() throws {
        try SecretStore.save("a-key", account: account)
        try SecretStore.save("   ", account: account)
        XCTAssertNil(SecretStore.read(account: account))
    }

    func testRemovingAMissingSecretIsNotAnError() {
        XCTAssertNoThrow(try SecretStore.remove(account: "absent-\(UUID().uuidString)"))
    }
}
