import Foundation

/// The user-facing speech-provider choice: an on-device model, or any
/// OpenAI-compatible endpoint (hosted or a local server such as whisper.cpp).
public enum STTBackend: String, CaseIterable, Identifiable, Sendable {
    case parakeet, local, cloud
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .parakeet: "On-device (Parakeet)"
        case .local: "On-device (Moonshine)"
        case .cloud: "OpenAI-compatible API"
        }
    }
    public var detail: String {
        switch self {
        case .parakeet: "Fully offline on the Apple Neural Engine. Recommended: most accurate local option, and it does not invent words during silence."
        case .local: "Fully offline. Smallest model; lower accuracy on technical vocabulary."
        case .cloud: "Sends each utterance to the endpoint you choose. Requires network."
        }
    }
    /// True when transcription happens entirely on this Mac.
    public var isOnDevice: Bool { self != .cloud }
    /// The value written to `stt.provider` in config.toml.
    public var configurationValue: String {
        switch self {
        case .parakeet: "parakeet"
        case .local: "moonshine"
        case .cloud: "cloud"
        }
    }
    public init(configurationValue: String) {
        switch configurationValue {
        case "parakeet": self = .parakeet
        case "cloud": self = .cloud
        default: self = .local
        }
    }
}

/// A one-click starting point for the cloud backend. `custom` lets the user
/// point Miri at any compatible server, including one running on this Mac.
public struct STTPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let model: String
    public let note: String
    /// A local server usually needs no credential.
    public let requiresKey: Bool

    public init(id: String, name: String, baseURL: String, model: String, note: String, requiresKey: Bool = true) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.model = model
        self.note = note; self.requiresKey = requiresKey
    }

    public static let groq = STTPreset(
        id: "groq",
        name: "Groq",
        baseURL: "https://api.groq.com/openai/v1",
        model: "whisper-large-v3-turbo",
        note: "Free tier, no credit card. Fast and accurate."
    )
    public static let openAI = STTPreset(
        id: "openai",
        name: "OpenAI",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4o-mini-transcribe",
        note: "Paid per minute of audio."
    )
    public static let localServer = STTPreset(
        id: "local-server",
        name: "Local server",
        baseURL: "http://127.0.0.1:8080/v1",
        model: "whisper-1",
        note: "Any OpenAI-compatible server on this Mac, such as whisper.cpp.",
        requiresKey: false
    )
    public static let custom = STTPreset(
        id: "custom",
        name: "Custom…",
        baseURL: "",
        model: "",
        note: "Enter your own endpoint and model.",
        requiresKey: false
    )

    public static let all: [STTPreset] = [.groq, .openAI, .localServer, .custom]

    /// Matches a saved configuration back to a preset so the UI reopens on the
    /// row the user actually chose. Falls back to Custom.
    public static func matching(baseURL: String, model: String) -> STTPreset {
        all.first { $0.id != "custom" && $0.baseURL == baseURL && $0.model == model }
            ?? all.first { $0.id != "custom" && $0.baseURL == baseURL }
            ?? .custom
    }
}

/// The editable cloud-endpoint settings shown in the UI.
public struct STTCloudSettings: Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var language: String
    public var prompt: String

    public init(baseURL: String = STTPreset.groq.baseURL, model: String = STTPreset.groq.model, language: String = "en", prompt: String = "") {
        self.baseURL = baseURL; self.model = model; self.language = language; self.prompt = prompt
    }

    public var trimmedBaseURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Returns nil when the settings are usable, or the reason they are not.
    public var validationMessage: String? {
        guard !trimmedBaseURL.isEmpty else { return "Enter the API base URL." }
        guard let url = URL(string: trimmedBaseURL), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            return "The base URL must be a valid http or https address."
        }
        guard !trimmedModel.isEmpty else { return "Enter the model name." }
        return nil
    }

    public var isValid: Bool { validationMessage == nil }

    public mutating func apply(_ preset: STTPreset) {
        guard preset.id != "custom" else { return }
        baseURL = preset.baseURL
        model = preset.model
    }
}
