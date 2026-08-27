import Foundation
import FluidAudio

public enum ParakeetError: LocalizedError, Equatable {
    case modelsMissing
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .modelsMissing: "The on-device speech model is not installed yet."
        case .notLoaded: "The on-device speech model is still loading."
        }
    }
}

public struct ParakeetDownloadProgress: Sendable, Equatable {
    public let message: String
    public let finished: Bool
    public init(message: String, finished: Bool = false) { self.message = message; self.finished = finished }
}

/// On-device speech recognition using NVIDIA Parakeet TDT on the Apple Neural
/// Engine, via FluidAudio.
///
/// This replaces the Python worker for transcription: `MicrophoneCapture`
/// already emits 16 kHz mono Float32, which is exactly what `transcribe`
/// consumes, so audio never leaves the process.
public actor ParakeetTranscriber {
    private var manager: AsrManager?
    private var decoderState: TdtDecoderState?
    private var buffer: [Float] = []
    private var active = false
    private var loadTask: Task<Void, Error>?
    private let logger = MiriLogger()

    public init() {}

    /// Where FluidAudio keeps its CoreML bundles. Exposed so the UI can report
    /// installation state and so "delete downloaded models" can remove them.
    public nonisolated static var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/FluidAudio/Models", directoryHint: .isDirectory)
    }

    public nonisolated static var isInstalled: Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.lastPathComponent.hasPrefix("parakeet") }
    }

    public var isLoaded: Bool { manager != nil }

    /// Loads the model, downloading it only when `allowDownload` is true.
    /// Miri requires explicit consent before any model download.
    ///
    /// Concurrent callers share one load. The `await` inside the load suspends
    /// the actor, so without this a second caller would sail past the
    /// `manager == nil` check and compile the CoreML encoder a second time —
    /// which measurably starved the rest of the app for ~16 seconds.
    public func load(allowDownload: Bool) async throws {
        guard manager == nil else { return }
        if let loadTask { return try await loadTask.value }
        let task = Task<Void, Error> { [allowDownload] in
            try await performLoad(allowDownload: allowDownload)
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func performLoad(allowDownload: Bool) async throws {
        if !allowDownload {
            guard Self.isInstalled else { throw ParakeetError.modelsMissing }
        }
        let started = Date()
        // The gate owns the process-wide download switch and serialises loads.
        // See ModelDownloadGate for why per-load flag flipping broke consent.
        let manager = try await ModelDownloadGate.shared.run(allowDownload: allowDownload) {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        self.manager = manager
        self.decoderState = try TdtDecoderState()
        logger.log("parakeet loaded in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    }

    public func unload() {
        loadTask?.cancel()
        loadTask = nil
        manager = nil
        decoderState = nil
        buffer.removeAll()
        active = false
    }

    public func startStream() throws {
        guard manager != nil else { throw ParakeetError.notLoaded }
        // A fresh decoder state per utterance: push-to-talk turns are
        // independent, and stale context would leak the previous transcript.
        decoderState = try TdtDecoderState()
        buffer.removeAll(keepingCapacity: true)
        active = true
    }

    public func accept(_ samples: [Float]) {
        guard active else { return }
        buffer.append(contentsOf: samples)
    }

    /// Transcribes the buffered utterance. Latency is flat in clip length
    /// because the transducer decodes incrementally.
    public func finish() async throws -> String {
        guard let manager else { throw ParakeetError.notLoaded }
        active = false
        let samples = buffer
        buffer.removeAll(keepingCapacity: true)
        guard !samples.isEmpty else { return "" }
        var state = try decoderState ?? TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        decoderState = state
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() {
        active = false
        buffer.removeAll(keepingCapacity: true)
    }

    /// Removes the downloaded CoreML bundles so "delete models" is complete.
    public nonisolated static func removeDownloadedModels() throws {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else { return }
        try FileManager.default.removeItem(at: modelsDirectory)
    }
}
