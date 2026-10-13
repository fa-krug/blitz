import Foundation

/// One ordered shell pattern: a glob over a whole command segment, where `*` may span spaces.
struct ShellRule: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var pattern: String
    var decision: AgentDecision

    init(id: UUID = UUID(), pattern: String, decision: AgentDecision) {
        self.id = id
        self.pattern = pattern
        self.decision = decision
    }

    /// A trailing ` *` also takes no arguments, so `ls *` covers the bare `ls` it was made from.
    func matches(_ segment: String) -> Bool {
        let pattern = Self.collapsed(pattern)
        let segment = Self.collapsed(segment)
        if pattern.hasSuffix(" *"), segment == pattern.dropLast(2) { return true }
        return Self.glob(Array(pattern.unicodeScalars), matches: Array(segment.unicodeScalars))
    }

    /// Only space and tab: the shell splits on nothing else, so neither may the matcher.
    static func collapsed(_ text: String) -> String {
        let words = text.unicodeScalars.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return words.map(String.init).joined(separator: " ")
    }

    /// Scalars, as the splitter reads them, so a combining mark cannot fuse a space into a word.
    private static func glob(_ pattern: [Unicode.Scalar], matches text: [Unicode.Scalar]) -> Bool {
        var patternIndex = 0
        var textIndex = 0
        var starIndex: Int?
        var starTextIndex = 0
        while textIndex < text.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starTextIndex = textIndex
                patternIndex += 1
            } else if patternIndex < pattern.count,
                pattern[patternIndex] == "?" || pattern[patternIndex] == text[textIndex]
            {
                patternIndex += 1
                textIndex += 1
            } else if let star = starIndex {
                patternIndex = star + 1
                starTextIndex += 1
                textIndex = starTextIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" { patternIndex += 1 }
        return patternIndex == pattern.count
    }
}
