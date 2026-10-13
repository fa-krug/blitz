import Foundation

/// One row of the agent's rule table: a built-in tool group, or an MCP server by its slug.
enum AgentTool: Hashable, Sendable {
    case shell
    case calendarRead
    case calendarWrite
    case remindersRead
    case remindersWrite
    case webSearch
    case mcp(String)

    /// The rows `AgentRules` stores itself, in Settings order; MCP rows live on their servers.
    static let builtIn: [AgentTool] = [
        .shell, .calendarRead, .calendarWrite, .remindersRead, .remindersWrite, .webSearch
    ]

    /// Keyed by the catalogs' wire names, which this layer cannot import; the harness pins them.
    private static let builtInToolNames: [String: AgentTool] = [
        "shell_run_command": .shell,
        "calendar_list_events": .calendarRead,
        "calendar_create_event": .calendarWrite,
        "reminders_list": .remindersRead,
        "reminders_create": .remindersWrite,
        "reminders_update": .remindersWrite,
        "reminders_complete": .remindersWrite
    ]

    init?(builtInToolName name: String) {
        guard let tool = Self.builtInToolNames[name] else { return nil }
        self = tool
    }

    var title: String {
        switch self {
        case .shell: "Run Commands"
        case .calendarRead: "Read Calendar"
        case .calendarWrite: "Add Calendar Events"
        case .remindersRead: "Read Reminders"
        case .remindersWrite: "Change Reminders"
        case .webSearch: "Web Search"
        case .mcp(let slug): slug
        }
    }

    var symbolName: String {
        switch self {
        case .shell: "terminal"
        case .calendarRead: "calendar"
        case .calendarWrite: "calendar.badge.plus"
        case .remindersRead: "checklist"
        case .remindersWrite: "checklist.checked"
        case .webSearch: "globe"
        case .mcp: "wrench.and.screwdriver"
        }
    }

    /// The provider runs a web search itself, so Blitz never sees a call it could stop to ask.
    var canAsk: Bool { self != .webSearch }
}

extension AgentTool: Codable {
    private static let mcpPrefix = "mcp:"

    private var storageKey: String {
        switch self {
        case .shell: "shell"
        case .calendarRead: "calendarRead"
        case .calendarWrite: "calendarWrite"
        case .remindersRead: "remindersRead"
        case .remindersWrite: "remindersWrite"
        case .webSearch: "webSearch"
        case .mcp(let slug): Self.mcpPrefix + slug
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        if key.hasPrefix(Self.mcpPrefix) {
            self = .mcp(String(key.dropFirst(Self.mcpPrefix.count)))
            return
        }
        guard let tool = Self.builtIn.first(where: { $0.storageKey == key }) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "No agent tool is stored as \(key).")
        }
        self = tool
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }
}
