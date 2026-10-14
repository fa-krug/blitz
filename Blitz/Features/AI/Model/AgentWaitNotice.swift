import Foundation

/// The notification a chat posts when it starts waiting off screen; it carries no actions.
struct AgentWaitNotice: Equatable, Sendable {
    let identifier: String
    let chatID: UUID
    let title: String
    let body: String

    /// Long enough to read the question by, short enough that the chat's title is not pushed off.
    static let maxQuestionLength = 140
    static let chatKey = "agentChat"

    init(wait: AgentWait, chatID: UUID, chatTitle: String, question: String?, appName: String) {
        identifier = Self.identifier(for: chatID)
        self.chatID = chatID
        switch wait {
        case .approval:
            title = "\(appName) is waiting for approval"
            body = chatTitle
        case .answer:
            title = "\(appName) has a question"
            let asked = question.map(Self.clipped) ?? ""
            body = asked.isEmpty ? chatTitle : chatTitle + "\n" + asked
        }
    }

    /// One per chat, so a later wait replaces an earlier one rather than stacking beside it.
    static func identifier(for chatID: UUID) -> String {
        "agent-wait-" + chatID.uuidString
    }

    var userInfo: [String: String] {
        [Self.chatKey: chatID.uuidString]
    }

    static func chatID(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[chatKey] as? String).flatMap(UUID.init(uuidString:))
    }

    /// The question on one line, cut at a word where one is near the limit.
    static func clipped(_ question: String) -> String {
        let line = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > maxQuestionLength else { return line }
        let cut = line.prefix(maxQuestionLength - 1)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        let kept = word.count >= maxQuestionLength / 2 ? word : cut
        return kept.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
