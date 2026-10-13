import Foundation

/// A runner's question to the gate once a call has been read; it answers nil or a refusal to send.
typealias AgentAuthorization = @MainActor @Sendable (AgentPrompt) async -> String?

/// What an Ask dialog says about one call, and the answers it offers; the last one refuses.
struct AgentPrompt: Equatable, Sendable {
    enum Choice: Equatable, Sendable {
        case allowOnce(String)
        /// An Allow rule for the pattern, placed where it decides the command that asked.
        case alwaysAllowCommands(pattern: String)
        /// Raises the MCP server's own trust, as its dialog always has.
        case alwaysAllowServer
        case allowThisChat
        case refuse(String)

        var title: String {
            switch self {
            case .allowOnce(let title), .refuse(let title): title
            case .alwaysAllowCommands(let pattern): "Always Allow \u{201C}\(pattern)\u{201D}"
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
