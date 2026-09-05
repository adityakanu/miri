import Foundation
import MiriCore

func response(id: Any, result: Any? = nil, error: [String: Any]? = nil) -> Data {
    var object: [String: Any] = ["jsonrpc": "2.0", "id": id]
    if let result { object["result"] = result }
    if let error { object["error"] = error }
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

func priorityValue(_ value: Any?) -> Int? {
    if let number = value as? Int, 0...2 ~= number { return number }
    guard let name = (value as? String)?.lowercased() else { return value == nil ? 0 : nil }
    return ["progress": 0, "question": 1, "urgent": 2, "warning": 2, "completion": 0][name]
}

for try await line in FileHandle.standardInput.bytes.lines {
    guard let input = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          let method = request["method"] as? String else { continue }
    let id = request["id"] ?? NSNull()
    let output: Data
    switch method {
    case "initialize":
        output = response(id: id, result: [
            "protocolVersion": "2025-06-18",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "miri-mcp", "version": MiriVersion.current],
        ])
    case "notifications/initialized":
        continue
    case "ping":
        output = response(id: id, result: [:])
    case "tools/list":
        output = response(id: id, result: ["tools": [[
            "name": "voice_status",
            "description": "Speak a concise local status through Miri and return immediately. Call with kind=progress while long work is still running, and kind=completion when it finishes. Use voice_ask instead whenever you actually need an answer. Miri binds statuses to this working directory. Never include secrets, code, commands, or private paths.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "maxLength": 180],
                    "kind": ["type": "string", "enum": ["progress", "completion", "question", "blocker", "warning"], "default": "progress"],
                    "target_id": ["type": "string", "description": "Optional Miri target ID. Usually omit; Miri resolves the current working directory."],
                    "priority": ["oneOf": [["type": "string", "enum": ["progress", "question", "urgent"]], ["type": "integer", "minimum": 0, "maximum": 2]], "default": "progress"],
                    "interruptible": ["type": "boolean", "default": true],
                ],
                "required": ["text"],
                "additionalProperties": false,
            ],
        ], [
            "name": "voice_ask",
            "description": "Ask the user a question through Miri and BLOCK until they answer by voice. Returns their spoken reply, so you keep your current context and continue this turn instead of ending it. Use this whenever you are blocked and need a decision. Ask one short, specific question; if you need a choice, name the options. If the result says no answer arrived, treat that as no decision — never as approval. Never include secrets, code, commands, or private paths.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "maxLength": 180, "description": "The question, phrased to be understood when heard aloud."],
                    "kind": ["type": "string", "enum": ["question", "blocker"], "default": "question", "description": "Use blocker when work has stopped entirely."],
                    "timeout_seconds": ["type": "number", "minimum": 5, "maximum": VoiceReplyTimeout.maximum, "default": VoiceReplyTimeout.default, "description": "How long to wait for the user. Longer is fine; they may be away from the desk."],
                    "target_id": ["type": "string", "description": "Optional Miri target ID. Usually omit; Miri resolves the current working directory."],
                ],
                "required": ["text"],
                "additionalProperties": false,
            ],
        ]]])
    case "tools/call":
        let parameters = request["params"] as? [String: Any]
        let arguments = parameters?["arguments"] as? [String: Any]
        let toolName = parameters?["name"] as? String
        guard toolName == "voice_status" || toolName == "voice_ask", let text = arguments?["text"] as? String else {
            output = response(id: id, error: ["code": -32602, "message": "Invalid tool arguments"]); break
        }
        let isAsk = toolName == "voice_ask"
        // A question that nobody hears cannot be answered, so an ask always
        // outranks routine progress chatter.
        guard let priority = isAsk ? 1 : priorityValue(arguments?["priority"]) else {
            output = response(id: id, error: ["code": -32602, "message": "priority must be progress, question, urgent, or 0...2"]); break
        }
        let interruptible = isAsk ? true : (arguments?["interruptible"] as? Bool ?? true)
        let kindName = arguments?["kind"] as? String ?? (isAsk ? "question" : "progress")
        guard let kind = VoiceStatusKind(rawValue: kindName), !isAsk || kind == .question || kind == .blocker else {
            output = response(id: id, error: ["code": -32602, "message": "invalid status kind"]); break
        }
        let replyTimeout = VoiceReplyTimeout.clamped((arguments?["timeout_seconds"] as? NSNumber)?.doubleValue)
        do {
            let delivery = try ControlClient.send(.init(
                text: text,
                priority: priority,
                interruptible: interruptible,
                kind: kind,
                targetID: arguments?["target_id"] as? String ?? ProcessInfo.processInfo.environment["MIRI_TARGET_ID"],
                sourceWorkingDirectory: FileManager.default.currentDirectoryPath,
                awaitReply: isAsk ? true : nil,
                replyTimeoutSeconds: isAsk ? replyTimeout : nil
            ), readTimeout: isAsk ? replyTimeout + 15 : ControlClient.defaultReadTimeout)
            // Report the absence of an answer as an error result, so silence
            // reads as "undecided" rather than as tacit approval.
            let message = isAsk ? (delivery.reply ?? "No answer from the user.") : delivery.message
            output = response(id: id, result: [
                "content": [["type": "text", "text": message]],
                "isError": isAsk ? (delivery.reply == nil) : !delivery.accepted,
            ])
        } catch {
            output = response(id: id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    default:
        output = response(id: id, error: ["code": -32601, "message": "Method not found"])
    }
    FileHandle.standardOutput.write(output + Data([0x0A]))
}
