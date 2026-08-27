import Foundation

/// How Miri starts listening. Push-to-talk is the only mode.
///
/// Wake word lived entirely in the removed Python worker and has no CoreML
/// replacement. This stays an enum because config.toml persists `input_mode`
/// and older releases wrote `wake_word`, which must still load.
public enum MiriInputMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case pushToTalk = "push_to_talk"

    public static let supportedCases: [Self] = [.pushToTalk]
    public static func supported(configurationValue: String) -> Self {
        supportedCases.first { $0.rawValue == configurationValue } ?? .pushToTalk
    }

    public var id: String { rawValue }
    public var displayName: String { "Push to Talk" }
    public var detail: String { "Miri listens only while you hold the configured shortcut." }
}


public enum FirstRunStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case microphone
    case interaction
    case targets
    case privacy

    public var id: Int { rawValue }
    public var isFirst: Bool { self == Self.allCases.first }
    public var isLast: Bool { self == Self.allCases.last }
    public var previous: Self? { Self(rawValue: rawValue - 1) }
    public var next: Self? { Self(rawValue: rawValue + 1) }
}

public struct FirstRunReadiness: Equatable, Sendable {
    public let microphonePermission: MicrophonePermission
    public let enabledTargetCount: Int

    public init(microphonePermission: MicrophonePermission, targets: [TargetDefinition]) {
        self.microphonePermission = microphonePermission
        enabledTargetCount = targets.lazy.filter(\.enabled).count
    }

    public var canFinish: Bool { microphonePermission == .granted && enabledTargetCount > 0 }

    public var remainingRequirements: [String] {
        var result: [String] = []
        if microphonePermission != .granted { result.append("Allow microphone access") }
        if enabledTargetCount == 0 { result.append("Configure at least one enabled target") }
        return result
    }
}
