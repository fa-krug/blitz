import Foundation

/// A reply's choices across its updates: the lines no later text can change are read only once.
struct ChatChoicesStream: Sendable {
    private var settledText = ""
    /// The line after the settled ones; a text that changes it starts over.
    private var holding = ""
    private var settled = ChatChoices.Settled()

    /// What `ChatChoices.split` returns, reading only what follows the settled lines.
    mutating func split(_ text: String) -> (text: String, choices: [String]) {
        if !text.hasUTF8Prefix(settledText)
            || !text.utf8.dropFirst(settledText.utf8.count).starts(with: holding.utf8)
        {
            self = ChatChoicesStream()
        }
        let tail = text[text.utf8.index(text.startIndex, offsetBy: settledText.utf8.count)...]
        let lines = tail.components(separatedBy: "\n").dropLast()
        var count = 0
        for (index, line) in lines.enumerated() {
            if index > 0, ChatChoices.holdsSettled(line) { count = index }
            if !ChatChoices.settles(line) { break }
        }
        if count > 0 {
            let read = lines.prefix(count).joined(separator: "\n") + "\n"
            settledText += read
            settled.append(read)
            holding = lines[count] + "\n"
        }
        return ChatChoices.split(text, past: settled)
    }
}
