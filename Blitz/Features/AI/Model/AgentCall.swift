import Foundation

/// One tool call as the policy weighs it: the tool, and for the shell the command line it runs.
struct AgentCall: Equatable, Sendable {
    let tool: AgentTool
    let command: String?
    /// Only an MCP call sets it, from its server's `readOnlyHint` for the tool, never the model's.
    private let isReadOnlyServerTool: Bool

    init(tool: AgentTool, command: String? = nil) {
        self.init(tool: tool, command: command, isReadOnlyServerTool: false)
    }

    private init(tool: AgentTool, command: String?, isReadOnlyServerTool: Bool) {
        self.tool = tool
        self.command = command
        self.isReadOnlyServerTool = isReadOnlyServerTool
    }

    static func shell(_ command: String) -> AgentCall {
        AgentCall(tool: .shell, command: command)
    }

    /// One tool of a server; a call without the hint is never read-only, so Plan refuses it.
    static func mcp(_ slug: String, readOnly: Bool) -> AgentCall {
        AgentCall(tool: .mcp(slug), command: nil, isReadOnlyServerTool: readOnly)
    }

    /// Whether the call only looks, which is all Plan mode lets through besides the shell.
    var isReadOnly: Bool { tool.isReadOnly || isReadOnlyServerTool }
}
