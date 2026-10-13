import Foundation

/// Why the gate stopped a call: a sentence the model reads as the call's answer, never a dialog.
enum AgentRefusal: Equatable, Sendable {
    /// The rules, a feature switch or the chat's tools menu say no.
    case denied
    /// The reader answered the dialog with no.
    case declined

    func message(for tool: AgentTool) -> String {
        switch self {
        case .denied: "Blitz's agent rules do not let the model \(Self.action(of: tool))."
        case .declined: "The user declined to let the model \(Self.action(of: tool))."
        }
    }

    private static func action(of tool: AgentTool) -> String {
        switch tool {
        case .shell: "run this command"
        case .calendarRead: "read the calendar"
        case .calendarWrite: "add this event"
        case .remindersRead: "read reminders"
        case .remindersWrite: "change reminders"
        case .webSearch: "search the web"
        case .mcp: "call this server's tools"
        }
    }
}
