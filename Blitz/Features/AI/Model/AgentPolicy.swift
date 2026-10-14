import Foundation

/// The whole rule: whether one tool call runs, waits for the user, or is refused.
enum AgentPolicy {
    /// First words "Always Allow" never proposes: they delete, escalate, reach out or run code.
    static let neverSuggested: Set<String> = [
        "rm", "rmdir", "srm", "shred", "truncate", "dd", "mkfs", "newfs_apfs", "diskutil",
        "mv", "cp", "ln", "install", "tee",
        "chmod", "chown", "chgrp", "chflags", "xattr",
        "sudo", "su", "doas", "security", "csrutil", "spctl", "nvram", "systemsetup",
        "networksetup", "pmset", "tmutil", "launchctl", "defaults", "crontab", "at",
        "shutdown", "reboot", "halt",
        "kill", "killall", "pkill",
        "curl", "wget", "ssh", "scp", "sftp", "rsync", "ftp", "nc", "telnet",
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
        "python", "python3", "node", "ruby", "perl", "php", "lua", "osascript", "swift",
        "npx", "bunx", "deno", "awk", "gawk", "expect",
        "env", "xargs", "find", "nohup", "nice", "timeout", "watch", "open"
    ]

    /// `mcpTrust` answers for a server by slug, and must say `.deny` for one that is off or gone.
    static func decision(
        for call: AgentCall, rules: AgentRules, mcpTrust: (String) -> AgentDecision,
        scope: AgentSessionScope
    ) -> AgentDecision {
        guard scope.allows(call.tool) else { return .deny }
        let base = baseDecision(
            for: call.tool, rules: rules, mcpTrust: mcpTrust, isGranted: scope.grants(call.tool))
        guard base != .deny else { return .deny }
        var decision = base
        if call.tool == .shell, let command = call.command {
            decision = shellDecision(for: command, base: base, rules: rules.shellRules)
        } else if call.tool.usesPathRules, !call.paths.isEmpty {
            decision = pathDecision(for: call, base: base, rules: rules.pathRules)
            if call.tool == .openItems { decision = min(decision, base) }
        }
        let decided = applying(scope.mode, to: decision, for: call)
        return call.isLocalNetwork ? min(decided, .ask) : decided
    }

    /// A call whose bare decision is Deny is never shown to the model, whatever its patterns say.
    static func isOffered(
        _ call: AgentCall, rules: AgentRules, mcpTrust: (String) -> AgentDecision,
        scope: AgentSessionScope
    ) -> Bool {
        decision(for: call, rules: rules, mcpTrust: mcpTrust, scope: scope) != .deny
    }

    /// A bare row; in Plan an MCP row is a call without the read-only hint, so it is refused.
    static func isOffered(
        _ tool: AgentTool, rules: AgentRules, mcpTrust: (String) -> AgentDecision,
        scope: AgentSessionScope
    ) -> Bool {
        isOffered(AgentCall(tool: tool), rules: rules, mcpTrust: mcpTrust, scope: scope)
    }

    /// Answers without the table, which has no row for them; Use Tools off still offers none.
    static func isOffered(_ tool: AgentChatTool, scope: AgentSessionScope) -> Bool {
        guard scope.isEnabled else { return false }
        switch tool {
        case .askUser: return true
        case .writePlan: return scope.mode == .plan
        }
    }

    static func offered(
        _ tools: [AgentTool], rules: AgentRules, mcpTrust: (String) -> AgentDecision,
        scope: AgentSessionScope
    ) -> [AgentTool] {
        tools.filter { isOffered($0, rules: rules, mcpTrust: mcpTrust, scope: scope) }
    }

    /// One tool a turn is offered and what a bare call to it does, as the context card lists it.
    struct ToolDecision: Equatable, Sendable {
        let tool: AgentTool
        let decision: AgentDecision
    }

    /// In the order given, leaving out every call the turn is not offered.
    static func decisions(
        for calls: [AgentCall], rules: AgentRules, mcpTrust: (String) -> AgentDecision,
        scope: AgentSessionScope
    ) -> [ToolDecision] {
        calls.compactMap { call in
            let decision = decision(for: call, rules: rules, mcpTrust: mcpTrust, scope: scope)
            return decision == .deny ? nil : ToolDecision(tool: call.tool, decision: decision)
        }
    }

