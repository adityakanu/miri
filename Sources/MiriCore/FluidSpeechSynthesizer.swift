import Foundation
import FluidAudio

public enum SpeechSynthesisError: LocalizedError, Equatable {
    case notLoaded
    case voiceMissing

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The on-device voice is still loading."
        case .voiceMissing: "The on-device voice is not installed yet."
        }
    }
}

/// On-device streaming text-to-speech using PocketTTS CoreML models.
///
/// Replaces the Python worker's TTS path. PocketTTS emits 24 kHz mono Float32
/// frames, which `SpeechPCMPlayer` consumes directly, so synthesis audio never
/// crosses a process boundary.
public actor FluidSpeechSynthesizer {
    public typealias FrameHandler = @Sendable ([Float]) async -> Void

    private var manager: PocketTtsManager?
    private var loadTask: Task<Void, Error>?
    private var speakTask: Task<Void, Never>?
    private let voice: String
    private let logger = MiriLogger()

    public init(voice: String = "alba") { self.voice = voice }

    public var isLoaded: Bool { manager != nil }

    /// Where PocketTTS keeps its CoreML bundles.
    ///
    /// FluidAudio's TTS cache root is `~/.cache/fluidaudio` on macOS — a
    /// different tree from Parakeet's under Application Support. Both must be
    /// removed for "delete downloaded models" to be honest.
    public nonisolated static var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cache/fluidaudio/Models", directoryHint: .isDirectory)
    }

    /// True once the English voice pack is on disk. Checked before speaking so
    /// an agent reply can never silently start a ~520 MB download.
    ///
    /// A non-empty directory is not enough: an interrupted download leaves the
    /// tree partly written, and treating that as installed sends the loader
    /// into a failure instead of the system-voice fallback.
    public nonisolated static var isInstalled: Bool {
        let root = modelsDirectory.appending(path: "pocket-tts", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "mlmodelc" || url.pathExtension == "safetensors" {
            return true
        }
        return false
    }

    /// Loads the voice, downloading it only when `allowDownload` is true.
    ///
    /// Concurrent callers share one load, matching ParakeetTranscriber: an
    /// `await` inside the actor otherwise lets a second caller past the
    /// `manager == nil` check and compiles CoreML twice.
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
            guard Self.isInstalled else { throw SpeechSynthesisError.voiceMissing }
        }
        let started = Date()
        let voice = voice
        // The gate owns the process-wide download switch and serialises loads,
        // so an unconsented load can never cancel a consented download and a
        // consented one can never open the door for an unconsented fetch.
        let manager = try await ModelDownloadGate.shared.run(allowDownload: allowDownload) {
            let manager = PocketTtsManager(defaultVoice: voice, language: .english)
            try await manager.initialize()
            return manager
        }
        self.manager = manager
        logger.log("pocket tts loaded in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    }

    /// Synthesizes `text`, delivering 24 kHz Float32 frames as they are
    /// produced. `onFinish` runs once generation ends, including cancellation.
    public func speak(
        _ text: String,
        onFrame: @escaping FrameHandler,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) throws {
        guard let manager else { throw SpeechSynthesisError.notLoaded }
        speakTask?.cancel()
        let voice = self.voice
        speakTask = Task {
            do {
                let stream = try await manager.synthesizeStreaming(text: text, voice: voice)
                for try await frame in stream {
                    if Task.isCancelled { break }
                    await onFrame(frame.samples)
                }
                onFinish(nil)
            } catch is CancellationError {
                onFinish(nil)
            } catch {
                onFinish(error)
            }
        }
    }

    public func stop() {
        speakTask?.cancel()
        speakTask = nil
    }

    public func unload() {
        stop()
        loadTask?.cancel()
        loadTask = nil
        manager = nil
    }

    /// Removes the downloaded voice bundles so "delete models" is complete.
    public nonisolated static func removeDownloadedModels() throws {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else { return }
        try FileManager.default.removeItem(at: modelsDirectory)
    }
}
