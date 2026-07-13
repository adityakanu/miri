import Foundation

public enum AgentSpeechFormatter {
    public static func spokenText(from markdown: String, maxCharacters: Int = 600) -> String? {
        guard maxCharacters > 0 else { return nil }
        var result: [String] = []
        var insideFence = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { insideFence.toggle(); continue }
            guard !insideFence, !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("|") || trimmed.hasPrefix("<") || trimmed.contains("/Users/") { continue }
            var line = trimmed
            while let first = line.first, "#>*-".contains(first) {
                line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"`[^`]+`"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { result.append(line) }
        }

        let joined = result.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        if joined.count <= maxCharacters { return joined }
        let prefix = String(joined.prefix(maxCharacters))
        let boundary = prefix.lastIndex(where: { ".!?".contains($0) }) ?? prefix.lastIndex(of: " ")
        let shortened = boundary.map { String(prefix[...$0]) } ?? prefix
        return shortened.trimmingCharacters(in: .whitespacesAndNewlines) + " Full response is available in Miri."
    }
}
