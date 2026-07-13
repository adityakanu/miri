import Foundation
import MiriCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("miri: \(message)\n".utf8)); exit(code)
}

func parsePriority(_ value: String) -> Int? {
    if let number = Int(value), 0...2 ~= number { return number }
    return ["progress": 0, "question": 1, "urgent": 2, "warning": 2, "completion": 0][value.lowercased()]
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: miri status <text> | miri models use-defaults --moonshine-path <directory> | miri agents test-codex", code: 64) }

switch arguments[1] {
case "status":
    guard arguments.count >= 3 else { fail("usage: miri status <text> [--priority N] [--non-interruptible]", code: 64) }
    let args = Array(arguments.dropFirst(2)); var priority = 0
    if let i = args.firstIndex(of: "--priority"), args.indices.contains(i + 1) {
        guard let parsed = parsePriority(args[i + 1]) else { fail("priority must be progress, question, urgent, or 0...2", code: 64) }
        priority = parsed
    }
    let flags = Set(args.filter { $0.hasPrefix("--") }); let text = args.prefix { !$0.hasPrefix("--") }.joined(separator: " ")
    do {
        let response = try ControlClient.send(.init(text: text, priority: priority, interruptible: !flags.contains("--non-interruptible")))
        guard response.accepted else { fail(response.message) }
    } catch { fail(error.localizedDescription) }

case "models" where arguments.count >= 5 && ["use-defaults", "use-accuracy"].contains(arguments[2]):
    guard let index = arguments.firstIndex(of: "--moonshine-path"), arguments.indices.contains(index + 1) else { fail("--moonshine-path is required", code: 64) }
    let url = URL(fileURLWithPath: MiriPaths.configPath)
    do {
        let source = try String(contentsOf: url, encoding: .utf8)
        var configuration = try MiriConfigurationParser.parse(source, file: url.path).configuration
        configuration.sections["stt", default: [:]]["provider"] = .string("moonshine")
        let accuracy = arguments[2] == "use-accuracy"
        configuration.sections["stt", default: [:]]["model"] = .string(accuracy ? "medium-streaming" : "small-streaming")
        configuration.sections["stt", default: [:]]["model_path"] = .string(arguments[index + 1])
        configuration.sections["stt", default: [:]]["model_arch"] = .integer(accuracy ? 5 : 4)
        configuration.sections["tts", default: [:]]["provider"] = .string("pocket-tts")
        configuration.sections["tts", default: [:]]["language"] = .string("english")
        configuration.sections["tts", default: [:]]["voice"] = .string("alba")
        configuration.sections["tts", default: [:]]["allow_model_downloads"] = .boolean(true)
        _ = try MiriConfigurationParser.parse(String(decoding: ConfigurationStore.serialize(configuration), as: UTF8.self), file: url.path)
        try ConfigurationStore.serialize(configuration).write(to: url, options: .atomic)
        print("Configured Moonshine \(accuracy ? "Medium" : "Small") Streaming and Pocket TTS in \(url.path)")
    } catch { fail(error.localizedDescription) }

case "agents" where arguments.count >= 5 && arguments[2] == "use-codex":
    guard let index = arguments.firstIndex(of: "--thread-id"), arguments.indices.contains(index + 1) else { fail("--thread-id is required", code: 64) }
    let url = URL(fileURLWithPath: MiriPaths.configPath)
    do {
        let source = try String(contentsOf: url, encoding: .utf8)
        var configuration = try MiriConfigurationParser.parse(source, file: url.path).configuration
        let target = TargetDefinition(id: "codex-miri", name: "Codex - Miri", agent: "codex", adapter: "codex", workingDirectory: FileManager.default.currentDirectoryPath, session: arguments[index + 1])
        configuration.targets.removeAll { $0.id == target.id }
        configuration.targets.append(target); configuration.defaultTarget = target.id
        _ = try MiriConfigurationParser.parse(String(decoding: ConfigurationStore.serialize(configuration), as: UTF8.self), file: url.path)
        try ConfigurationStore.serialize(configuration).write(to: url, options: .atomic)
        print("Configured Codex thread \(arguments[index + 1]) as Miri's default target")
    } catch { fail(error.localizedDescription) }

case "agents" where arguments.count >= 5 && arguments[2] == "probe-codex":
    guard let index = arguments.firstIndex(of: "--thread-id"), arguments.indices.contains(index + 1) else { fail("--thread-id is required", code: 64) }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [home.appending(path: ".local/bin/codex"), URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { fail("Codex executable not found") }
    let adapter = CodexAppServerAdapter(id: "probe", executable: executable, workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), threadID: arguments[index + 1])
    do {
        try await adapter.connect()
        print("Codex app-server target status: \(await adapter.status().rawValue)")
        await adapter.disconnect()
    } catch { fail(error.localizedDescription) }

case "agents" where arguments.count >= 3 && arguments[2] == "test-codex":
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [home.appending(path: ".local/bin/codex"), URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { fail("Codex executable not found") }
    let adapter = CodexAppServerAdapter(id: "smoke-test", executable: executable, workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let eventTask = Task<String, Error> {
        var response = ""
        for await event in adapter.events() {
            switch event {
            case .responseDelta(let delta): response += delta
            case .responseCompleted(let final): response = final
            case .completed: return response
            case .failed(let message): throw NSError(domain: "MiriCodexTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            case .status: break
            }
        }
        return response
    }
    do {
        try await adapter.connect()
        _ = try await adapter.sendUserMessage("Reply with exactly MIRI_CODEX_OK. Do not use tools.")
        let response = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await eventTask.value }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw NSError(domain: "MiriCodexTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Codex test timed out after 60 seconds"])
            }
            let first = try await group.next() ?? ""
            group.cancelAll()
            return first
        }
        guard response.trimmingCharacters(in: .whitespacesAndNewlines) == "MIRI_CODEX_OK" else { fail("unexpected Codex response: \(response)") }
        print("Codex end-to-end test passed: \(response)")
        await adapter.disconnect()
    } catch {
        eventTask.cancel(); await adapter.disconnect(); fail(error.localizedDescription)
    }

case "agents" where arguments.count >= 3 && arguments[2] == "list-codex":
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [home.appending(path: ".local/bin/codex"), URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { fail("Codex executable not found") }
    do {
        let configURL = URL(fileURLWithPath: MiriPaths.configPath)
        let configuration = try MiriConfigurationParser.parse(String(contentsOf: configURL, encoding: .utf8), file: configURL.path).configuration
        guard let target = configuration.targets.first(where: { $0.adapter == "codex" }) else { fail("No configured Codex target") }
        let adapter = CodexAppServerAdapter(id: "catalog", executable: executable, workingDirectory: URL(fileURLWithPath: target.workingDirectory ?? FileManager.default.currentDirectoryPath), opensThread: false)
        try await adapter.connect()
        let threads = try await adapter.listThreads(limit: 30)
        for thread in threads {
            print("\(thread.id)\t\(thread.status)\t\(thread.displayName)\t\(thread.workingDirectory)")
        }
        await adapter.disconnect()
    } catch { fail(error.localizedDescription) }

default:
    fail("unknown command", code: 64)
}
