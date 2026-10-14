import Foundation

/// One tool call as the policy weighs it: the tool, and what it acts on — a command, or paths.
struct AgentCall: Equatable, Sendable {
    let tool: AgentTool
    let command: String?
    /// Every path the call touches, a move's source and destination both; the narrowest decides.
    let paths: [String]
    /// What `~` means in a path or a pattern; only `files(_:paths:homeDirectory:)` sets it.
    let homeDirectory: String
    /// Only an MCP call sets it, from its server's `readOnlyHint` for the tool, never the model's.
    private let isReadOnlyServerTool: Bool
    /// Only a web fetch sets it: then an Allow row, a chat grant or Auto still asks; Deny denies.
    let isLocalNetwork: Bool

    init(tool: AgentTool, command: String? = nil) {
        self.init(
            tool: tool, command: command, paths: [], homeDirectory: "",
            isReadOnlyServerTool: false)
    }

    private init(
        tool: AgentTool, command: String?, paths: [String], homeDirectory: String,
        isReadOnlyServerTool: Bool, isLocalNetwork: Bool = false
    ) {
        self.tool = tool
        self.command = command
        self.paths = paths
        self.homeDirectory = homeDirectory
        self.isReadOnlyServerTool = isReadOnlyServerTool
        self.isLocalNetwork = isLocalNetwork
    }

    static func shell(_ command: String) -> AgentCall {
        AgentCall(tool: .shell, command: command)
    }

    /// Each path absolute with its symlinks resolved (`URL.resolvingSymlinksInPath()`) first.
    static func files(_ tool: AgentTool, paths: [String], homeDirectory: String) -> AgentCall {
        AgentCall(
            tool: tool, command: nil, paths: paths, homeDirectory: homeDirectory,
            isReadOnlyServerTool: false)
    }

    /// `isLocalNetwork` is `LocalNetworkPolicy`'s word on the URL, never the model's.
    static func webFetch(isLocalNetwork: Bool) -> AgentCall {
        AgentCall(
            tool: .webFetch, command: nil, paths: [], homeDirectory: "",
            isReadOnlyServerTool: false, isLocalNetwork: isLocalNetwork)
    }

    /// One tool of a server; a call without the hint is never read-only, so Plan refuses it.
    static func mcp(_ slug: String, readOnly: Bool) -> AgentCall {
        AgentCall(
            tool: .mcp(slug), command: nil, paths: [], homeDirectory: "",
            isReadOnlyServerTool: readOnly)
    }

    /// Whether the call only looks, which is all Plan mode lets through besides the shell.
    var isReadOnly: Bool { tool.isReadOnly || isReadOnlyServerTool }
}
