@preconcurrency import AVFoundation
import Foundation

public struct AudioPCMChunk: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum AudioIOError: LocalizedError {
    case unavailableInputFormat
    case converterCreationFailed
    case conversionFailed(String)
    case invalidPCM

    public var errorDescription: String? {
        switch self {
        case .unavailableInputFormat: "The selected microphone has no usable input format."
        case .converterCreationFailed: "Miri could not create an audio format converter."
        case .conversionFailed(let message): "Audio conversion failed: \(message)"
        case .invalidPCM: "The speech worker returned invalid PCM audio."
        }
    }
}

/// Captures the system-selected microphone and emits worker-ready 16 kHz mono Float32 PCM.
/// AVAudioEngine owns the real-time thread; consumers should move expensive work off the callback.
public final class MicrophoneCapture: @unchecked Sendable {
    public typealias ChunkHandler = @Sendable (AudioPCMChunk) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void

    public nonisolated static let workerSampleRate = 16_000.0

    private let engine: AVAudioEngine
    private let lock = NSLock()
    private var running = false

    private final class InputSupply: @unchecked Sendable {
        var supplied = false
    }

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    public var isRunning: Bool { lock.withLock { running } }

    public func start(
        bufferSize: AVAudioFrameCount = 1_024,
        onChunk: @escaping ChunkHandler,
        onError: @escaping ErrorHandler = { _ in }
    ) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw AudioIOError.unavailableInputFormat
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.workerSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioIOError.converterCreationFailed
        }

        input.installTap(onBus: 0, bufferSize: bufferSize, format: sourceFormat) { buffer, _ in
            do {
                if let chunk = try Self.convert(buffer, using: converter, to: targetFormat) {
                    onChunk(chunk)
                }
            } catch {
                onError(error)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            lock.withLock { running = true }
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    public func stop() {
        guard lock.withLock({ () -> Bool in
            guard running else { return false }
            running = false
            return true
        }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit { stop() }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) throws -> AudioPCMChunk? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioIOError.invalidPCM
        }

        let inputSupply = InputSupply()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputSupply.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputSupply.supplied = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error {
            throw AudioIOError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
        }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return nil }
        return AudioPCMChunk(
            samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))),
            sampleRate: format.sampleRate
        )
    }
}

/// Queues worker-produced 24 kHz mono Float32 PCM. AVAudioEngine resamples it for the output device.
@MainActor
public final class SpeechPCMPlayer {
    public nonisolated static let workerSampleRate = 24_000.0

    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private var queuedBufferCount = 0
    private var generationFinished = false
    private var drainedHandler: (() -> Void)?

    public init() throws {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.workerSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw AudioIOError.invalidPCM }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    public var isPlaying: Bool { player.isPlaying }
    public var volume: Float {
        get { player.volume }
        set { player.volume = min(1, max(0, newValue)) }
    }

    public func enqueue(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else { throw AudioIOError.invalidPCM }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        queuedBufferCount += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferDidPlay() }
        }
        if !player.isPlaying { player.play() }
    }

    public func enqueuePCMBytes(_ data: Data) throws {
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { throw AudioIOError.invalidPCM }
        var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        try enqueue(samples)
    }

    public func stop() {
        player.stop()
        engine.stop()
        engine.reset()
        queuedBufferCount = 0
        generationFinished = false
        drainedHandler = nil
    }

    /// Marks the producer stream complete without truncating buffers already
    /// scheduled on the audio device.
    public func finishWhenDrained(_ handler: @escaping () -> Void) {
        generationFinished = true
        drainedHandler = handler
        completeIfDrained()
    }

    private func bufferDidPlay() {
        queuedBufferCount = max(0, queuedBufferCount - 1)
        completeIfDrained()
    }

    private func completeIfDrained() {
        guard generationFinished, queuedBufferCount == 0 else { return }
        player.stop(); engine.stop(); engine.reset()
        generationFinished = false
        let handler = drainedHandler; drainedHandler = nil; handler?()
    }
}
