import Foundation

/// What a running turn is waiting on the reader for; a turn that needs nobody has none.
enum AgentWait: Equatable, Sendable {
    /// An Ask request, still waiting its turn or with its dialog up.
    case approval
    /// An `ask_user` question.
    case answer

    /// An approval wins: its dialog, not the card, is what stands before the turn's next call.
    static func of(isStreaming: Bool, pendingApprovals: Int, hasQuestion: Bool) -> AgentWait? {
        guard isStreaming else { return nil }
        if pendingApprovals > 0 { return .approval }
        return hasQuestion ? .answer : nil
    }

    var symbol: String {
        switch self {
        case .approval: "hand.raised.fill"
        case .answer: "questionmark.bubble.fill"
        }
    }

    var label: String {
        switch self {
        case .approval: "Waiting for approval"
        case .answer: "Waiting for an answer"
        }
    }
}
