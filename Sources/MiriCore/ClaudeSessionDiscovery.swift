import Foundation

/// Discovers Claude Code conversations from disk.
///
/// Claude Code has no list-sessions API. It writes one JSONL transcript per
/// session under `~/.claude/projects/<encoded-path>/<session-id>.jsonl`, where
/// the directory name is the working directory with `/` replaced by `-`.
/// Reading that tree is the only way to offer the user a session list.
///
/// Read-only: Miri never writes to Claude's directory.
public enum ClaudeSessionDiscovery {
    public static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
    }

    /// Sessions across every project, most recently modified first.
    ///
    /// `limit` caps the result because a long-lived install accumulates
    /// hundreds of transcripts and the picker only shows a handful.
    public static func sessions(
        in root: URL? = nil,
        limit: Int = 30,
        fileManager: FileManager = .default
    ) -> [AgentSessionSummary] {
        let projectsRoot = root ?? projectsDirectory
        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var found: [AgentSessionSummary] = []
        for project in projects {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let workingDirectory = decodeWorkingDirectory(project.lastPathComponent)
            // Only the project's own transcripts: `subagents/` holds child
            // conversations the user cannot address directly.
            guard let files = try? fileManager.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let scanned = scan(transcriptAt: file)
                found.append(
                    AgentSessionSummary(
                        id: file.deletingPathExtension().lastPathComponent,
                        agent: .claude,
                        title: scanned.title ?? "Claude session",
                        // The transcript records the true cwd; the directory
                        // name is a lossy fallback.
                        workingDirectory: scanned.workingDirectory ?? workingDirectory,
                        lastActiveAt: modified
                    )
                )
            }
        }
        return Array(found.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(limit))
    }

    /// `-Users-adityakanu-Developer-miri` → `/Users/adityakanu/Developer/miri`.
    ///
    /// The encoding is lossy: a directory whose real name contains a hyphen is
    /// indistinguishable from a path separator. The decoded path is therefore
    /// only used as a label, and is verified against the filesystem — an
    /// unverifiable path yields nil rather than a wrong one.
    static func decodeWorkingDirectory(
        _ encoded: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        let candidate = "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    /// The first genuine user message and the working directory the session
    /// ran in, taken from the transcript itself.
    ///
    /// Transcripts open with metadata lines and injected command caveats, and
    /// can be megabytes long, so this reads incrementally and stops as soon as
    /// both fields are known rather than parsing the whole file.
    static func scan(transcriptAt url: URL) -> (title: String?, workingDirectory: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }

        var buffer = Data()
        var scannedLines = 0
        var title: String?
        var workingDirectory: String?

        while scannedLines < 200 {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                scannedLines += 1
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                if workingDirectory == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty {
                    workingDirectory = cwd
                }
                if title == nil { title = userText(in: object) }
                if title != nil, workingDirectory != nil { return (title, workingDirectory) }
            }
        }
        return (title, workingDirectory)
    }

    private static func userText(in object: [String: Any]) -> String? {
        guard object["type"] as? String == "user",
              let message = object["message"] as? [String: Any]
        else { return nil }

        let raw: String?
        switch message["content"] {
        case let text as String:
            raw = text
        case let parts as [[String: Any]]:
            raw = parts.first { $0["type"] as? String == "text" }?["text"] as? String
        default:
            raw = nil
        }

        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude injects command caveats and system reminders as user turns.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        let firstLine = trimmed.components(separatedBy: .newlines)
            .first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        return firstLine.isEmpty ? nil : String(firstLine.prefix(72))
    }
}
