import Foundation

/// Blitz's own tools as the in-process `sdk` server Claude reaches over its control channel.
enum ClaudeHostedServer {
    /// `MCPSlug` never yields `_`, so no server the reader adds can take this name.
    static let handle = "blitz_data"
    static let protocolVersion = "2025-06-18"

    /// One JSON-RPC message the CLI addressed to this server, held open until Blitz answers.
    struct Message: Equatable, Sendable {
        let requestID: String
        let body: JSONValue
    }

    enum Reply: Equatable, Sendable {
        case answer(JSONValue)
        /// A `tools/call` for an offered tool; its result is `result(_:id:)` once it has run.
        case call(AIToolCall, id: JSONValue)
    }

    static func reply(to body: JSONValue, tools: [AITool]) -> Reply {
        let message = body.objectValue ?? [:]
        // The SDK answers a notification with an empty result, and the CLI waits for one.
        guard let id = message["id"], id != .null else { return .answer(envelope(id: .number(0))) }
        let params = message["params"]?.objectValue ?? [:]
        switch message["method"]?.stringValue {
        case "initialize":
            return .answer(
                envelope(
                    id: id,
                    result: .object([
                        "protocolVersion": params["protocolVersion"] ?? .string(protocolVersion),
                        "capabilities": .object(["tools": .object([:])]),
                        "serverInfo": .object(["name": .string("Blitz"), "version": .string("1")])
                    ])))
        case "ping":
            return .answer(envelope(id: id))
        case "tools/list":
            let listed: [JSONValue] = tools.map {
                .object([
                    "name": .string($0.name), "description": .string($0.description),
                    "inputSchema": $0.parameters
                ])
            }
            return .answer(envelope(id: id, result: .object(["tools": .array(listed)])))
        case "tools/call":
            let name = params["name"]?.stringValue ?? ""
            let call = AIToolCall(
                id: "\(handle)-\(id.stringValue ?? id.intValue.map(String.init) ?? "call")",
                name: name,
                arguments: AIToolJSON.text(params["arguments"] ?? .object([:])))
            guard tools.contains(where: { $0.name == name }) else {
                return .answer(
                    result(.failure(call.id, "Blitz offers no tool named \(name)."), id: id))
            }
            return .call(call, id: id)
        default:
            return .answer(
                .object([
                    "jsonrpc": .string("2.0"), "id": id,
                    "error": .object([
                        "code": .number(-32601), "message": .string("Method not found")
                    ])
                ]))
        }
    }

    /// A failed call is still a result the model reads, never a JSON-RPC error.
    static func result(_ result: AIToolResult, id: JSONValue) -> JSONValue {
        envelope(
            id: id,
            result: .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(result.content)])
                ]),
                "isError": .bool(result.isError)
            ]))
    }

    private static func envelope(id: JSONValue, result: JSONValue = .object([:])) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
}
