import Foundation

public enum ConfigurationSeverity: String, Equatable, Sendable { case warning, error }

public struct ConfigurationDiagnostic: Error, Equatable, Sendable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let severity: ConfigurationSeverity
    public let message: String

    public init(file: String, line: Int, severity: ConfigurationSeverity, message: String) {
        self.file = file; self.line = line; self.severity = severity; self.message = message
    }
    public var description: String { "\(file):\(line): \(severity.rawValue): \(message)" }
}

public struct ConfigurationValidationError: Error, Sendable, LocalizedError {
    public let diagnostics: [ConfigurationDiagnostic]
    public var errorDescription: String? { diagnostics.map(\.description).joined(separator: "\n") }
}

public enum ConfigurationValue: Equatable, Sendable {
    case string(String), integer(Int), number(Double), boolean(Bool)
}

public struct MiriConfiguration: Equatable, Sendable {
    public var version: Int
    public var defaultTarget: String?
    public var inputMode: String
    public var sections: [String: [String: ConfigurationValue]]
    public var targets: [TargetDefinition]

    public init(version: Int = 1, defaultTarget: String? = nil, inputMode: String = "push_to_talk", sections: [String: [String: ConfigurationValue]] = [:], targets: [TargetDefinition] = []) {
        self.version = version; self.defaultTarget = defaultTarget; self.inputMode = inputMode
        self.sections = sections; self.targets = targets
    }
}

public struct ConfigurationLoadResult: Sendable {
    public let configuration: MiriConfiguration
    public let warnings: [ConfigurationDiagnostic]
}

/// A deliberately small TOML reader for Miri's documented schema. It supports TOML
/// strings, numbers, booleans, tables, and `[[targets]]`; unsupported syntax fails
/// loudly instead of being interpreted loosely.
public enum MiriConfigurationParser {
    private static let sectionKeys: [String: Set<String>] = [
        "ui": ["overlay", "show_transcript_preview", "display", "animation"],
        "audio": ["input_device", "output_device", "pause_stt_while_speaking", "speech_volume", "profile", "sample_rate"],
        "hotkeys": ["active_target", "cancel", "stop_speaking"],
        "stt": ["provider", "model", "model_path", "model_arch", "language", "transcription_interval_ms"],
        "tts": ["provider", "model", "language", "config_path", "voice", "voice_path", "max_characters", "allow_model_downloads", "speak_agent_responses", "agent_response_max_characters"],
        "vad": ["provider", "threshold", "minimum_silence_ms"],
        "wakeword": ["enabled", "provider", "model_path", "threshold", "utterance_timeout_seconds"],
        "models": ["stt", "tts", "manifest_path", "directory"],
        "interaction": ["mode", "half_duplex", "wake_word"]
    ]
    private static let targetKeys: Set<String> = ["id", "name", "agent", "adapter", "working_directory", "project", "session", "endpoint", "hotkey", "enabled", "queue_replacement"]

