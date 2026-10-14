import Foundation

/// A runner's question to the gate once a call has been read; it answers nil or a refusal to send.
typealias AgentAuthorization = @MainActor @Sendable (AgentPrompt) async -> String?

/// What an Ask dialog says about one call, and the answers it offers; the last one refuses.
struct AgentPrompt: Equatable, Sendable {
    enum Choice: Equatable, Sendable {
        case allowOnce(String)
        /// An Allow rule for the pattern, placed where it decides the command that asked.
        case alwaysAllowCommands(pattern: String)
        /// A path rule for the folder, placed where it decides the call that asked.
        case alwaysAllowPaths(pattern: String)
        /// Raises the MCP server's own trust, as its dialog always has.
        case alwaysAllowServer
        case allowThisChat
        case refuse(String)

        var title: String {
            switch self {
            case .allowOnce(let title), .refuse(let title): title
            case .alwaysAllowCommands(let pattern), .alwaysAllowPaths(let pattern):
                "Always Allow \u{201C}\(pattern)\u{201D}"
            case .alwaysAllowServer: "Always Allow"
            case .allowThisChat: "Allow This Chat"
            }
        }

        var allows: Bool {
            if case .refuse = self { return false }
            return true
        }
    }

    let title: String
    let message: String?
    let symbol: String
    let choices: [Choice]
    let defaultIndex: Int

    /// `summary` is the command verbatim and where it runs; Escape is Don't Run, never a rule.
    static func shell(command: String, summary: String) -> AgentPrompt {
        let always = AgentPolicy.suggestedPattern(for: command).map {
            Choice.alwaysAllowCommands(pattern: $0)
        }
        return AgentPrompt(
            title: "Run this command?", message: summary, symbol: AgentTool.shell.symbolName,
            choices: [.allowOnce("Run")] + (always.map { [$0] } ?? []) + [.refuse("Don't Run")],
            defaultIndex: 0)
    }

    /// A change the reader sees spelled out before it lands, such as a new event.
    static func write(title: String, message: String?, symbol: String) -> AgentPrompt {
        AgentPrompt(
            title: title, message: message, symbol: symbol,
            choices: [.allowOnce("Allow"), .refuse("Don't Allow")], defaultIndex: 0)
    }

    static func read(_ tool: AgentTool) -> AgentPrompt {
        let subject =
            switch tool {
            case .calendarRead: "your calendar"
            case .remindersRead: "your reminders"
            default: tool.title
            }
        return AgentPrompt(
            title: "Let the agent read \(subject)?",
            message: "What it reads is sent to the model's provider.", symbol: tool.symbolName,
            choices: [.allowOnce("Allow"), .allowThisChat, .refuse("Don't Allow")],
            defaultIndex: 0)
    }

    /// A personal or context read, which Allow This Chat may answer; `detail` says what it sees.
    static func read(_ tool: AgentTool, title: String, detail: String?) -> AgentPrompt {
        let provider = "What it reads is sent to the model\u{2019}s provider."
        return AgentPrompt(
            title: title, message: detail.map { "\($0) \(provider)" } ?? provider,
            symbol: tool.symbolName,
            choices: [.allowOnce("Allow"), .allowThisChat, .refuse("Don't Allow")],
            defaultIndex: 0)
    }

    static func searchContacts(_ query: String) -> AgentPrompt {
        read(
            .contactsRead,
            title: "Let the agent search your contacts for \u{201C}\(query)\u{201D}?",
            detail: "It sees each match\u{2019}s name, company, email addresses, phone numbers, "
                + "postal addresses and birthday, never its notes or photo.")
    }

    static func readNote(_ title: String) -> AgentPrompt {
        read(
            .noteRead, title: "Let the agent read your note?",
            detail: "It reads \u{201C}\(title)\u{201D}.")
    }

    /// The text is shown as sent, clipped, since it lands in the reader's own note.
    static func appendToNote(_ title: String, text: String) -> AgentPrompt {
        write(
            title: "Let the agent add to your note?",
            message: "It adds this on a new line at the end of \u{201C}\(title)\u{201D}:\n"
                + AIToolJSON.clipped(text, to: 300),
            symbol: AgentTool.noteWrite.symbolName)
    }

    static func readClipboardHistory(query: String?, limit: Int) -> AgentPrompt {
        let matching = query.map { " that contain \u{201C}\($0)\u{201D}" } ?? ""
        let copies = limit == 1 ? "your latest copy" : "up to \(limit) of your latest copies"
        return read(
            .clipboardRead, title: "Let the agent read your clipboard history?",
            detail: "It sees \(copies)\(matching), with when and where each was copied; of an "
                + "image, only its size.")
    }

    /// One snippet by name, or the list of them.
    static func readSnippets(_ name: String?) -> AgentPrompt {
        guard let name else {
            return read(
                .snippetsRead, title: "Let the agent list your snippets?",
                detail: "It sees each snippet\u{2019}s name, keyword and the start of its text.")
        }
        return read(
            .snippetsRead, title: "Let the agent read the snippet \u{201C}\(name)\u{201D}?",
            detail: nil)
    }

    static func readQuicklinks() -> AgentPrompt {
        read(
            .snippetsRead, title: "Let the agent list your quicklinks?",
            detail: "It sees each quicklink\u{2019}s name and link.")
    }

