import AppKit

/// Each block's drawn text, kept so an update renders and re-lays out only from its first change.
@MainActor
final class ChatMarkdownRenderCache {
    /// What every block is drawn with; a change to any of it redraws them all.
    private struct Surroundings: Equatable {
        let highlight: ChatTextHighlight?
        let citations: [String: Int]
        let prefix: [Int]
        let metrics: InterfaceMetrics

        init(_ source: ChatMarkdownSource) {
            highlight = source.highlight
            citations = source.citations
            prefix = source.prefix
            metrics = source.metrics
        }
    }

    private struct Drawn {
        let block: MarkdownBlock
        let isFailed: Bool
        let fragment: ChatRenderedText.Fragment
    }

    private var surroundings: Surroundings?
    private var drawn: [Drawn] = []
    private let mathEngines = ChatMarkdownRenderer.MathEngines()

    /// Leaves `storage` holding what `ChatMarkdownRenderer.render()` makes of `source`.
    func update(_ storage: NSTextStorage, to source: ChatMarkdownSource) -> ChatRenderedText {
        let renderer = ChatMarkdownRenderer(source, mathEngines: mathEngines)
        let surroundings = Surroundings(source)
        let previous = surroundings == self.surroundings ? drawn : []
        self.surroundings = surroundings
        var first = 0
        while first < min(previous.count, source.blocks.count), previous[first].block == source.blocks[first],
            previous[first].isFailed == renderer.isFailed(at: first)
        {
            first += 1
        }
        drawn = Array(previous[..<first])
        for position in first..<source.blocks.count {
            drawn.append(
                Drawn(
                    block: source.blocks[position], isFailed: renderer.isFailed(at: position),
                    fragment: renderer.fragment(at: position)))
        }
        let fragments = drawn.map(\.fragment)
        replaceTail(of: storage, from: first, previous: previous.map(\.fragment), with: fragments)
        return ChatRenderedText(string: storage, placing: fragments)
    }

    /// The text before the first changed block keeps its layout; only what follows is replaced.
    private func replaceTail(
        of storage: NSTextStorage, from first: Int, previous: [ChatRenderedText.Fragment],
        with fragments: [ChatRenderedText.Fragment]
    ) {
        let starts = fragments.reduce(into: [0]) { $0.append($0.last! + $1.string.length) }
        let wanted = Self.length(of: fragments)
        let isUnchanged = first == previous.count && first == fragments.count && storage.length == wanted
        guard !isUnchanged else { return }
        // Storage another hand changed, or none of it kept, is replaced whole.
        var kept = storage.length == Self.length(of: previous) && !previous.isEmpty ? first : 0
        // A kept block that ended the text lost its break, so it is put back with the rest.
        while kept > 0, starts[kept] > min(storage.length, wanted) { kept -= 1 }
        let tail = NSMutableAttributedString()
        for fragment in fragments[kept...] { tail.append(fragment.string) }
        tail.deleteCharacters(
            in: NSRange(location: wanted - starts[kept], length: tail.length - (wanted - starts[kept])))
        let replaced = NSRange(location: starts[kept], length: storage.length - starts[kept])
        guard replaced.length > 0 || tail.length > 0 else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: replaced, with: tail)
        storage.endEditing()
    }

    /// The length `ChatRenderedText.joined` gives: every fragment, less a final paragraph break.
    private static func length(of fragments: [ChatRenderedText.Fragment]) -> Int {
        let total = fragments.reduce(0) { $0 + $1.string.length }
        let last = fragments.last { $0.string.length > 0 }?.string
        return last.map(ChatRenderedText.endsWithBreak) == true ? total - 1 : total
    }
}
