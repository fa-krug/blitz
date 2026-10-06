import Foundation

/// The user's own search terms per base glyph: what Edit Keywords takes and the store keeps.
enum EmojiKeywords {
    /// These bound a malformed, hand-edited or imported file, never what a person types.
    static let glyphCap = 3_000
    static let termCap = 32
    static let termLengthCap = 64

    /// Comma-separated, as the dialog takes them.
    static func terms(from input: String) -> [String] {
        normalized(input.split(separator: ",").map(String.init))
    }

    static func input(for terms: [String]) -> String {
        terms.joined(separator: ", ")
    }

    /// Whitespace collapses; a term repeated in another case or accent keeps its first spelling.
    static func normalized(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for term in terms {
            let collapsed = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let bounded = String(collapsed.prefix(termLengthCap))
            guard !bounded.isEmpty, !bounded.contains(","),
                seen.insert(bounded.folding(options: folding, locale: nil)).inserted
            else { continue }
            result.append(bounded)
            if result.count == termCap { break }
        }
        return result
    }

    /// A glyph left with no terms has no entry, so the count is the emoji the user has given terms.
    static func normalized(_ keywords: [String: [String]]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for glyph in keywords.keys.sorted() where !glyph.isEmpty {
            let terms = normalized(keywords[glyph] ?? [])
            guard !terms.isEmpty else { continue }
            result[glyph] = terms
            if result.count == glyphCap { break }
        }
        return result
    }

    private static let folding: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive
    ]
}