    public static func parse(_ source: String, file: String = MiriPaths.configPath) throws -> ConfigurationLoadResult {
        var root: [String: (ConfigurationValue, Int)] = [:]
        var sections: [String: [String: ConfigurationValue]] = [:]
        var rawTargets: [[String: (ConfigurationValue, Int)]] = []
        var sectionLines: [String: [String: Int]] = [:]
        var currentSection = ""
        var targetIndex: Int?
        var diagnostics: [ConfigurationDiagnostic] = []

        for (offset, rawLine) in source.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[[") {
                guard line == "[[targets]]" else {
                    diagnostics.append(.init(file: file, line: lineNumber, severity: .error, message: "unknown array table \(line)")); continue
                }
                rawTargets.append([:]); targetIndex = rawTargets.count - 1; currentSection = "targets"; continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                    diagnostics.append(.init(file: file, line: lineNumber, severity: .error, message: "malformed table header")); continue
                }
                currentSection = String(line.dropFirst().dropLast())
                targetIndex = nil
                if sectionKeys[currentSection] == nil {
                    diagnostics.append(.init(file: file, line: lineNumber, severity: .warning, message: "unknown table [\(currentSection)]"))
                }
                continue
            }
            guard let equals = unquotedEquals(in: line) else {
                diagnostics.append(.init(file: file, line: lineNumber, severity: .error, message: "expected key = value")); continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let valueText = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard isBareKey(key) else {
                diagnostics.append(.init(file: file, line: lineNumber, severity: .error, message: "invalid key '\(key)'")); continue
            }
            guard let value = parseValue(valueText) else {
                diagnostics.append(.init(file: file, line: lineNumber, severity: .error, message: "unsupported or malformed value for '\(key)'")); continue
            }
            if let targetIndex {
                if !targetKeys.contains(key) { diagnostics.append(.init(file: file, line: lineNumber, severity: .warning, message: "unknown target key '\(key)'")) }
                if rawTargets[targetIndex][key] != nil { diagnostics.append(.init(file: file, line: lineNumber, severity: .error, message: "duplicate key '\(key)'")) }
                rawTargets[targetIndex][key] = (value, lineNumber)
            } else if currentSection.isEmpty {
                if !["version", "default_target", "input_mode"].contains(key) { diagnostics.append(.init(file: file, line: lineNumber, severity: .warning, message: "unknown root key '\(key)'")) }
                if root[key] != nil { diagnostics.append(.init(file: file, line: lineNumber, severity: .error, message: "duplicate key '\(key)'")) }
                root[key] = (value, lineNumber)
            } else {
                if !(sectionKeys[currentSection]?.contains(key) ?? false) { diagnostics.append(.init(file: file, line: lineNumber, severity: .warning, message: "unknown key '\(key)' in [\(currentSection)]")) }
                sections[currentSection, default: [:]][key] = value
                sectionLines[currentSection, default: [:]][key] = lineNumber
            }
        }

        let version = int(root["version"]?.0) ?? 0
        if version != 1 { diagnostics.append(.init(file: file, line: root["version"]?.1 ?? 1, severity: .error, message: "version must be 1")) }
        let defaultTarget = string(root["default_target"]?.0)
        let inputMode = string(root["input_mode"]?.0) ?? "push_to_talk"
        if !["push_to_talk", "wake_word"].contains(inputMode) { diagnostics.append(.init(file: file, line: root["input_mode"]?.1 ?? 1, severity: .error, message: "input_mode must be push_to_talk or wake_word")) }

        var targets: [TargetDefinition] = []
        for raw in rawTargets {
            let line = raw.values.map(\.1).min() ?? 1
            guard let id = string(raw["id"]?.0), !id.isEmpty else { diagnostics.append(.init(file: file, line: line, severity: .error, message: "target requires a non-empty id")); continue }
            guard let name = string(raw["name"]?.0), !name.isEmpty else { diagnostics.append(.init(file: file, line: line, severity: .error, message: "target '\(id)' requires a name")); continue }
            guard let adapter = string(raw["adapter"]?.0), !adapter.isEmpty else { diagnostics.append(.init(file: file, line: line, severity: .error, message: "target '\(id)' requires an adapter")); continue }
            let queueReplacement = string(raw["queue_replacement"]?.0) ?? "reject"
            if !["reject", "replace", "confirm"].contains(queueReplacement) {
                diagnostics.append(.init(file: file, line: raw["queue_replacement"]?.1 ?? line, severity: .error, message: "target '\(id)' queue_replacement must be reject, replace, or confirm"))
            }
            targets.append(.init(id: id, name: name, agent: string(raw["agent"]?.0), adapter: adapter, workingDirectory: string(raw["working_directory"]?.0), project: string(raw["project"]?.0), session: string(raw["session"]?.0), endpoint: string(raw["endpoint"]?.0), hotkey: string(raw["hotkey"]?.0), enabled: bool(raw["enabled"]?.0) ?? true, queueReplacement: queueReplacement))
        }
        let duplicates = Dictionary(grouping: targets, by: \.id).filter { $0.value.count > 1 }.keys
        for id in duplicates { diagnostics.append(.init(file: file, line: 1, severity: .error, message: "duplicate target id '\(id)'")) }
        if let defaultTarget, !targets.contains(where: { $0.id == defaultTarget && $0.enabled }) {
            diagnostics.append(.init(file: file, line: root["default_target"]?.1 ?? 1, severity: .error, message: "default_target '\(defaultTarget)' is not an enabled target"))
        }
        var shortcuts: [String: (label: String, line: Int)] = [:]
        func recordShortcut(_ shortcut: String?, label: String, line: Int) {
            guard let shortcut, !shortcut.isEmpty else { return }
            let normalized = shortcut.lowercased().filter { !$0.isWhitespace }
            if let previous = shortcuts[normalized] {
                diagnostics.append(.init(file: file, line: line, severity: .error, message: "hotkey '\(shortcut)' for \(label) conflicts with \(previous.label) on line \(previous.line)"))
            } else { shortcuts[normalized] = (label, line) }
        }
        for key in ["active_target", "cancel", "stop_speaking"] {
            recordShortcut(string(sections["hotkeys"]?[key]), label: "hotkeys.\(key)", line: sectionLines["hotkeys"]?[key] ?? 1)
        }
        for raw in rawTargets {
            let id = string(raw["id"]?.0) ?? "unnamed target"
            recordShortcut(string(raw["hotkey"]?.0), label: "target '\(id)'", line: raw["hotkey"]?.1 ?? 1)
        }
        let errors = diagnostics.filter { $0.severity == .error }
        if !errors.isEmpty { throw ConfigurationValidationError(diagnostics: diagnostics) }
        return .init(configuration: .init(version: version, defaultTarget: defaultTarget, inputMode: inputMode, sections: sections, targets: targets), warnings: diagnostics)
    }

    private static func stripComment(_ line: String) -> String {
        var quoted = false; var escaped = false
        for index in line.indices {
            let character = line[index]
            if character == "\"" && !escaped { quoted.toggle() }
            if character == "#" && !quoted { return String(line[..<index]) }
            escaped = character == "\\" && !escaped
            if character != "\\" { escaped = false }
        }
        return line
    }
    private static func unquotedEquals(in line: String) -> String.Index? {
        var quoted = false
        for index in line.indices { if line[index] == "\"" { quoted.toggle() }; if line[index] == "=" && !quoted { return index } }
        return nil
    }
    private static func isBareKey(_ key: String) -> Bool { !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } }
    private static func parseValue(_ text: String) -> ConfigurationValue? {
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            let inner = String(text.dropFirst().dropLast())
            return .string(inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\\", with: "\\"))
        }
        if text == "true" { return .boolean(true) }; if text == "false" { return .boolean(false) }
        if let value = Int(text) { return .integer(value) }; if let value = Double(text) { return .number(value) }
        return nil
    }
    private static func string(_ value: ConfigurationValue?) -> String? { if case .string(let result) = value { return result }; return nil }
    private static func int(_ value: ConfigurationValue?) -> Int? { if case .integer(let result) = value { return result }; return nil }
    private static func bool(_ value: ConfigurationValue?) -> Bool? { if case .boolean(let result) = value { return result }; return nil }
}
