import Foundation

/// The speech-provider choice. Transcription is on-device only.
///
/// The cloud provider was removed with the Python worker and is not
/// reimplemented natively, so this is a single case today. It stays an enum
/// because config.toml persists `stt.provider` and older releases wrote values
/// that must still load.
public enum STTBackend: String, CaseIterable, Identifiable, Sendable {
    case parakeet

    public static let supportedCases: [Self] = [.parakeet]
    public static func supported(configurationValue: String) -> Self {
        supportedCases.first { $0.rawValue == configurationValue } ?? .parakeet
    }

    public var id: String { rawValue }
    public var displayName: String { "On-device (Parakeet)" }
    public var detail: String {
        "Fully offline on the Apple Neural Engine. Accurate, fast, and it does not invent words during silence."
    }

    /// True when transcription happens entirely on this Mac. Always true now,
    /// kept so the privacy copy reads from one source rather than a literal.
    public var isOnDevice: Bool { true }

    /// The value written to `stt.provider` in config.toml.
    public var configurationValue: String { rawValue }

    /// Older releases wrote "moonshine" or "cloud"; those configurations now
    /// resolve to the on-device default rather than failing to load.
    public init(configurationValue: String) {
        self = .parakeet
    }
}
