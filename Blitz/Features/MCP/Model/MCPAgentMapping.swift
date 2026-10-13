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
