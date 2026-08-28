import Foundation

/// What releasing the push-to-talk shortcut should do.
///
/// A press shorter than the time Miri needs to open the microphone never
/// reaches the listening state, so the release has no recording to finish.
/// Treating that as a no-op made a quick tap look like a dead shortcut, so the
/// outcome is decided here — pure, and testable without a hotkey or a
/// microphone.
public enum HotkeyReleaseOutcome: Equatable, Sendable {
    /// Recording started; stop it and transcribe.
    case finishRecording
    /// The press was too brief to record anything. Explain the gesture.
    case explainHold
    /// Nothing was in flight and nothing needs explaining.
    case ignore

    /// A press shorter than this cannot produce usable audio: microphone
    /// permission, the audio engine, and the speech stream all have to start
    /// first. Measured against observed startup, with margin.
    public static let minimumHold: TimeInterval = 0.25

    /// - Parameters:
    ///   - isListening: whether recording actually reached the listening state.
    ///   - heldFor: how long the shortcut was down, when known.
    public static func resolve(isListening: Bool, heldFor: TimeInterval?) -> HotkeyReleaseOutcome {
        if isListening { return .finishRecording }
        // Only an actual short tap earns the hint. A release with no
        // measurable press belongs to some other state transition, and a long
        // press that still failed to start has already shown its own error.
        guard let heldFor, heldFor < minimumHold else { return .ignore }
        return .explainHold
    }
}
