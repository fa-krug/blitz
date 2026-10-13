import Foundation

/// How one session narrows the rule table; never stored, and a grant only answers an Ask early.
struct AgentSessionScope: Equatable, Sendable {
    var isEnabled = true
    /// Switched off for this session; an MCP server added later arrives switched on.
    var excluded: Set<AgentTool> = []
    /// Turns every Allow into Ask, except where a tool has no Ask to turn it into.
    var asksForEverything = false
    /// "Allow This Chat" answers, so they end exactly when the session's scope does.
    private(set) var granted: Set<AgentTool> = []

    func allows(_ tool: AgentTool) -> Bool {
        isEnabled && !excluded.contains(tool)
    }

    func grants(_ tool: AgentTool) -> Bool {
        tool.canAllowForSession && granted.contains(tool)
    }

    /// Ask for Everything would cap a grant straight back to Ask, so none is offered under it.
    var offersGrants: Bool { !asksForEverything }

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
