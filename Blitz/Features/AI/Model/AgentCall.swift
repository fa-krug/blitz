import Foundation

/// One tool call as the policy weighs it: the tool, and for the shell the command line it runs.
struct AgentCall: Equatable, Sendable {
    let tool: AgentTool
    let command: String?

    init(tool: AgentTool, command: String? = nil) {
        self.tool = tool
        self.command = command
    }

    static func shell(_ command: String) -> AgentCall {
        AgentCall(tool: .shell, command: command)
    }
}
