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
            "serverInfo": ["name": "miri-mcp", "version": "0.1.0"],
        ])
    case "notifications/initialized":
        continue
    case "ping":
        output = response(id: id, result: [:])
    case "tools/list":
        output = response(id: id, result: ["tools": [[
            "name": "voice_status",
            "description": "Speak a concise progress, blocker, approval, question, warning, or completion status through Miri.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "maxLength": 180],
                    "priority": ["oneOf": [["type": "string", "enum": ["progress", "question", "urgent"]], ["type": "integer", "minimum": 0, "maximum": 2]], "default": "progress"],
                    "interruptible": ["type": "boolean", "default": true],
                ],
                "required": ["text"],
                "additionalProperties": false,
            ],
        ]]])
    case "tools/call":
        let parameters = request["params"] as? [String: Any]
        let arguments = parameters?["arguments"] as? [String: Any]
        guard parameters?["name"] as? String == "voice_status", let text = arguments?["text"] as? String else {
            output = response(id: id, error: ["code": -32602, "message": "Invalid voice_status arguments"]); break
        }
        guard let priority = priorityValue(arguments?["priority"]) else {
            output = response(id: id, error: ["code": -32602, "message": "priority must be progress, question, urgent, or 0...2"]); break
        }
        let interruptible = arguments?["interruptible"] as? Bool ?? true
        do {
            let delivery = try ControlClient.send(.init(text: text, priority: priority, interruptible: interruptible))
            output = response(id: id, result: ["content": [["type": "text", "text": delivery.message]], "isError": !delivery.accepted])
        } catch {
            output = response(id: id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    default:
        output = response(id: id, error: ["code": -32601, "message": "Method not found"])
    }
    FileHandle.standardOutput.write(output + Data([0x0A]))
}
