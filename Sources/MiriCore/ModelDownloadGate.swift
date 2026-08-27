import Foundation
import FluidAudio

/// Serialises every model load and owns the process-wide download switch.
///
/// `ModelHub.offlineMode` proxies `HFClient.offlineMode`, a
/// `nonisolated(unsafe) static var` that FluidAudio documents as "set once at
/// startup". Two independent actors were flipping it per load, which broke
/// consent in both directions: an agent reply loading with
/// `allowDownload: false` during a user-consented install killed that install,
/// and a consented loader's `defer { offlineMode = false }` cleared the flag
/// while an unconsented loader was still fetching.
///
/// The gate closes both holes. Downloads are blocked for the whole process at
/// launch, loads run one at a time, and each load restores the *previous*
/// value rather than hardcoding `false`.
public actor ModelDownloadGate {
    public static let shared = ModelDownloadGate()

    /// Blocks every model download for the process. Call once at launch,
    /// before anything can load a model.
    public nonisolated static func blockDownloadsAtLaunch() {
        ModelHub.offlineMode = true
    }

    /// The live download switch. Exposed so tests and diagnostics can observe
    /// that a load left it exactly as it found it.
    public nonisolated static var downloadsBlocked: Bool {
        get { ModelHub.offlineMode }
        set { ModelHub.offlineMode = newValue }
    }

    /// Completed loads chain through this task, so `body` never overlaps
    /// another load. An actor alone is not enough: `body` suspends, and actor
    /// reentrancy would let a second loader in while the flag is flipped.
    private var tail: Task<Void, Never> = Task {}

    /// Runs `body` with downloads permitted only when `allowDownload` is true,
    /// waiting for any in-flight load to finish first.
    public func run<T: Sendable>(
        allowDownload: Bool,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let previous = tail
        let work = Task { () async throws -> T in
            await previous.value
            let saved = ModelHub.offlineMode
            ModelHub.offlineMode = !allowDownload
            defer { ModelHub.offlineMode = saved }
            return try await body()
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
}
