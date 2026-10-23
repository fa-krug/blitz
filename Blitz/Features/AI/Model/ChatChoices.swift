import Foundation

/// A reply may end with a ```choices fence; its lines become buttons that answer for the reader.
enum ChatChoices {
    static let maxCount = 6
    /// Past this a line is prose that wandered into the fence, not an option.
    static let maxLength = 160

    /// The prose around the fence, and its options; an unclosed fence is still hidden mid-stream.
    static func split(_ text: String) -> (text: String, choices: [String]) {
        split(text, past: Settled())
    }

    /// The same, reading past `settled` only what follows it; `ChatChoicesStream` keeps that.
    static func split(_ text: String, past settled: Settled) -> (text: String, choices: [String]) {
        let tail = text[text.utf8.index(text.startIndex, offsetBy: settled.length)...]
        guard let open = tail.range(of: opener, options: .backwards),
            open.lowerBound == text.startIndex || text[text.index(before: open.lowerBound)] == "\n"
        else { return labelled(text, past: settled) ?? (text, []) }
        let body = text[open.upperBound...]
        let close = body.range(of: "```")
        let fenced = close.map { body[..<$0.lowerBound] } ?? body
        let after = close.map { body[$0.upperBound...] } ?? ""
        let choices = fenced.split(whereSeparator: \.isNewline)
            .map { option(String($0)) }
            .filter { !$0.isEmpty && $0.count <= maxLength }
        let prose = [trimmed(text.unicodeScalars[..<open.lowerBound]), trimmed(after.unicodeScalars)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (droppingDanglingFence(prose, past: settled), Array(choices.prefix(maxCount)))
    }

    /// Leading lines read once: no fence opener or label, with plain prose after them.
    struct Settled: Sendable {
        var length = 0
        var lines = 0
        var fence: Fence?
        var mentions = false
        /// The same lines from their first non-blank character, where a fenced reply's prose begins.
        var prose: (length: Int, lines: Int, fence: Fence?)?

        mutating func append(_ text: String) {
            let read = text.components(separatedBy: "\n").dropLast()
            fence = openFence(in: read, from: lines, after: fence)
            lines += read.count
            length += text.utf8.count
            mentions = mentions || mentionsChoices(text)
            if var prose {
                prose.fence = openFence(in: read, from: prose.lines, after: prose.fence)
                prose.lines += read.count
                prose.length += text.utf8.count
                self.prose = prose
            } else if let start = text.unicodeScalars.firstIndex(where: isContent) {
                let rest = text[start...].components(separatedBy: "\n").dropLast()
                prose = (text.utf8.distance(from: start, to: text.endIndex), rest.count, openFence(in: rest))
            }
        }
    }

    /// A line that may settle: what follows it can never make it the fence or the label.
    static func settles(_ line: String) -> Bool {
        line.range(of: opener) == nil && !isLabel(line)
    }

    /// Prose that no trim or strip reads past, so the lines before it can settle.
    static func holdsSettled(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("`") && settles(line)
    }

    typealias Fence = (line: Int, run: Int, isBare: Bool)

    private static let opener = "```choices"

    /// The on-device model's form: a `choices` line, then list items to the end, fenced or not.
    private static func labelled(_ text: String, past settled: Settled) -> (text: String, choices: [String])?
    {
        let tail = text[text.utf8.index(text.startIndex, offsetBy: settled.length)...]
        guard settled.mentions || mentionsChoices(tail) else { return nil }
        var lines = tail.components(separatedBy: "\n")
        while let last = lines.last, isBlank(last) || isBareFence(last) { lines.removeLast() }
        guard let label = lines.lastIndex(where: isLabel), label < lines.count - 1 else { return nil }
        let items = lines[(label + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !items.isEmpty, items.allSatisfy(isListItem) else { return nil }
        let choices = items.map(option).filter { !$0.isEmpty && $0.count <= maxLength }
        guard !choices.isEmpty else { return nil }
        var before = Array(lines[..<label])
        while let last = before.last, isBlank(last) { before.removeLast() }
        if let open = openFence(in: before, from: settled.lines, after: settled.fence) {
            guard open.isBare, open.line == settled.lines + before.count - 1 else { return nil }
            before.removeLast()
        }
        let prose = String(text[..<tail.startIndex]) + before.joined(separator: "\n")
        return (trimmed(prose.unicodeScalars[...]), Array(choices.prefix(maxCount)))
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isBareFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "```"
    }

    private static func openFence(
        in lines: some Sequence<String>, from first: Int = 0, after open: Fence? = nil
    ) -> Fence? {
        var open = open
        for (index, line) in zip(first..., lines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let run = trimmed.prefix { $0 == "`" }.count
            guard run >= 3 else { continue }
            let isBare = trimmed.count == run
            if let current = open {
                if isBare, run >= current.run { open = nil }
            } else {
                open = (index, run, isBare)
            }
        }
        return open
    }

    /// Only the lines past the settled ones are read; a fence open among those is never the last.
    private static func droppingDanglingFence(_ prose: String, past settled: Settled) -> String {
        let skipped = settled.prose?.length ?? 0
        let rest = prose[prose.utf8.index(prose.startIndex, offsetBy: skipped)...]
        let lines = rest.components(separatedBy: "\n")
        let first = settled.prose?.lines ?? 0
        guard let open = openFence(in: lines, from: first, after: settled.prose?.fence),
            open.line == first + lines.count - 1
        else { return prose }
        let scalars = prose.unicodeScalars
        return trimmed(scalars[..<(scalars.lastIndex(of: "\n") ?? scalars.startIndex)])
    }

    /// `trimmingCharacters(in: .whitespacesAndNewlines)`, reading only the ends it trims.
    private static func trimmed(_ scalars: Substring.UnicodeScalarView) -> String {
        guard let first = scalars.firstIndex(where: isContent), let last = scalars.lastIndex(where: isContent)
        else { return "" }
        return String(scalars[first...last])
    }

    private static func isContent(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// `choices`, as a model might dress it: bold, a heading, a trailing colon.
    private static func isLabel(_ line: String) -> Bool {
        guard mentionsChoices(line) else { return false }
        return line.trimmingCharacters(in: .whitespaces)
            .wholeMatch(of: #/(?i)(?:#{1,6}\s*)?(?:\*\*|__)?choices:?(?:\*\*|__)?:?/#) != nil
    }

    private static func mentionsChoices(_ text: some StringProtocol) -> Bool {
        text.range(of: "choices", options: .caseInsensitive) != nil
    }

    private static func isListItem(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).firstMatch(of: #/^(?:[-*•]|\d+[.)])\s+\S/#) != nil
    }

    /// A model lists options the way it lists anything, so a bullet or a number is not the option.
    private static func option(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if let marker = trimmed.firstMatch(of: #/^(?:[-*•]|\d+[.)])\s+/#) {
            trimmed.removeSubrange(marker.range)
        }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }
}
