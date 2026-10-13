import Foundation

/// How a session treats the rule table's Ask; never stored, so every chat opens in Manual.
enum AgentMode: String, CaseIterable, Identifiable, Sendable {
    case manual
    case auto
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .auto: "Auto"
        case .plan: "Plan"
        }
    }

    var symbolName: String {
        switch self {
        case .manual: "hand.raised"
        case .auto: "bolt"
        case .plan: "list.bullet.clipboard"
        }
    }

    var summary: String {
        switch self {
        case .manual: "Asks before anything the agent's rules say to ask about."
        case .auto: "Runs what the rules would ask about; what they deny stays denied."
        case .plan: "Looks without changing anything, then writes a plan for you to approve."
        }
    }
}
