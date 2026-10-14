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
        case .filesRead: "read this file or folder"
        case .filesWrite: "change this file or folder"
        case .webSearch: "search the web"
        case .webFetch: "fetch this page"
        case .openItems: "open this"
        case .shortcuts: "run this shortcut"
        case .systemActions: "run this system action"
        case .windowLayouts: "apply this window layout"
        case .calendarRead: "read the calendar"
        case .calendarWrite: "add this event"
        case .remindersRead: "read reminders"
        case .remindersWrite: "change reminders"
        case .contactsRead: "read contacts"
        case .noteRead: "read the note"
        case .noteWrite: "add to the note"
        case .clipboardRead: "read clipboard history"
        case .snippetsRead: "read snippets and quicklinks"
        case .frontmostApp: "see the frontmost app"
        case .selectedText: "read the selected text"
        case .currentClipboard: "read the clipboard"
        case .sessionsRead: "read the user's other chats"
        case .sessionsArchive: "archive or unarchive this chat"
        case .memoryRead: "read its memory"
        case .memoryWrite: "change its memory"
        case .mcp: "call this server's tools"
        }
    }
}
