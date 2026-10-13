import Foundation

/// The agent's standing rule table: one decision per built-in tool, plus ordered shell patterns.
struct AgentRules: Equatable, Sendable {
    var shell: AgentDecision
    var calendarRead: AgentDecision
    var calendarWrite: AgentDecision
    var remindersRead: AgentDecision
    var remindersWrite: AgentDecision
    var webSearch: AgentDecision {
        didSet { webSearch = Self.withoutAsk(webSearch) }
    }
    /// First match per segment decides it, so order is the user's to arrange.
    var shellRules: [ShellRule]

    init(
        shell: AgentDecision, calendarRead: AgentDecision, calendarWrite: AgentDecision,
        remindersRead: AgentDecision, remindersWrite: AgentDecision, webSearch: AgentDecision,
        shellRules: [ShellRule] = []
    ) {
        self.shell = shell
        self.calendarRead = calendarRead
        self.calendarWrite = calendarWrite
        self.remindersRead = remindersRead
        self.remindersWrite = remindersWrite
        self.webSearch = Self.withoutAsk(webSearch)
        self.shellRules = shellRules
    }

    static let defaults = AgentRules(
        shell: .deny, calendarRead: .ask, calendarWrite: .deny, remindersRead: .ask,
        remindersWrite: .deny, webSearch: .allow)

    /// The table the old access pickers and shell switch amounted to; read once, then dropped.
    static func migrated(
        calendarAccess: AIDataAccess, remindersAccess: AIDataAccess, shellCommandsEnabled: Bool
    ) -> AgentRules {
        AgentRules(
            shell: shellCommandsEnabled ? .ask : .deny,
            calendarRead: calendarAccess.canRead ? .allow : .deny,
            calendarWrite: calendarAccess.canWrite ? .ask : .deny,
            remindersRead: remindersAccess.canRead ? .allow : .deny,
            remindersWrite: remindersAccess.canWrite ? .allow : .deny,
            webSearch: .allow)
    }

    /// Nil for an MCP server, whose row is its own `MCPServer.trust`.
    func decision(for tool: AgentTool) -> AgentDecision? {
        switch tool {
        case .shell: shell
        case .calendarRead: calendarRead
        case .calendarWrite: calendarWrite
        case .remindersRead: remindersRead
        case .remindersWrite: remindersWrite
        case .webSearch: webSearch
        case .mcp: nil
        }
    }

    /// Does nothing for an MCP server, whose row is its own `MCPServer.trust`.
    mutating func set(_ decision: AgentDecision, for tool: AgentTool) {
        switch tool {
        case .shell: shell = decision
        case .calendarRead: calendarRead = decision
        case .calendarWrite: calendarWrite = decision
        case .remindersRead: remindersRead = decision
        case .remindersWrite: remindersWrite = decision
        case .webSearch: webSearch = decision
        case .mcp: break
        }
    }

    /// The table under a feature's own switch: a tool whose feature is off reads as Deny.
    func restricted(to isAvailable: (AgentTool) -> Bool) -> AgentRules {
        var rules = self
        for tool in AgentTool.builtIn where !isAvailable(tool) {
            rules.set(.deny, for: tool)
        }
        return rules
    }

    private static func withoutAsk(_ decision: AgentDecision) -> AgentDecision {
        decision == .ask ? .deny : decision
    }
}

extension AgentRules: Codable {
    private enum CodingKeys: String, CodingKey {
        case shell, calendarRead, calendarWrite, remindersRead, remindersWrite, webSearch
        case shellRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            shell: try container.decode(AgentDecision.self, forKey: .shell),
            calendarRead: try container.decode(AgentDecision.self, forKey: .calendarRead),
            calendarWrite: try container.decode(AgentDecision.self, forKey: .calendarWrite),
            remindersRead: try container.decode(AgentDecision.self, forKey: .remindersRead),
            remindersWrite: try container.decode(AgentDecision.self, forKey: .remindersWrite),
            webSearch: try container.decode(AgentDecision.self, forKey: .webSearch),
            shellRules: try container.decode([ShellRule].self, forKey: .shellRules))
    }
}
