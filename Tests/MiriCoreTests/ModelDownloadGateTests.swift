import XCTest
@testable import MiriCore

/// Guards the consent bypass fixed by ModelDownloadGate. Before the gate, the
/// loaders flipped ModelHub.offlineMode per load: an unconsented load killed a
/// running consented download, and a consented load's `defer` hardcoded
/// `false`, clearing the block while an unconsented load was still fetching.
final class ModelDownloadGateTests: XCTestCase {
    /// Restore whatever the process-wide switch was, so these tests cannot
    /// leak the download block into the rest of the suite.
    private var saved = false

    override func setUp() {
        super.setUp()
        saved = ModelDownloadGate.downloadsBlocked
        ModelDownloadGate.blockDownloadsAtLaunch()
    }

    override func tearDown() {
        ModelDownloadGate.downloadsBlocked = saved
        super.tearDown()
    }

    func testLaunchBlocksDownloads() {
        XCTAssertTrue(ModelDownloadGate.downloadsBlocked)
    }

    func testConsentedLoadPermitsDownloadsOnlyForItsOwnBody() async throws {
        let observed = try await ModelDownloadGate.shared.run(allowDownload: true) {
            ModelDownloadGate.downloadsBlocked
        }
        XCTAssertFalse(observed, "a consented load must be allowed to download")
        XCTAssertTrue(
            ModelDownloadGate.downloadsBlocked,
            "the launch block must be restored, not hardcoded to false"
        )
    }

    func testUnconsentedLoadKeepsDownloadsBlocked() async throws {
        let observed = try await ModelDownloadGate.shared.run(allowDownload: false) {
            ModelDownloadGate.downloadsBlocked
        }
        XCTAssertTrue(observed)
        XCTAssertTrue(ModelDownloadGate.downloadsBlocked)
    }

    /// The regression that mattered most: an agent reply arriving mid-install
    /// used to set offlineMode = true and fail the user's own download.
    func testUnconsentedLoadCannotInterruptAConsentedDownload() async throws {
        // Sampled from inside the consented body, after an unconsented load
        // has had time to run. Any per-load flag flipping shows up here.
        let samples = Samples()

        async let consented: Void = ModelDownloadGate.shared.run(allowDownload: true) {
            for _ in 0..<10 {
                await samples.recordConsented(ModelDownloadGate.downloadsBlocked)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        // Give the consented load a head start, then contend with it.
        try await Task.sleep(for: .milliseconds(20))
        let unconsented = Task {
            try await ModelDownloadGate.shared.run(allowDownload: false) {
                ModelDownloadGate.downloadsBlocked
            }
        }

        try await consented
        let unconsentedSawBlock = try await unconsented.value

        let consentedSamples = await samples.consented
        XCTAssertFalse(
            consentedSamples.contains(true),
            "an unconsented load must not disable a consented download in flight"
        )
        XCTAssertTrue(
            unconsentedSawBlock,
            "an unconsented load must never inherit a consented load's permission"
        )
        XCTAssertTrue(ModelDownloadGate.downloadsBlocked)
    }
}

private actor Samples {
    private(set) var consented: [Bool] = []
    func recordConsented(_ blocked: Bool) { consented.append(blocked) }
}
