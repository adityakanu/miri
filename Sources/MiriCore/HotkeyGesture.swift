import Foundation

/// What releasing the push-to-talk hotkey meant.
///
/// Holding speaks; a quick tap opens the Agent HUD. Sharing one key keeps the
/// single-agent path a single gesture while still giving multi-agent users a
/// way to choose.
public enum HotkeyGesture: Equatable, Sendable {
    case speak
    case openHUD

    /// Below this, a press with no captured audio is treated as a tap.
    public static let tapThreshold: TimeInterval = 0.25

    public static func classify(heldFor duration: TimeInterval, capturedAudio: Bool) -> Self {
        // Any captured audio means the user actually spoke: never discard a
        // real utterance just because the press was brief.
        if capturedAudio { return .speak }
        return duration < tapThreshold ? .openHUD : .speak
    }
}
