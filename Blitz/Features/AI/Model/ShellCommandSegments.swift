import Foundation

/// The shell command splitter rules match against; nil means it cannot be read with confidence.
enum ShellCommandSegments {
    /// Refused even inside quotes, since `eval`, `trap` and arithmetic can run a quoted string.
    private static let forbiddenAnywhere = ["$(", "`", "<(", ">(", "<<", "${(", "$'"]
    /// Words that run, define or re-read other commands, so the text after them is not the command.
    private static let opaqueLeadingWords: Set<String> = [
        "!", "if", "then", "else", "elif", "fi", "for", "foreach", "while", "until", "do", "done",
        "case", "esac", "select", "repeat", "end", "function", "coproc", "time", "and", "or",
        "not", "begin", "eval", "exec", "source", ".", "command", "builtin", "noglob",
        "nocorrect", "-", "alias", "trap", "emulate", "let", "declare", "typeset", "local",
        "export", "readonly", "integer", "float"
    ]
    /// Quoting, expansion, assignment, globbing or a redirection in the command word itself.
    private static let opaqueLeadingScalars = Set("'\"\\$=*?[]{}<>".unicodeScalars)

    static func segments(of command: String) -> [String]? {
        let scalars = Array(command.unicodeScalars)
        guard !forbiddenAnywhere.contains(where: { contains($0, in: scalars) }) else { return nil }
        var reader = Reader(scalars)
        guard let segments = reader.split(), !segments.isEmpty,
            segments.allSatisfy(hasPlainLeadingWord)
        else { return nil }
        return segments
    }

    /// The command word, the part of a segment before its first space or tab.
    static func leadingWord(of segment: String) -> String {
        String(segment.unicodeScalars.prefix { $0 != " " && $0 != "\t" })
    }

    private static func hasPlainLeadingWord(_ segment: String) -> Bool {
        let word = leadingWord(of: segment)
        guard word != "[" else { return true }
        return !opaqueLeadingWords.contains(word)
            && !word.unicodeScalars.contains(where: opaqueLeadingScalars.contains)
    }

    private static func contains(_ needle: String, in scalars: [Unicode.Scalar]) -> Bool {
        let needle = Array(needle.unicodeScalars)
        guard scalars.count >= needle.count else { return false }
        return (0...scalars.count - needle.count).contains { start in
            scalars[start..<start + needle.count].elementsEqual(needle)
        }
    }

    /// Scalars rather than characters: a combining mark must not hide a quote the shell still sees.
    private struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0
        var current = String.UnicodeScalarView()
        var segments: [String] = []

        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        private func peek() -> Unicode.Scalar? {
            index + 1 < scalars.count ? scalars[index + 1] : nil
        }

        private mutating func take(_ count: Int = 1) {
            current.append(contentsOf: scalars[index..<index + count])
            index += count
        }

        private mutating func endSegment(skipping count: Int) {
            let text = String(current).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if !text.isEmpty { segments.append(text) }
            current = String.UnicodeScalarView()
            index += count
        }

        mutating func split() -> [String]? {
            while index < scalars.count {
                guard readUnquoted() else { return nil }
            }
            endSegment(skipping: 0)
            return segments
        }

        private mutating func readUnquoted() -> Bool {
            let scalar = scalars[index]
            switch scalar {
            case "\\":
                guard let escaped = peek() else { return false }
                if escaped == "\n" { index += 2 } else { take(2) }
            case "'": return readQuoted(until: "'", escapes: false)
            case "\"": return readQuoted(until: "\"", escapes: true)
            case "(", ")", "#": return false
            case ";", "\n": endSegment(skipping: 1)
            case "&":
                switch peek() {
                case "&": endSegment(skipping: 2)
                case ">": take(2)
                default: endSegment(skipping: 1)
                }
            case "|": endSegment(skipping: peek() == "|" ? 2 : 1)
            case "<", ">":
                let isOneOperator = peek() == "&" || (scalar == ">" && peek() == "|")
                take(isOneOperator ? 2 : 1)
            default:
                guard scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F) else {
                    return false
                }
                take()
            }
            return true
        }

        private mutating func readQuoted(until closing: Unicode.Scalar, escapes: Bool) -> Bool {
            take()
            while index < scalars.count {
                let scalar = scalars[index]
                if escapes, scalar == "\\" {
                    guard peek() != nil else { return false }
                    take(2)
                    continue
                }
                take()
                if scalar == closing { return true }
            }
            return false
        }
    }
}
