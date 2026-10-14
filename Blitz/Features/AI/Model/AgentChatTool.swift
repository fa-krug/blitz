import Foundation

/// A tool that only talks to the chat, so it has no rule row: asking the reader is no capability.
enum AgentChatTool: CaseIterable, Sendable {
    /// Asks the reader a question and waits for the answer.
    case askUser
    /// Writes the chat's plan, replacing the last one.
    case writePlan
}
