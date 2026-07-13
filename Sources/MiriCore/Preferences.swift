import Foundation

public enum MiriInputMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case pushToTalk = "push_to_talk"
    case wakeWord = "wake_word"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pushToTalk: "Push to Talk"
        case .wakeWord: "Wake Word (Experimental)"
        }
    }

    public var detail: String {
        switch self {
        case .pushToTalk: "Miri listens only while you hold the configured shortcut."
        case .wakeWord: "Miri listens locally for a wake phrase and always shows a listening indicator."
        }
    }
}

public enum ModelLifecycleProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case responsive
    case balanced
    case eco

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }

    public var detail: String {
        switch self {
        case .responsive: "Keeps speech models warm for the lowest latency."
        case .balanced: "Releases models after inactivity to reduce memory use."
        case .eco: "Loads models only when needed to minimize background resources."
        }
    }
}

public enum FirstRunStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case microphone
    case interaction
    case models
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
