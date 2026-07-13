import Foundation

public struct AudioSignalMetrics: Equatable, Sendable {
    public let durationSeconds: Double
    public let rms: Double
    public let peak: Double
    public let clippedFraction: Double

    public var qualityMessage: String? {
        if durationSeconds < 0.25 { return "Recording was too short" }
        if rms < 0.008 { return "Microphone input is very quiet" }
        if clippedFraction > 0.01 { return "Microphone input is clipping" }
        return nil
    }

    public static func analyze(float32LE data: Data, sampleRate: Double = 16_000) -> Self? {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size), sampleRate > 0 else { return nil }
        var sumSquares = 0.0; var peak = 0.0; var clipped = 0
        let count = data.count / MemoryLayout<Float>.size
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float.self)
            for sample in values {
                let value = abs(Double(sample)); sumSquares += value * value
                peak = max(peak, value); if value >= 0.99 { clipped += 1 }
            }
        }
        return .init(durationSeconds: Double(count) / sampleRate, rms: sqrt(sumSquares / Double(count)), peak: peak, clippedFraction: Double(clipped) / Double(count))
    }
}
