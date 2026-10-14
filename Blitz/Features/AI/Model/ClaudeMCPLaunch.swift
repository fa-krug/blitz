import Foundation

/// Blitz's servers as Claude's own MCP configuration: a file, since argv shows in `ps`.
enum ClaudeMCPLaunch {
    static let toolPrefix = "mcp__"
    /// The one built-in a turn is ever handed, and only while the chat's web search is on.
    static let searchTool = "WebSearch"
    /// Per turn, so a second turn never overwrites or deletes a live turn's configuration.
    static func configurationFileName(_ id: UUID = UUID()) -> String {
        "blitz-mcp-\(id.uuidString).json"
    }
    private static let separator = "__"

    static func configuration(servers: [AIToolServer], hosting: Bool = false) -> String {
        var entries: [String: Any] = [:]
        if hosting {
            entries[ClaudeHostedServer.handle] = [
                "type": "sdk", "name": ClaudeHostedServer.handle,
                "timeout": ClaudeHostedServer.callTimeoutMilliseconds
            ]
        }
        for server in servers {
            switch server.transport {
            case .command(let path, let arguments, let environment):
                entries[server.handle] = [
                    "command": path, "args": arguments, "env": environment
                ]
            case .url(let url, let headerName, let headerValue):
                var entry: [String: Any] = ["type": "http", "url": url]
                if !headerValue.isEmpty { entry["headers"] = [headerName: headerValue] }
                entries[server.handle] = entry
            }
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["mcpServers": entries], options: [.sortedKeys]),
            let text = String(bytes: data, encoding: .utf8)
        else { return #"{"mcpServers":{}}"# }
        return text
    }

    /// The flags that arm the servers; `--disallowedTools *` would take the MCP tools with it.
    static func arguments(
        configurationPath: String, handles: [String], rounds: Int?, allowing: [String] = []
    ) -> [String] {
        var result = [
            "--strict-mcp-config",
            "--mcp-config", configurationPath,
            "--permission-prompt-tool", "stdio",
            "--permission-mode", "default",
            "--settings", askSettings(handles: handles, allowing: allowing)
        ]
        // Claude has no turn cap of its own, so no flag is what Unlimited means.
        if let rounds { result += ["--max-turns", "\(rounds)"] }
        return result
    }

    /// An ask rule outranks the reader's allow rules, so their settings never pre-approve a call.
    static func askSettings(handles: [String], allowing: [String] = []) -> String {
        var permissions: [String: Any] = ["ask": handles.map { toolPrefix + $0 }]
        // A built-in would reach the consent channel, which refuses anything not an MCP call.
        if !allowing.isEmpty { permissions["allow"] = allowing }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["permissions": permissions], options: [.sortedKeys]),
            let text = String(bytes: data, encoding: .utf8)
        else { return #"{"permissions":{"ask":[]}}"# }
        return text
    }

    /// `mcp__<handle>__<tool>` back to Blitz's pair; a handle never holds `__`, a tool may.
    static func route(_ wireName: String) -> AIToolServerCall? {
        guard wireName.hasPrefix(toolPrefix) else { return nil }
        let rest = wireName.dropFirst(toolPrefix.count)
        guard let separator = rest.range(of: Self.separator) else { return nil }
        let handle = String(rest[..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        guard !handle.isEmpty, !tool.isEmpty else { return nil }
        return AIToolServerCall(handle: handle, tool: tool)
    }
}
