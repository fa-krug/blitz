import Foundation

/// A server's trust is its row in the agent table, read and written in place rather than copied.
extension MCPTrust {
    init(_ decision: AgentDecision) {
        switch decision {
        case .allow: self = .always
        case .ask: self = .ask
        case .deny: self = .never
        }
    }

    var decision: AgentDecision {
        switch self {
        case .always: .allow
        case .ask: .ask
        case .never: .deny
        }
    }
}

extension AgentTool {
    /// The row a model's tool call falls under; nil for a name neither Blitz nor a server spells.
    init?(wireName: String) {
        if let tool = AgentTool(builtInToolName: wireName) {
            self = tool
        } else if let parsed = MCPToolName.parse(wireName) {
            self = .mcp(parsed.slug)
        } else {
            return nil
        }
    }
}

extension AgentCall {
    /// The row a model's call falls under, with the command a shell call would run.
    init?(toolCall: AIToolCall) {
        guard let tool = AgentTool(wireName: toolCall.name) else { return nil }
        let command =
            tool == .shell ? (try? AIToolArguments(toolCall.arguments))?.string("command") : nil
        self.init(tool: tool, command: command)
    }
}

extension AgentCall {
    /// One listed tool, read-only only where its server's annotation says so.
    init(_ tool: MCPTool) {
        self = .mcp(tool.serverSlug, readOnly: tool.isReadOnly)
    }

    /// A call a CLI's own client made, weighed by what Blitz saw the server list for that tool.
    static func mcp(_ call: AIToolServerCall, listed: [MCPTool]) -> AgentCall {
        let tool = listed.first { $0.serverSlug == call.handle && $0.name == call.tool }
        return .mcp(call.handle, readOnly: tool?.isReadOnly ?? false)
    }

    /// A whole server as a CLI is handed it: Plan offers it while any one of its tools only looks.
    static func server(_ slug: String, listed: [MCPTool]) -> AgentCall {
        .mcp(slug, readOnly: listed.contains { $0.serverSlug == slug && $0.isReadOnly })
    }
}
