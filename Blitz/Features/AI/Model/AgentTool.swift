import Foundation

/// One row of the agent's rule table: a built-in tool group, or an MCP server by its slug.
enum AgentTool: Hashable, Sendable {
    case shell
    case filesRead
    case filesWrite
    case webSearch
    case webFetch
    case openItems
    case shortcuts
    case systemActions
    case windowLayouts
    case calendarRead
    case calendarWrite
    case remindersRead
    case remindersWrite
    case contactsRead
    case noteRead
    case noteWrite
    case clipboardRead
    case snippetsRead
    case frontmostApp
    case selectedText
    case currentClipboard
    case mcp(String)

    /// Where Settings lists a built-in row, in Settings order.
    enum Group: CaseIterable, Sendable {
        case commands, files, web, mac, calendarAndReminders, personal, context

        var title: String {
            switch self {
            case .commands: "Commands"
            case .files: "Files"
            case .web: "Web"
            case .mac: "Mac"
            case .calendarAndReminders: "Calendar & Reminders"
            case .personal: "Personal"
            case .context: "Context"
            }
        }

        var tools: [AgentTool] { AgentTool.builtIn.filter { $0.group == self } }
    }

    /// The rows `AgentRules` stores itself, in Settings order; MCP rows live on their servers.
    static let builtIn: [AgentTool] = [
        .shell,
        .filesRead, .filesWrite,
        .webSearch, .webFetch,
        .openItems, .shortcuts, .systemActions, .windowLayouts,
        .calendarRead, .calendarWrite, .remindersRead, .remindersWrite,
        .contactsRead, .noteRead, .noteWrite, .clipboardRead, .snippetsRead,
        .frontmostApp, .selectedText, .currentClipboard
    ]

    /// Keyed by the catalogs' wire names, which this layer cannot import; the harness pins them.
    private static let builtInToolNames: [String: AgentTool] = [
        "shell_run_command": .shell,
        "files_list": .filesRead,
        "files_read": .filesRead,
        "files_write": .filesWrite,
        "files_move": .filesWrite,
        "files_trash": .filesWrite,
        "calendar_list_events": .calendarRead,
        "calendar_create_event": .calendarWrite,
        "reminders_list": .remindersRead,
        "reminders_create": .remindersWrite,
        "reminders_update": .remindersWrite,
        "reminders_complete": .remindersWrite
    ]

    private static let hostedRows = Set(builtInToolNames.values)

    init?(builtInToolName name: String) {
        guard let tool = Self.builtInToolNames[name] else { return nil }
        self = tool
    }

    /// Whether Blitz serves the model a tool under this row; a row with no wire name has no runner.
    var isHosted: Bool { Self.hostedRows.contains(self) }

    /// Nil for an MCP server, which Settings lists beneath the built-in groups.
    var group: Group? {
        switch self {
        case .shell: .commands
        case .filesRead, .filesWrite: .files
        case .webSearch, .webFetch: .web
        case .openItems, .shortcuts, .systemActions, .windowLayouts: .mac
        case .calendarRead, .calendarWrite, .remindersRead, .remindersWrite: .calendarAndReminders
        case .contactsRead, .noteRead, .noteWrite, .clipboardRead, .snippetsRead: .personal
        case .frontmostApp, .selectedText, .currentClipboard: .context
        case .mcp: nil
        }
    }

    var title: String {
        switch self {
        case .shell: "Run Commands"
        case .filesRead: "Read Files"
        case .filesWrite: "Change Files"
        case .webSearch: "Web Search"
        case .webFetch: "Fetch Web Pages"
        case .openItems: "Open Apps, Files and Links"
        case .shortcuts: "Run Shortcuts"
        case .systemActions: "Run System Actions"
        case .windowLayouts: "Apply Window Layouts"
        case .calendarRead: "Read Calendar"
        case .calendarWrite: "Add Calendar Events"
        case .remindersRead: "Read Reminders"
        case .remindersWrite: "Change Reminders"
        case .contactsRead: "Read Contacts"
        case .noteRead: "Read the Note"
        case .noteWrite: "Add to the Note"
        case .clipboardRead: "Read Clipboard History"
        case .snippetsRead: "Read Snippets and Quicklinks"
        case .frontmostApp: "See the Frontmost App"
        case .selectedText: "Read Selected Text"
        case .currentClipboard: "Read the Clipboard"
        case .mcp(let slug): slug
        }
    }

    var symbolName: String {
        switch self {
        case .shell: "terminal"
        case .filesRead: "doc.text.magnifyingglass"
        case .filesWrite: "doc.badge.gearshape"
        case .webSearch: "globe"
        case .webFetch: "network"
        case .openItems: "arrow.up.forward.app"
        case .shortcuts: "square.2.layers.3d"
        case .systemActions: "bolt"
        case .windowLayouts: "macwindow"
        case .calendarRead: "calendar"
        case .calendarWrite: "calendar.badge.plus"
        case .remindersRead: "checklist"
        case .remindersWrite: "checklist.checked"
        case .contactsRead: "person.crop.circle"
        case .noteRead: "note.text"
        case .noteWrite: "note.text.badge.plus"
        case .clipboardRead: "doc.on.clipboard"
        case .snippetsRead: "curlybraces"
        case .frontmostApp: "macwindow.on.rectangle"
        case .selectedText: "selection.pin.in.out"
        case .currentClipboard: "clipboard"
        case .mcp: "wrench.and.screwdriver"
        }
    }

    /// The provider runs a web search itself, so Blitz never sees a call it could stop to ask.
    var canAsk: Bool { self != .webSearch }

    /// Whether every call under the row only looks; a server's row cannot say it for all its tools.
    var isReadOnly: Bool {
        switch self {
        case .filesRead, .webSearch, .webFetch, .calendarRead, .remindersRead, .contactsRead,
            .noteRead, .clipboardRead, .snippetsRead, .frontmostApp, .selectedText,
            .currentClipboard:
            true
        case .shell, .filesWrite, .openItems, .shortcuts, .systemActions, .windowLayouts,
            .calendarWrite, .remindersWrite, .noteWrite, .mcp:
            false
        }
    }

    /// Whether an Ask may be answered for the whole chat; a write or a command is asked each time.
    var canAllowForSession: Bool {
        switch self {
        case .mcp: true
        default: isReadOnly && canAsk
        }
    }

    /// The rows whose calls name paths, which `AgentRules.pathRules` then weighs one by one.
    var usesPathRules: Bool { self == .filesRead || self == .filesWrite }
}

extension AgentTool: Codable {
    private static let mcpPrefix = "mcp:"

    /// The row's key in a stored table too, so renaming a case never renames what is stored.
    var storageKey: String {
        switch self {
        case .shell: "shell"
        case .filesRead: "filesRead"
        case .filesWrite: "filesWrite"
        case .webSearch: "webSearch"
        case .webFetch: "webFetch"
        case .openItems: "openItems"
        case .shortcuts: "shortcuts"
        case .systemActions: "systemActions"
        case .windowLayouts: "windowLayouts"
        case .calendarRead: "calendarRead"
        case .calendarWrite: "calendarWrite"
        case .remindersRead: "remindersRead"
        case .remindersWrite: "remindersWrite"
        case .contactsRead: "contactsRead"
        case .noteRead: "noteRead"
        case .noteWrite: "noteWrite"
        case .clipboardRead: "clipboardRead"
        case .snippetsRead: "snippetsRead"
        case .frontmostApp: "frontmostApp"
        case .selectedText: "selectedText"
        case .currentClipboard: "currentClipboard"
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
