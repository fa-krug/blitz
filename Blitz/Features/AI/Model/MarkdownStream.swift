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
            markdown.containsUTF8(0x0D) ? markdown.replacingOccurrences(of: "\r\n", with: "\n") : markdown
        // Mid-stream decides what the end holds back, so a settled block assumed one value of it.
        if midStream != self.midStream || !text.hasUTF8Prefix(settledText) {
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

/// Raw memory reads: the generic walk over `utf8` costs a long reply's length on every update.
extension String {
    func hasUTF8Prefix(_ prefix: String) -> Bool {
        let compared = utf8.withContiguousStorageIfAvailable { whole in
            prefix.utf8.withContiguousStorageIfAvailable { part in
                part.isEmpty
                    || part.count <= whole.count
                        && memcmp(whole.baseAddress!, part.baseAddress!, part.count) == 0
            }
        }
        if case let compared?? = compared { return compared }
        return utf8.starts(with: prefix.utf8)
    }

    func containsUTF8(_ byte: UInt8) -> Bool {
        let found = utf8.withContiguousStorageIfAvailable { bytes in
            !bytes.isEmpty && memchr(bytes.baseAddress!, Int32(byte), bytes.count) != nil
        }
        return found ?? utf8.contains(byte)
    }
}
