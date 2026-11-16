import Foundation

/// Fits a transcript to the text around the caret: a joining space, and the first letter's case.
enum DictationTextFormatter {
    /// The text either side of the caret, reduced to the characters the rules look at.
    struct Context: Equatable, Sendable {
        let trailing: Character?
        let lastNonWhitespace: Character?
        let newParagraph: Bool
        let following: Character?

        init(before: Substring, after: Substring) {
            trailing = before.last
            following = after.first
            var last: Character?
            var paragraph = false
            for character in before.reversed() {
                if !character.isWhitespace {
                    last = character
                    break
                }
                if character.isNewline { paragraph = true }
            }
            lastNonWhitespace = last
            newParagraph = paragraph
        }
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?"]
    /// After these the next word attaches without a space: an opening bracket, quote or dash.
    private static let openers: Set<Character> = [
        "(", "[", "{", "/", "\"", "'", "‘", "’", "“", "—", "-"
    ]
    /// These attach to the word before them, so no space goes in front.
    private static let closers: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "/", "\"", "'", "”"
    ]

    /// The longest tail of the pasted text a new chunk's head is compared against.
    private static let echoWindow = 8
    /// A repeat may start this many words in, past a fragment the cut left behind.
    private static let echoSkip = 3

    /// Drops the words a live chunk repeats from the end of what is already pasted.
    static func stripEcho(_ text: String, after previous: String) -> String {
        guard !text.isEmpty, !previous.isEmpty else { return text }
        let tail = Array(previous.split(separator: " ").suffix(echoWindow))
        let head = Array(text.split(separator: " "))
        let plain = { (word: Substring) in
            word.lowercased().trimmingCharacters(in: .alphanumerics.inverted)
        }
        var drop = 0
        for skip in 0..<min(echoSkip, head.count) {
            // Past a skipped fragment, one shared word is chance; two in a row are an echo.
            let minimum = skip == 0 ? 1 : skip + 1
            var run = min(tail.count, head.count - skip)
            while run >= minimum {
                let repeats = (0..<run).allSatisfy {
                    plain(head[skip + $0]) == plain(tail[tail.count - run + $0])
                }
                guard repeats else {
                    run -= 1
                    continue
                }
                drop = max(drop, skip + run)
                break
            }
        }
        guard drop > 0 else { return text }
        var index = text.startIndex
        for _ in 0..<drop {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
        }
        let rest = String(text[index...])
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : rest
    }

    /// Without a context the transcript goes in as it came: an unread caret is never guessed at.
    static func format(
        _ transcription: String, context: Context?, adaptCapitalization: Bool = true
    ) -> String {
        var text = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let context else { return text }
        if adaptCapitalization, let first = text.first, first.isLetter {
            let startsSentence =
                context.lastNonWhitespace.map { sentenceEnds.contains($0) } ?? true
                || context.newParagraph
            let replacement = startsSentence ? String(first).uppercased() : String(first).lowercased()
            text.replaceSubrange(text.startIndex...text.startIndex, with: replacement)
        }
        if let trailing = context.trailing, !trailing.isWhitespace, !openers.contains(trailing),
            let leading = text.first, !closers.contains(leading)
        {
            text = " " + text
        }
        if let following = context.following, !following.isWhitespace,
            let last = text.last, !last.isWhitespace, !closers.contains(following)
        {
            text += " "
        }
        return text
    }
}
