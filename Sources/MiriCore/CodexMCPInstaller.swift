import Foundation

public enum CodexMCPInstallerError: Error, LocalizedError {
    case commandFailed(String)
    public var errorDescription: String? { switch self { case .commandFailed(let message): message } }
}

public enum CodexMCPInstaller {
    public static func isInstalled(codex: URL) -> Bool {
        (try? run(codex, ["mcp", "get", "miri", "--json"])) != nil
    }

    public static func install(codex: URL, helper: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw CodexMCPInstallerError.commandFailed("Miri MCP helper was not found at \(helper.path)")
        }
        if isInstalled(codex: codex) { _ = try run(codex, ["mcp", "remove", "miri"]) }
        _ = try run(codex, ["mcp", "add", "miri", "--", helper.path])
    }

    @discardableResult private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process(); let output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        // Drain one combined pipe while the process runs. Waiting first can
        // deadlock if a future Codex CLI release writes more than a pipe buffer.
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexMCPInstallerError.commandFailed(detail.isEmpty ? "Codex MCP command failed" : detail)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