    static func seeFrontmostApp(_ app: String) -> AgentPrompt {
        read(
            .frontmostApp, title: "Let the agent see that you are using \(app)?",
            detail: "It sees the app\u{2019}s name and bundle identifier, and the title of its "
                + "front window.")
    }

    static func readSelectedText(in app: String) -> AgentPrompt {
        read(.selectedText, title: "Let the agent read the text selected in \(app)?", detail: nil)
    }

    /// `summary` names what is on the clipboard, never its content.
    static func readClipboard(_ summary: String) -> AgentPrompt {
        read(
            .currentClipboard, title: "Let the agent read the clipboard?",
            detail: "It reads what you copied last: \(summary).")
    }

    /// A file call: a read may be allowed for the chat, and either may allow its folder for good.
    static func files(
        _ tool: AgentTool, title: String, message: String?, pattern: String?
    ) -> AgentPrompt {
        let chat: [Choice] = tool.canAllowForSession ? [.allowThisChat] : []
        let always = pattern.map { [Choice.alwaysAllowPaths(pattern: $0)] } ?? []
        return AgentPrompt(
            title: title, message: message, symbol: tool.symbolName,
            choices: [.allowOnce("Allow")] + chat + always + [.refuse("Don't Allow")],
            defaultIndex: 0)
    }

    /// A page to fetch; one on the local network is asked each time, never for the whole chat.
    static func webFetch(host: String, url: String, isLocalNetwork: Bool) -> AgentPrompt {
        let local = isLocalNetwork ? " This address is on this Mac or its local network." : ""
        let chat: [Choice] = isLocalNetwork ? [] : [.allowThisChat]
        return AgentPrompt(
            title: "Let the agent open \(host)?",
            message: "\(url)\n\nWhat it reads is sent to the model\u{2019}s provider.\(local)",
            symbol: AgentTool.webFetch.symbolName,
            choices: [.allowOnce("Allow")] + chat + [.refuse("Don't Allow")], defaultIndex: 0)
    }

    /// The chat list, or one chat by its title; either may be allowed for the whole chat.
    static func sessions(reading title: String?) -> AgentPrompt {
        let provider = "What it reads is sent to the model\u{2019}s provider."
        return AgentPrompt(
            title: title.map { "Let the agent read your chat \u{201C}\($0)\u{201D}?" }
                ?? "Let the agent list your chats?",
            message: title == nil
                ? "It sees each chat\u{2019}s title, when it was last used and how long it is, "
                    + "and can search their last messages. " + provider
                : provider,
            symbol: AgentTool.sessionsRead.symbolName,
            choices: [.allowOnce("Allow"), .allowThisChat, .refuse("Don't Allow")],
            defaultIndex: 0)
    }

    /// Asked each time: archiving moves a chat out of the reader's sidebar.
    static func archive(title: String, archiving: Bool) -> AgentPrompt {
        write(
            title: archiving
                ? "Let the agent archive \u{201C}\(title)\u{201D}?"
                : "Let the agent unarchive \u{201C}\(title)\u{201D}?",
            message: archiving
                ? "It moves to Archived at the bottom of the sidebar, where it can be opened again."
                : "It goes back to the sidebar.",
            symbol: AgentTool.sessionsArchive.symbolName)
    }

    /// An app, a path or a link; `subject` is how the title names it.
    static func open(_ subject: String, detail: String) -> AgentPrompt {
        write(
            title: "Let the agent open \(subject)?", message: detail,
            symbol: AgentTool.openItems.symbolName)
    }

    /// The input is shown as sent, clipped, since the shortcut acts on it.
    static func runShortcut(_ name: String, input: String?) -> AgentPrompt {
        let given = input.map { "With this input:\n\(AIToolJSON.clipped($0, to: 300))\n\n" } ?? ""
        return write(
            title: "Let the agent run the shortcut \u{201C}\(name)\u{201D}?",
            message: given + "It can do anything its actions do, and what it returns is sent to "
                + "the model\u{2019}s provider.",
            symbol: AgentTool.shortcuts.symbolName)
    }

    static func runSystemAction(_ name: String) -> AgentPrompt {
        write(
            title: "Let the agent run \u{201C}\(name)\u{201D}?",
            message: "Blitz runs it as if you chose it in the launcher.",
            symbol: AgentTool.systemActions.symbolName)
    }

    /// `summary` says how many windows on how many displays, as the layout's row does.
    static func applyWindowLayout(_ name: String, summary: String) -> AgentPrompt {
        write(
            title: "Let the agent apply the window layout \u{201C}\(name)\u{201D}?",
            message: "\(summary). It opens the apps it names that are not running, then moves "
                + "and resizes their windows.",
            symbol: AgentTool.windowLayouts.symbolName)
    }

    /// The server's own three-way question; only Settings can withhold a server for good.
    static func mcp(serverTitle: String, tool: String) -> AgentPrompt {
        AgentPrompt(
            title: "Let \(serverTitle) run its tools?",
            message: "The model wants to call \u{201C}\(tool)\u{201D}. Blitz did not write this "
                + "server and cannot vouch for what it does.",
            symbol: AgentTool.mcp("").symbolName,
            choices: [.alwaysAllowServer, .allowThisChat, .refuse("Don't Allow")],
            defaultIndex: 1)
    }
}
