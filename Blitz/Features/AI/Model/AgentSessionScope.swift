import Foundation

/// How one session applies the rule table; never stored, and nothing in it ever lifts a Deny.
struct AgentSessionScope: Equatable, Sendable {
    var isEnabled = true
    /// Switched off for this session; an MCP server added later arrives switched on.
    var excluded: Set<AgentTool> = []
    var mode = AgentMode.manual
    /// "Allow This Chat" answers, so they end exactly when the session's scope does.
    private(set) var granted: Set<AgentTool> = []

    func allows(_ tool: AgentTool) -> Bool {
        isEnabled && !excluded.contains(tool)
    }

    func grants(_ tool: AgentTool) -> Bool {
        tool.canAllowForSession && granted.contains(tool)
    }

    mutating func grant(_ tool: AgentTool) {
        guard tool.canAllowForSession else { return }
        granted.insert(tool)
    }

    mutating func toggle(_ tool: AgentTool) {
        if excluded.contains(tool) {
            excluded.remove(tool)
        } else {
            excluded.insert(tool)
        }
    }
}
