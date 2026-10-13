import Foundation

/// A server's row for one chat: its standing trust, with an Ask this chat already answered.
enum MCPTrustPolicy {
    static func decide(trust: MCPTrust, isGrantedForChat: Bool) -> AgentDecision {
        trust == .ask && isGrantedForChat ? .allow : trust.decision
    }
}
