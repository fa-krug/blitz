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
        let base = baseDecision(for: call.tool, rules: rules, mcpTrust: mcpTrust)
        guard base != .deny else { return .deny }
        var decision = base
        if call.tool == .shell, let command = call.command {
            decision = shellDecision(for: command, base: base, rules: rules.shellRules)
        }
        if scope.asksForEverything, call.tool.canAsk {
            decision = min(decision, .ask)
        }
        return decision
    }

    /// A tool whose bare decision is Deny is never shown to the model, whatever its patterns say.
    static func isOffered(
        _ tool: AgentTool, rules: AgentRules, mcpTrust: (String) -> AgentDecision,
        scope: AgentSessionScope
    ) -> Bool {
        decision(for: AgentCall(tool: tool), rules: rules, mcpTrust: mcpTrust, scope: scope)
            != .deny
    }

    static func offered(
        _ tools: [AgentTool], rules: AgentRules, mcpTrust: (String) -> AgentDecision,
        scope: AgentSessionScope
    ) -> [AgentTool] {
        tools.filter { isOffered($0, rules: rules, mcpTrust: mcpTrust, scope: scope) }
    }

    /// The pattern "Always Allow" proposes: one plain command's first word, then ` *`.
    static func suggestedPattern(for command: String) -> String? {
        guard let segments = ShellCommandSegments.segments(of: command), segments.count == 1
        else { return nil }
        let word = ShellCommandSegments.leadingWord(of: segments[0])
        guard !word.contains("/"), !neverSuggested.contains(word) else { return nil }
        return word + " *"
    }

    private static func baseDecision(
        for tool: AgentTool, rules: AgentRules, mcpTrust: (String) -> AgentDecision
    ) -> AgentDecision {
        let decision: AgentDecision
        if case .mcp(let slug) = tool {
            decision = mcpTrust(slug)
        } else {
            decision = rules.decision(for: tool) ?? .deny
        }
        return tool.canAsk || decision != .ask ? decision : .deny
    }

    /// Each segment takes its first matching rule, or the base; the narrowest segment decides.
    private static func shellDecision(
        for command: String, base: AgentDecision, rules: [ShellRule]
    ) -> AgentDecision {
        guard let segments = ShellCommandSegments.segments(of: command) else {
            return min(base, .ask)
        }
        return segments.map { segment in
            rules.first(where: { $0.matches(segment) })?.decision ?? base
        }.min() ?? min(base, .ask)
    }
}
