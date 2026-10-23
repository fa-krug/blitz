import Foundation

/// A reply's blocks across its updates: the lines no later text can change are read only once.
struct MarkdownStream: Sendable {
    /// The leading lines whose blocks are settled, each with its newline.
    private var settledText = ""
    private var settledBlocks: [MarkdownBlock] = []
    private var midStream = false

    /// What `MarkdownBlock.parse` returns, reading only what follows the settled lines.
    mutating func blocks(of markdown: String, midStream: Bool) -> [MarkdownBlock] {
        let text =
            markdown.utf8.contains(0x0D) ? markdown.replacingOccurrences(of: "\r\n", with: "\n") : markdown
        // Mid-stream decides what the end holds back, so a settled block assumed one value of it.
        if midStream != self.midStream || !text.utf8.starts(with: settledText.utf8) {
            settledText = ""
            settledBlocks = []
            self.midStream = midStream
        }
        let rest = String(text[text.utf8.index(text.startIndex, offsetBy: settledText.utf8.count)...])
        let lines = rest.components(separatedBy: "\n")
        let read = MarkdownBlock.settling(lines, midStream: midStream)
        let blocks = settledBlocks + read.blocks
        if read.settledLines > 0 {
            settledText += lines[..<read.settledLines].joined(separator: "\n") + "\n"
            settledBlocks += read.blocks[..<read.settledBlocks]
        }
        return blocks
    }
}
