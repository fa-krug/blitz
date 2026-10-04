import AppKit
import SwiftUI

/// An `NSTextView`, not `Text`: only the text system appends without re-laying out.
struct TerminalLogView: NSViewRepresentable {
    let transcript: CommandTranscript

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let inset = CGSize(width: Theme.Spacing.xxl, height: Theme.Spacing.xs)
    /// Within this of the bottom counts as following along, matching the chat transcript's band.
    private static let tailSlack = Theme.Spacing.chatFollowTailSlack

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// A new transcript or a trimmed log makes the drawn text wrong, unseen by the revision.
        var transcriptID: UUID?
        var generation = -1
        var revision = 0
        var lineCount = 0
        var interpreter = ANSIInterpreter()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        // Zeroed so the inset alone sets the left edge, lining the log up with the header text.
        textView.textContainer?.lineFragmentPadding = 0
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
            let storage = textView.textStorage
        else { return }
        let coordinator = context.coordinator
        // A line just typed is one the reader wants to watch, wherever they had scrolled to.
        let following = isAtBottom(scrollView) || transcript.lineCount != coordinator.lineCount
        coordinator.lineCount = transcript.lineCount

        let isSame =
            coordinator.transcriptID == transcript.id
            && coordinator.generation == transcript.generation
        guard !isSame || transcript.revision != coordinator.revision else { return }

        // One step on is streaming and costs only the new text; anything else is drawn whole.
        let isAppend = isSame && transcript.revision == coordinator.revision + 1
        if !isAppend {
            coordinator.interpreter = ANSIInterpreter()
            storage.setAttributedString(NSAttributedString())
        }
        coordinator.transcriptID = transcript.id
        coordinator.generation = transcript.generation
        coordinator.revision = transcript.revision
        coordinator.interpreter.render(
            isAppend ? transcript.delta : transcript.log, into: storage, font: Self.font)
        if following { textView.scrollToEndOfDocument(nil) }
    }

    /// A reader who scrolled up is left alone; arriving back at the end resumes the follow.
    private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visible = scrollView.contentView.bounds
        return visible.maxY >= documentView.frame.height - Self.tailSlack
    }
}

/// SGR colour carried across chunks, a CR rewinding its line, everything else dropped.
struct ANSIInterpreter {
    private var colour: NSColor = .labelColor
    private var isBold = false
    private var isDim = false
    /// A control sequence can be split across reads, so a partial one waits for the rest.
    private var partial = ""

    mutating func render(_ text: String, into storage: NSTextStorage, font: NSFont) {
        var run = ""
        var characters = Array(partial + text)[...]
        partial = ""

        func flush() {
            guard !run.isEmpty else { return }
            storage.append(NSAttributedString(string: run, attributes: attributes(font)))
            run = ""
        }

        while let character = characters.first {
            characters = characters.dropFirst()
            switch character {
            case "\u{1B}":
                guard let sequence = Self.take(&characters) else {
                    // Truncated mid-sequence: hold it back rather than printing the escape.
                    partial = "\u{1B}" + String(characters)
                    characters = characters.prefix(0)
                    continue
                }
                flush()
                apply(sequence)
            case "\r":
                // A progress bar redraws its line in place; appending the frames would stack them.
                flush()
                rewindLine(in: storage)
            case "\u{8}":
                flush()
                eraseCharacter(in: storage)
            default:
                // The echo of a typed ⌃D, a bell: control bytes with nothing to draw.
                if Self.isInvisibleControl(character) { continue }
                run.append(character)
            }
        }
        flush()
    }

    private func attributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        let face = isBold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        return [.font: face, .foregroundColor: isDim ? colour.withAlphaComponent(0.6) : colour]
    }

    /// Reads one CSI/OSC body; nil when the sequence has not all arrived yet.
    private static func take(_ characters: inout ArraySlice<Character>) -> String? {
        guard let introducer = characters.first else { return nil }
        characters = characters.dropFirst()
        guard introducer == "[" else {
            // OSC and the rest carry no meaning here; swallow to their terminator.
            while let character = characters.first, character != "\u{07}", character != "\u{1B}" {
                characters = characters.dropFirst()
            }
            return ""
        }
        var body = ""
        while let character = characters.first {
            characters = characters.dropFirst()
            body.append(character)
            if character.isLetter { return body }
        }
        return nil
    }

    private mutating func apply(_ sequence: String) {
        // Only SGR is drawn; cursor moves and erases have no meaning in a document.
        guard sequence.hasSuffix("m") else { return }
        let codes = sequence.dropLast().split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        var index = 0
        while index < max(codes.count, 1) {
            let code = codes.isEmpty ? 0 : codes[index]
            switch code {
            case 0: colour = .labelColor; isBold = false; isDim = false
            case 1: isBold = true
            case 2: isDim = true
            case 22: isBold = false; isDim = false
            case 30...37: colour = Self.palette[code - 30]
            case 90...97: colour = Self.palette[code - 90]
            case 39: colour = .labelColor
            // Extended colour carries its own parameters; skipping them keeps the rest in step.
            case 38, 48: index += codes.count > index + 1 && codes[index + 1] == 5 ? 2 : 4
            default: break
            }
            index += 1
        }
    }

    /// Deletes back to the start of the last line, which is what a bare carriage return means.
    private func rewindLine(in storage: NSTextStorage) {
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        let lineStart = text.range(
            of: "\n", options: .backwards, range: NSRange(location: 0, length: text.length))
        let start = lineStart.location == NSNotFound ? 0 : lineStart.location + 1
        guard start < text.length else { return }
        storage.deleteCharacters(in: NSRange(location: start, length: text.length - start))
    }

    /// A backspace moves back over a character a later one would overwrite, which is erasing it.
    private func eraseCharacter(in storage: NSTextStorage) {
        let text = storage.string as NSString
        guard text.length > 0, text.character(at: text.length - 1) != 0x0A else { return }
        storage.deleteCharacters(in: text.rangeOfComposedCharacterSequence(at: text.length - 1))
    }

    /// CR LF is one `Character` with two scalars, so it is never mistaken for a lone control.
    private static func isInvisibleControl(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first
        else { return false }
        return scalar.value < 0x20 && scalar != "\n" && scalar != "\t"
    }

    /// System colours, so the log reads in both appearances; orange stands in for yellow.
    private static let palette: [NSColor] = [
        .secondaryLabelColor, .systemRed, .systemGreen, .systemOrange,
        .systemBlue, .systemPurple, .systemTeal, .labelColor
    ]
}
