import AppKit
import SwiftUI

/// A reply streaming in, one flush at a time: what each update costs to parse, render and lay out.
@main
@MainActor
struct ChatMarkdownPerformance {
    static let width: CGFloat = 640

    static func main() {
        let arguments = CommandLine.arguments
        let chunk = value(after: "--chunk", in: arguments) ?? 16
        let sections = value(after: "--sections", in: arguments) ?? 14
        let reply = ChatMarkdownFixture.longReply(sections: sections)
        let pieces = ChatMarkdownFixture.chunks(of: reply, size: chunk)
        print("reply: \(reply.utf8.count) bytes, \(pieces.count) updates of \(chunk) characters")
        if !arguments.contains("--incremental-only") { full(pieces) }
        cached(pieces)
        view(pieces)
    }

    private static func value(after flag: String, in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    /// Two layouts of one storage, as `ChatSelectableTextView` keeps: drawn and measuring.
    @MainActor
    final class Surface {
        let storage = NSTextStorage()
        let drawn = NSLayoutManager()
        let measurer = NSLayoutManager()
        let drawnContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        let measuringContainer = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude))

        init() {
            for (layout, container) in [(drawn, drawnContainer), (measurer, measuringContainer)] {
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
            }
        }

        func layOut() {
            drawn.ensureLayout(for: drawnContainer)
            measurer.ensureLayout(for: measuringContainer)
        }
    }

    struct Timing {
        var parse = 0.0
        var render = 0.0
        var layout = 0.0
        var total: Double { parse + render + layout }
    }

    static func milliseconds(_ work: () -> Void) -> Double {
        let start = ContinuousClock.now
        work()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
    }

    static func source(_ blocks: [MarkdownBlock]) -> ChatMarkdownSource {
        ChatMarkdownSource(
            blocks: blocks, highlight: nil, citations: [:], prefix: [0], failedFrom: nil,
            metrics: .standard)
    }

    /// Every update parses, renders and lays out the whole reply so far, as the shipped view did.
    static func full(_ pieces: [String]) {
        let surface = Surface()
        var text = ""
        var timings: [(bytes: Int, timing: Timing)] = []
        for piece in pieces {
            text += piece
            var timing = Timing()
            var blocks: [MarkdownBlock] = []
            timing.parse = milliseconds { blocks = MarkdownBlock.parse(text, midStream: true) }
            var rendered: ChatRenderedText?
            timing.render = milliseconds { rendered = ChatMarkdownRenderer(source(blocks)).render() }
            timing.layout = milliseconds {
                surface.storage.setAttributedString(rendered!.string)
                surface.layOut()
            }
            timings.append((text.utf8.count, timing))
        }
        report("full", timings)
    }

    /// The same three steps through the stream parse and the render cache, as the view runs them.
    static func cached(_ pieces: [String]) {
        let surface = Surface()
        let cache = ChatMarkdownRenderCache()
        var stream = MarkdownStream()
        var text = ""
        var timings: [(bytes: Int, timing: Timing)] = []
        for piece in pieces {
            text += piece
            var timing = Timing()
            var blocks: [MarkdownBlock] = []
            timing.parse = milliseconds { blocks = stream.blocks(of: text, midStream: true) }
            timing.render = milliseconds { _ = cache.update(surface.storage, to: source(blocks)) }
            timing.layout = milliseconds { surface.layOut() }
            timings.append((text.utf8.count, timing))
        }
        report("cached", timings)
    }

    /// The shipped text view, handed what the transcript hands it and sized as SwiftUI sizes it.
    static func view(_ pieces: [String]) {
        let view = ChatSelectableTextView()
        view.setFrameSize(CGSize(width: width, height: 1))
        var text = ""
        var timings: [(bytes: Int, timing: Timing)] = []
        for piece in pieces {
            text += piece
            var timing = Timing()
            var markdown = ""
            timing.parse = milliseconds { markdown = ChatChoices.split(text).text }
            timing.render = milliseconds {
                view.show(
                    ChatMarkdownInput(
                        markdown: markdown, midStream: true, failsLastBlock: false, highlight: nil,
                        citations: [:], prefix: [0], metrics: .standard))
            }
            timing.layout = milliseconds {
                let size = view.measure(width: width)
                view.setFrameSize(CGSize(width: width, height: size.height))
            }
            timings.append((text.utf8.count, timing))
        }
        report("view (parse = choices split, render = show, layout = measure and resize)", timings)
    }

    static func report(_ name: String, _ timings: [(bytes: Int, timing: Timing)]) {
        let total = timings.reduce(0) { $0 + $1.timing.total }
        print("\n\(name): \(String(format: "%.0f", total)) ms over \(timings.count) updates")
        print("  at      parse   render   layout    total   (ms per update, mean of the 5% ending there)")
        let count = timings.count
        for fraction in [0.25, 0.5, 0.75, 1.0] {
            let end = max(Int(Double(count) * fraction), 1)
            let window = timings[max(end - max(count / 20, 1), 0)..<end]
            func mean(_ key: KeyPath<Timing, Double>) -> String {
                String(format: "%7.2f", window.reduce(0) { $0 + $1.timing[keyPath: key] } / Double(window.count))
            }
            let kilobytes = String(format: "%5.1f KB", Double(window.last!.bytes) / 1024)
            print("  \(kilobytes) \(mean(\.parse))  \(mean(\.render))  \(mean(\.layout))  \(mean(\.total))")
        }
    }
}

/// The code header's Copy is never pressed here; the real one would write the shared pasteboard.
enum Paster {
    @discardableResult
    static func copyPlainText(_ text: String) -> Bool { true }
}
