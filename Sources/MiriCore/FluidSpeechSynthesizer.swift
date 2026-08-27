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
    private var voice: String
    private let logger = MiriLogger()

    public init(voice: String = "alba") { self.voice = voice }

    public var isLoaded: Bool { manager != nil }

    public func setVoice(_ voice: String) { self.voice = voice }

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
    public nonisolated static var isInstalled: Bool {
        let root = modelsDirectory.appending(path: "pocket-tts", directoryHint: .isDirectory)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return false }
        return !contents.isEmpty
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
            // Refuse every network fetch when the user has not consented.
            ModelHub.offlineMode = true
        }
        defer { ModelHub.offlineMode = false }
        let started = Date()
        let manager = PocketTtsManager(defaultVoice: voice, language: .english)
        try await manager.initialize()
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
