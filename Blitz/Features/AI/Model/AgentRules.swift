import Foundation

/// The agent's standing rule table: one decision per built-in row, plus ordered patterns.
struct AgentRules: Equatable, Sendable {
    /// Always one entry per `AgentTool.builtIn` row, and never one for an MCP server.
    private var decisions: [AgentTool: AgentDecision]
    /// A matching Deny decides a segment; otherwise the first match does, so order matters.
    var shellRules: [ShellRule]
    /// Weighed like `shellRules`, per path, for the two file rows.
    var pathRules: [PathRule]

    /// A row left out takes its default, as does every MCP slug given here.
    init(
        _ decisions: [AgentTool: AgentDecision] = [:], shellRules: [ShellRule] = [],
        pathRules: [PathRule] = PathRule.seeds
    ) {
        self.decisions = Dictionary(
            uniqueKeysWithValues: AgentTool.builtIn.map { tool in
                (tool, Self.normalised(decisions[tool] ?? Self.defaultDecision(for: tool), tool))
            })
        self.shellRules = shellRules
        self.pathRules = pathRules
    }

    static let defaults = AgentRules()

    /// Reads ask, everything that acts is denied, and web search's composer globe is the opt-in.
    static func defaultDecision(for tool: AgentTool) -> AgentDecision {
        if tool == .webSearch { return .allow }
        return tool.isReadOnly ? .ask : .deny
    }

    /// The table the old access pickers and shell switch amounted to; read once, then dropped.
    static func migrated(
        calendarAccess: AIDataAccess, remindersAccess: AIDataAccess, shellCommandsEnabled: Bool
    ) -> AgentRules {
        AgentRules([
            .shell: shellCommandsEnabled ? .ask : .deny,
            .calendarRead: calendarAccess.canRead ? .allow : .deny,
            .calendarWrite: calendarAccess.canWrite ? .ask : .deny,
            .remindersRead: remindersAccess.canRead ? .allow : .deny,
            .remindersWrite: remindersAccess.canWrite ? .allow : .deny,
            .webSearch: .allow
        ])
    }

    /// Nil for an MCP server, whose row is its own `MCPServer.trust`.
    func decision(for tool: AgentTool) -> AgentDecision? {
        decisions[tool]
    }

    /// Does nothing for an MCP server, whose row is its own `MCPServer.trust`.
    mutating func set(_ decision: AgentDecision, for tool: AgentTool) {
        guard decisions[tool] != nil else { return }
        decisions[tool] = Self.normalised(decision, tool)
    }

    /// The table under a feature's own switch: a tool whose feature is off reads as Deny.
    func restricted(to isAvailable: (AgentTool) -> Bool) -> AgentRules {
        var rules = self
        for tool in AgentTool.builtIn where !isAvailable(tool) {
            rules.set(.deny, for: tool)
        }
        return rules
    }

    /// "Always Allow": ahead of the first rule that would still decide `command`, never later.
    mutating func allow(_ pattern: String, for command: String) {
        let key = ShellRule.collapsed(pattern)
        guard !key.isEmpty else { return }
        let segments = ShellCommandSegments.segments(of: command) ?? []
        shellRules = Self.placingAllow(
            ShellRule(pattern: pattern, decision: .allow), in: shellRules,
            isSame: { ShellRule.collapsed($0.pattern) == key },
            decides: { rule in rule.decision != .deny && segments.contains(where: rule.matches) },
            allowing: { $0.decision = .allow })
    }

    /// "Always Allow" for a file call: reads or writes only, placed as `allow(_:for:)` places one.
    mutating func allowPath(_ pattern: String, for call: AgentCall) {
        guard call.tool.usesPathRules else { return }
        let key = PathRule.collapsed(pattern)
        guard !key.isEmpty else { return }
        let access: PathRule.Access = call.tool == .filesRead ? .read : .write
        pathRules = Self.placingAllow(
            PathRule(pattern: pattern, access: access, decision: .allow), in: pathRules,
            isSame: { PathRule.collapsed($0.pattern) == key && $0.access == access },
            decides: { rule in
                rule.decision != .deny && rule.applies(to: call.tool)
                    && call.paths.contains { rule.matches($0, homeDirectory: call.homeDirectory) }
            },
            allowing: { $0.decision = .allow })
    }

    /// An existing twin is raised to Allow and moved up only if it must; a Deny is never passed.
    private static func placingAllow<Rule>(
        _ new: Rule, in rules: [Rule], isSame: (Rule) -> Bool, decides: (Rule) -> Bool,
        allowing: (inout Rule) -> Void
    ) -> [Rule] {
        var rules = rules
        let existing = rules.firstIndex(where: isSame)
        var rule = new
        if let existing {
            rule = rules.remove(at: existing)
            allowing(&rule)
        }
        let deciding = rules.firstIndex(where: decides)
        let index = [existing, deciding].compactMap(\.self).min() ?? rules.endIndex
        rules.insert(rule, at: index)
        return rules
    }

    /// Web search has no Ask, since Blitz never sees the provider's call to stop it.
    private static func normalised(_ decision: AgentDecision, _ tool: AgentTool) -> AgentDecision {
        !tool.canAsk && decision == .ask ? .deny : decision
    }
}

extension AgentRules: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }

        static let shellRules = Key(stringValue: "shellRules")
        static let pathRules = Key(stringValue: "pathRules")
    }

    /// Tolerant by field: a row or list added after the table was stored decodes as its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var decisions: [AgentTool: AgentDecision] = [:]
        for tool in AgentTool.builtIn {
            decisions[tool] = try container.decodeIfPresent(
                AgentDecision.self, forKey: Key(stringValue: tool.storageKey))
        }
        self.init(
            decisions,
            shellRules: try container.decodeIfPresent([ShellRule].self, forKey: .shellRules) ?? [],
            pathRules: try container.decodeIfPresent([PathRule].self, forKey: .pathRules)
                ?? PathRule.seeds)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for tool in AgentTool.builtIn {
            try container.encode(
                decision(for: tool) ?? Self.defaultDecision(for: tool),
                forKey: Key(stringValue: tool.storageKey))
        }
        try container.encode(shellRules, forKey: .shellRules)
        try container.encode(pathRules, forKey: .pathRules)
    }
}
