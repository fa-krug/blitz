import Foundation

/// How one session narrows the rule table; never stored, and it can only take away.
struct AgentSessionScope: Equatable, Sendable {
    var isEnabled = true
    /// Switched off for this session; an MCP server added later arrives switched on.
    var excluded: Set<AgentTool> = []
    /// Turns every Allow into Ask, except where a tool has no Ask to turn it into.
    var asksForEverything = false

    func allows(_ tool: AgentTool) -> Bool {
        isEnabled && !excluded.contains(tool)
    }

    mutating func toggle(_ tool: AgentTool) {
        if excluded.contains(tool) {
            excluded.remove(tool)
        } else {
            excluded.insert(tool)
        }
    }
}