    /// The pattern "Always Allow" proposes: one plain command's first word, then ` *`.
    static func suggestedPattern(for command: String) -> String? {
        guard let segments = ShellCommandSegments.segments(of: command), segments.count == 1
        else { return nil }
        let word = ShellCommandSegments.leadingWord(of: segments[0])
        guard !word.contains("/"), !neverSuggested.contains(word) else { return nil }
        return word + " *"
    }

    /// What file "Always Allow" proposes: the folder holding `path`, or `path` itself, then `/**`.
    static func suggestedPathPattern(
        for path: String, homeDirectory: String, seeds: [PathRule] = PathRule.seeds,
        isFolder: Bool = false
    ) -> String? {
        guard let path = PathRule.canonical(path, homeDirectory: homeDirectory),
            let home = PathRule.canonical(homeDirectory, homeDirectory: homeDirectory)
        else { return nil }
        let folder = isFolder ? path : (path as NSString).deletingLastPathComponent
        // Lowercased, as matching is: `/users/**` would cover `/Users/me` just the same.
        let (lowerFolder, lowerHome) = (folder.lowercased(), home.lowercased())
        guard lowerFolder != "/", lowerFolder != lowerHome, !lowerHome.hasPrefix(lowerFolder + "/")
        else { return nil }
        let isSeeded = seeds.contains { seed in
            seed.decision == .deny
                && (seed.matches(folder, homeDirectory: homeDirectory)
                    || seed.matches(path, homeDirectory: homeDirectory))
        }
        guard !isSeeded else { return nil }
        let spelled =
            lowerFolder.hasPrefix(lowerHome + "/") ? "~" + folder.dropFirst(home.count) : folder
        return spelled + "/**"
    }

    /// Auto confirms every Ask; Plan lets only reads through, and asks before every command.
    private static func applying(
        _ mode: AgentMode, to decision: AgentDecision, for call: AgentCall
    ) -> AgentDecision {
        guard decision != .deny else { return .deny }
        switch mode {
        case .manual: return decision
        case .auto: return .allow
        case .plan:
            if call.tool == .shell { return .ask }
            return call.isReadOnly ? decision : .deny
        }
    }

    /// A grant answers only an Ask, so it never lifts a Deny.
    private static func baseDecision(
        for tool: AgentTool, rules: AgentRules, mcpTrust: (String) -> AgentDecision,
        isGranted: Bool
    ) -> AgentDecision {
        let decision: AgentDecision
        if case .mcp(let slug) = tool {
            decision = mcpTrust(slug)
        } else {
            decision = rules.decision(for: tool) ?? .deny
        }
        guard decision == .ask else { return decision }
        guard tool.canAsk else { return .deny }
        return isGranted ? .allow : .ask
    }

    /// The narrowest segment decides the command.
    private static func shellDecision(
        for command: String, base: AgentDecision, rules: [ShellRule]
    ) -> AgentDecision {
        guard let segments = ShellCommandSegments.segments(of: command) else {
            return min(base, .ask)
        }
        return segments.map { segmentDecision(for: $0, base: base, rules: rules) }.min()
            ?? min(base, .ask)
    }

    /// The narrowest path decides; one that is not absolute cannot be weighed, so it asks.
    private static func pathDecision(
        for call: AgentCall, base: AgentDecision, rules: [PathRule]
    ) -> AgentDecision {
        let applying = rules.filter { $0.applies(to: call.tool) }
        return call.paths.map { path in
            guard PathRule.canonical(path, homeDirectory: call.homeDirectory) != nil else {
                return min(base, .ask)
            }
            let matching = applying.filter { $0.matches(path, homeDirectory: call.homeDirectory) }
            if matching.contains(where: { $0.decision == .deny }) { return .deny }
            return matching.first?.decision ?? base
        }.min() ?? base
    }

    /// Any matching Deny wins, so no Allow placed above it can shadow it; else the first match.
    private static func segmentDecision(
        for segment: String, base: AgentDecision, rules: [ShellRule]
    ) -> AgentDecision {
        let matching = rules.filter { $0.matches(segment) }
        if matching.contains(where: { $0.decision == .deny }) { return .deny }
        return matching.first?.decision ?? base
    }
}
