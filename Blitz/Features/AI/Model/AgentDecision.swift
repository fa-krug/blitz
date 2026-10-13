import Foundation

/// What the agent's rules say about one tool call, ordered so `min` is the narrower of two.
enum AgentDecision: String, CaseIterable, Codable, Comparable, Identifiable, Sendable {
    case deny
    case ask
    case allow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deny: "Deny"
        case .ask: "Ask"
        case .allow: "Allow"
        }
    }

    private var rank: Int {
        switch self {
        case .deny: 0
        case .ask: 1
        case .allow: 2
        }
    }

    static func < (lhs: AgentDecision, rhs: AgentDecision) -> Bool {
        lhs.rank < rhs.rank
    }
}
