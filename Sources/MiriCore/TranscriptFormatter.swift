import Foundation
import FluidAudio

/// Converts spoken-form transcripts to written form before they reach an agent.
///
/// Parakeet emits words as spoken ("port eight thousand and eighty"), which is
/// wrong for dictating into code. FluidAudio ships NVIDIA NeMo's inverse text
/// normalization as a Rust library with a Swift wrapper, so this is a lookup
/// against rules that already exist rather than our own number parser.
///
/// Deliberately *not* applied to voice approvals: those are parsed from the raw
/// transcript, so no text transform sits on a permission boundary.
public enum TranscriptFormatter {
    /// True when the native NeMo library is linked. When it is not, every
    /// method below returns its input unchanged rather than failing.
    public static var isAvailable: Bool { TextNormalizer.shared.isNativeAvailable }

    /// Rewrites spoken numbers, currency, and units into written form.
    ///
    /// `normalizeSentence` is the sentence-context entry point: the plain
    /// `normalize` treats the whole string as one span and leaves
    /// "set timeout to two hundred milliseconds" untouched, while this yields
    /// "set timeout to 200 milliseconds".
    public static func written(_ transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let normalized = TextNormalizer.shared.normalizeSentence(trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Never let normalization empty out real speech.
        return normalized.isEmpty ? trimmed : normalized
    }
}
