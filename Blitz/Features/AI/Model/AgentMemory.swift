import Foundation

/// One thing the user asked the agent to remember; its number is never reused, so `m3` stays put.
struct AgentMemory: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    var text: String
    let createdAt: Date
    /// Informational only: deleting that chat keeps what was remembered in it.
    let sourceConversation: UUID?

    static let textLimit = 500
    static let countLimit = 100
    /// UTF-8 bytes of text across every memory, since all of them ride in each turn.
    static let byteLimit = 12 * 1024

    /// The id the model sees in its instructions and names to `memory_forget`.
    var handle: String { "m\(id)" }

    /// Whether a text may join the memories, as the tool and Settings both ask it.
    enum Admission: Equatable, Sendable {
        /// The text as it would be stored.
        case accepted(String)
        case empty
        case tooLong(Int)
        case duplicate(AgentMemory)
        case full
    }

    /// One line with runs of whitespace collapsed, since each memory is one bullet of a turn.
    static func cleaned(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Two texts are one memory once case and whitespace are set aside.
    static func key(_ text: String) -> String {
        cleaned(text).lowercased()
    }

    /// `m3`, `M3` or a bare `3`.
    static func id(fromHandle handle: String) -> Int? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.lowercased().hasPrefix("m") ? trimmed.dropFirst() : trimmed[...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let id = Int(digits), id > 0 else {
            return nil
        }
        return id
    }

    /// `replacing` names an edit's memory, so it is neither its own twin nor counted twice.
    static func admission(
        of text: String, into memories: [AgentMemory], replacing id: Int? = nil
    ) -> Admission {
        let cleaned = cleaned(text)
        guard !cleaned.isEmpty else { return .empty }
        guard cleaned.count <= textLimit else { return .tooLong(cleaned.count) }
        let others = memories.filter { $0.id != id }
        let key = key(cleaned)
        if let twin = others.first(where: { Self.key($0.text) == key }) { return .duplicate(twin) }
        let bytes = others.reduce(cleaned.utf8.count) { $0 + $1.text.utf8.count }
        guard others.count < countLimit, bytes <= byteLimit else { return .full }
        return .accepted(cleaned)
    }
}
