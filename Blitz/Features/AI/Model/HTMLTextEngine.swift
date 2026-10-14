import Foundation

/// A page's HTML as the text a reader sees: no scripts or styles, each link followed by its URL.
enum HTMLTextEngine {
    struct Page: Equatable, Sendable {
        let title: String?
        let text: String
    }

    /// `baseURL` is the page's final URL; a `<base href>` in the page replaces it.
    static func page(from html: String, baseURL: URL?) -> Page {
        var reader = Reader(bytes: Array(html.utf8), base: baseURL)
        reader.read()
        return Page(title: reader.title, text: reader.finishedText())
    }

    /// Entities decoded and runs of whitespace made one space, as a title or an attribute reads.
    static func collapsed(_ text: String) -> String {
        decoded(Array(text.utf8)[...]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// UTF-8 with anything invalid read as U+FFFD, so a page's bad bytes never lose its text.
    static func lossyText(_ bytes: some Collection<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func decoded(_ bytes: ArraySlice<UInt8>) -> String {
        var output: [UInt8] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == ascii("&"), let (scalar, end) = entity(in: bytes, at: index) {
                output.append(contentsOf: Array(String(scalar).utf8))
                index = end
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return lossyText(output)
    }

    // MARK: - Elements

    /// Dropped with all they hold; `script` and `style` are raw text and skipped to their end tag.
    private static let hiddenElements: Set<String> = ["noscript", "svg", "template", "math"]
    private static let rawTextElements: Set<String> = ["script", "style"]
    /// What may sit in `<head>`; any other start tag ends it, as a browser reads a missing `</head>`.
    private static let headElements: Set<String> = [
        "meta", "link", "title", "style", "script", "base", "noscript", "template"
    ]
    private static let paragraphElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "dl", "table", "blockquote", "figure", "hr"
    ]
    private static let lineElements: Set<String> = [
        "div", "section", "article", "header", "footer", "nav", "aside", "main", "form",
        "fieldset", "figcaption", "address", "details", "summary", "caption", "legend", "tr",
        "dt", "dd", "li", "center", "option"
    ]
    private static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    fileprivate static func ascii(_ character: Character) -> UInt8 { character.asciiValue ?? 0 }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x30 && byte <= 0x39) || byte == ascii("-") || byte == ascii(":")
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A)
    }

    private static func lowered(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    // MARK: - Entities

    private static let namedEntities: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "\u{A9}", "reg": "\u{AE}", "trade": "\u{2122}", "hellip": "\u{2026}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "sbquo": "\u{201A}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "laquo": "\u{AB}", "raquo": "\u{BB}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "bull": "\u{2022}", "middot": "\u{B7}", "deg": "\u{B0}", "euro": "\u{20AC}",
        "pound": "\u{A3}", "yen": "\u{A5}", "cent": "\u{A2}", "sect": "\u{A7}", "para": "\u{B6}",
        "times": "\u{D7}", "divide": "\u{F7}", "plusmn": "\u{B1}", "minus": "\u{2212}",
        "frac12": "\u{BD}", "frac14": "\u{BC}", "frac34": "\u{BE}", "sup2": "\u{B2}",
        "sup3": "\u{B3}", "micro": "\u{B5}", "iexcl": "\u{A1}", "iquest": "\u{BF}",
        "shy": "\u{AD}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "larr": "\u{2190}", "uarr": "\u{2191}",
        "rarr": "\u{2192}", "darr": "\u{2193}", "harr": "\u{2194}", "rArr": "\u{21D2}",
        "dagger": "\u{2020}", "Dagger": "\u{2021}", "permil": "\u{2030}", "prime": "\u{2032}",
        "check": "\u{2713}", "star": "\u{2606}", "hearts": "\u{2665}", "infin": "\u{221E}",
        "ne": "\u{2260}", "le": "\u{2264}", "ge": "\u{2265}", "asymp": "\u{2248}",
        "auml": "\u{E4}", "ouml": "\u{F6}", "uuml": "\u{FC}", "Auml": "\u{C4}", "Ouml": "\u{D6}",
        "Uuml": "\u{DC}", "szlig": "\u{DF}", "aacute": "\u{E1}", "agrave": "\u{E0}",
        "acirc": "\u{E2}", "atilde": "\u{E3}", "aring": "\u{E5}", "aelig": "\u{E6}",
        "ccedil": "\u{E7}", "eacute": "\u{E9}", "egrave": "\u{E8}", "ecirc": "\u{EA}",
        "euml": "\u{EB}", "iacute": "\u{ED}", "igrave": "\u{EC}", "icirc": "\u{EE}",
        "iuml": "\u{EF}", "ntilde": "\u{F1}", "oacute": "\u{F3}", "ograve": "\u{F2}",
        "ocirc": "\u{F4}", "otilde": "\u{F5}", "oslash": "\u{F8}", "uacute": "\u{FA}",
        "ugrave": "\u{F9}", "ucirc": "\u{FB}", "yacute": "\u{FD}", "yuml": "\u{FF}",
        "Aacute": "\u{C1}", "Agrave": "\u{C0}", "Aring": "\u{C5}", "AElig": "\u{C6}",
        "Ccedil": "\u{C7}", "Eacute": "\u{C9}", "Egrave": "\u{C8}", "Ntilde": "\u{D1}",
        "Oacute": "\u{D3}", "Oslash": "\u{D8}", "Uacute": "\u{DA}", "oelig": "\u{153}",
        "OElig": "\u{152}", "alpha": "\u{3B1}", "beta": "\u{3B2}", "gamma": "\u{3B3}",
        "delta": "\u{3B4}", "pi": "\u{3C0}", "sigma": "\u{3C3}", "omega": "\u{3C9}",
        "Omega": "\u{3A9}", "lambda": "\u{3BB}", "mu": "\u{3BC}"
    ]

    /// `&name;` or `&#…;`, and where it ends; nil leaves the `&` as written.
    fileprivate static func entity(
        in bytes: ArraySlice<UInt8>, at start: Int
    ) -> (Unicode.Scalar, Int)? {
        var index = start + 1
        guard index < bytes.endIndex else { return nil }
        if bytes[index] == ascii("#") {
            index += 1
            var radix = 10
            if index < bytes.endIndex, lowered(bytes[index]) == ascii("x") {
                radix = 16
                index += 1
            }
            let digitsStart = index
            let digits = radix == 16 ? "0123456789abcdefABCDEF" : "0123456789"
            while index < bytes.endIndex, index - digitsStart < 8,
                digits.utf8.contains(bytes[index])
            {
                index += 1
            }
            guard index > digitsStart,
                let value = UInt32(
                    lossyText(bytes[digitsStart..<index]), radix: radix)
            else { return nil }
            if index < bytes.endIndex, bytes[index] == ascii(";") { index += 1 }
            return (numericScalar(value), index)
        }
        let nameStart = index
        while index < bytes.endIndex, index - nameStart < 10, isNameByte(bytes[index]) {
            index += 1
        }
        guard index < bytes.endIndex, bytes[index] == ascii(";"),
            let scalar = namedEntities[lossyText(bytes[nameStart..<index])]
        else { return nil }
        return (scalar, index + 1)
    }

    /// As browsers read them: 128–159 are Windows-1252's, and nothing invalid survives.
    private static func numericScalar(_ value: UInt32) -> Unicode.Scalar {
        if (0x80...0x9F).contains(value),
            let text = String(data: Data([UInt8(value)]), encoding: .windowsCP1252),
            let scalar = text.unicodeScalars.first
        {
            return scalar
        }
        guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
        return scalar
    }

    // MARK: - Reading

    private struct Reader {
        let bytes: [UInt8]
        var base: URL?
        var index = 0
        var output: [UInt8] = []
        var title: String?
        var pendingSpace = false
        var isInHead = false
        var hidden: (name: String, depth: Int)?
        var preformatted = 0
        /// Where the current list item's "- " ends, so a block opening inside it breaks no line.
        var markerEnd = -1
        var anchor: (href: String?, start: Int)?
        /// A list inside a list item opens on the next line rather than after a blank one.
        var lists = 0

        init(bytes: [UInt8], base: URL?) {
            self.bytes = bytes
            self.base = base
        }

        mutating func read() {
            while index < bytes.count {
                let byte = bytes[index]
                if byte == HTMLTextEngine.ascii("<"), readMarkup() { continue }
                if byte == HTMLTextEngine.ascii("&"),
                    let (scalar, end) = HTMLTextEngine.entity(in: bytes[...], at: index)
                {
                    emit(scalar)
                    index = end
                    continue
                }
                emit(byte)
                index += 1
            }
            closeAnchor()
        }

        /// Blank lines run together into one, and none open or close the text.
        func finishedText() -> String {
            var lines: [Substring] = []
            let text = HTMLTextEngine.lossyText(output)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let isBlank = line.allSatisfy { $0 == " " }
                if isBlank, lines.last?.isEmpty ?? true { continue }
                lines.append(isBlank ? "" : line)
            }
            while lines.last?.isEmpty == true { lines.removeLast() }
            return lines.joined(separator: "\n")
        }

        // MARK: Text

        private var isSilent: Bool { hidden != nil || isInHead }

        private var isAtLineStart: Bool { output.isEmpty || output.last == 0x0A }

        private mutating func emit(_ byte: UInt8) {
            guard !isSilent else { return }
            if preformatted > 0 {
                if byte != 0x0D { output.append(byte) }
                return
            }
            if HTMLTextEngine.isSpace(byte) {
                pendingSpace = true
                return
            }
            if pendingSpace, !isAtLineStart, output.last != 0x20 { output.append(0x20) }
            pendingSpace = false
            output.append(byte)
        }

        private mutating func emit(_ scalar: Unicode.Scalar) {
            if scalar == "\u{A0}" || scalar == "\u{2002}" || scalar == "\u{2003}" {
                emit(0x20)
                return
            }
            guard scalar != "\u{AD}" else { return }
            for byte in String(scalar).utf8 { emit(byte) }
        }

        private mutating func write(_ text: String) {
            guard !isSilent else { return }
            if pendingSpace, !isAtLineStart, output.last != 0x20 { output.append(0x20) }
            pendingSpace = false
            output.append(contentsOf: Array(text.utf8))
        }

        private mutating func separateCell() {
            guard !isSilent else { return }
            pendingSpace = false
            while output.last == 0x20 { output.removeLast() }
            guard !isAtLineStart else { return }
            output.append(contentsOf: Array(" | ".utf8))
        }

        private mutating func breakLine(_ count: Int) {
            guard !isSilent else { return }
            pendingSpace = false
            if output.count == markerEnd { return }
            while output.last == 0x20 { output.removeLast() }
            guard !output.isEmpty else { return }
            let existing = output.reversed().prefix { $0 == 0x0A }.count
            if existing < count { output.append(contentsOf: repeatElement(0x0A, count: count - existing)) }
        }

        // MARK: Markup

        /// False when the `<` is text, as in `a < b`.
        private mutating func readMarkup() -> Bool {
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if starts(with: "<!--", at: index) {
                index = position(of: "-->", from: index + 4).map { $0 + 3 } ?? bytes.count
                return true
            }
            if next == HTMLTextEngine.ascii("!") || next == HTMLTextEngine.ascii("?") {
                index = position(of: ">", from: index + 2).map { $0 + 1 } ?? bytes.count
                return true
            }
            if next == HTMLTextEngine.ascii("/") {
                guard index + 2 < bytes.count, HTMLTextEngine.isLetter(bytes[index + 2]) else {
                    return false
                }
                let name = readName(from: index + 2)
                index = position(of: ">", from: index).map { $0 + 1 } ?? bytes.count
                close(name)
                return true
            }
            guard HTMLTextEngine.isLetter(next) else { return false }
            let name = readName(from: index + 1)
            let (href, selfClosing) = readAttributes()
            open(name, href: href, selfClosing: selfClosing)
            return true
        }

        /// Leaves `index` at the byte after the name.
        private mutating func readName(from start: Int) -> String {
            var end = start
            while end < bytes.count, HTMLTextEngine.isNameByte(bytes[end]) { end += 1 }
            index = end
            return HTMLTextEngine.lossyText(bytes[start..<end].map(HTMLTextEngine.lowered))
        }

        /// Only `href` is kept; quotes are honoured, so a `>` inside a value ends nothing.
        private mutating func readAttributes() -> (href: String?, selfClosing: Bool) {
            var href: String?
            while index < bytes.count {
                let byte = bytes[index]
                if HTMLTextEngine.isSpace(byte) {
                    index += 1
                    continue
                }
                if byte == HTMLTextEngine.ascii(">") {
                    index += 1
                    return (href, false)
                }
                if byte == HTMLTextEngine.ascii("/") {
                    index += 1
                    if index < bytes.count, bytes[index] == HTMLTextEngine.ascii(">") {
                        index += 1
                        return (href, true)
                    }
                    continue
                }
                let nameStart = index
                while index < bytes.count, !HTMLTextEngine.isSpace(bytes[index]),
                    ![HTMLTextEngine.ascii("="), HTMLTextEngine.ascii(">")].contains(bytes[index])
                {
                    index += 1
                }
                let name = HTMLTextEngine.lossyText(
                    bytes[nameStart..<index].map(HTMLTextEngine.lowered))
                skipSpaces()
                guard index < bytes.count, bytes[index] == HTMLTextEngine.ascii("=") else {
                    continue
                }
                index += 1
                skipSpaces()
                let value = readValue()
                if name == "href" { href = HTMLTextEngine.decoded(value) }
            }
            return (href, false)
        }

        private mutating func readValue() -> ArraySlice<UInt8> {
            guard index < bytes.count else { return [] }
            let quote = bytes[index]
            if quote == HTMLTextEngine.ascii("\"") || quote == HTMLTextEngine.ascii("'") {
                let end = bytes[(index + 1)...].firstIndex(of: quote) ?? bytes.count
                let value = bytes[(index + 1)..<end]
                index = min(end + 1, bytes.count)
                return value
            }
            let start = index
            while index < bytes.count, !HTMLTextEngine.isSpace(bytes[index]),
                bytes[index] != HTMLTextEngine.ascii(">")
            {
                index += 1
            }
            return bytes[start..<index]
        }

        private mutating func skipSpaces() {
            while index < bytes.count, HTMLTextEngine.isSpace(bytes[index]) { index += 1 }
        }

        private mutating func open(_ name: String, href: String?, selfClosing: Bool) {
            if HTMLTextEngine.rawTextElements.contains(name) {
                if !selfClosing { index = endOfRawText(name).end }
                return
            }
            if let hidden {
                if name == hidden.name, !selfClosing { self.hidden = (name, hidden.depth + 1) }
                return
            }
            if name == "title" {
                let (contentEnd, end) = endOfRawText(name)
                if title == nil {
                    let text = HTMLTextEngine.collapsed(
                        HTMLTextEngine.lossyText(bytes[min(index, contentEnd)..<contentEnd]))
                    title = text.isEmpty ? nil : text
                }
                index = end
                return
            }
            if name == "base", let href, let url = URL(string: href, relativeTo: base) {
                base = url.absoluteURL
            }
            if isInHead {
                if HTMLTextEngine.headElements.contains(name) { return }
                isInHead = false
            }
            switch name {
            case "head": isInHead = !selfClosing
            case _ where HTMLTextEngine.hiddenElements.contains(name):
                if !selfClosing { hidden = (name, 1) }
            case "br": breakLine(1)
            case "li":
                markerEnd = -1
                breakLine(1)
                write("- ")
                markerEnd = output.count
            case "td", "th": separateCell()
            case "a":
                closeAnchor()
                anchor = (link(href), output.count)
            case "ul", "ol":
                breakLine(lists > 0 ? 1 : 2)
                lists += 1
            case "pre":
                breakLine(2)
                preformatted += 1
            case _ where HTMLTextEngine.paragraphElements.contains(name): breakLine(2)
            case _ where HTMLTextEngine.lineElements.contains(name): breakLine(1)
            default: break
            }
        }

        private mutating func close(_ name: String) {
            if let hidden {
                if name == hidden.name {
                    self.hidden = hidden.depth > 1 ? (name, hidden.depth - 1) : nil
                }
                return
            }
            if isInHead {
                if name == "head" { isInHead = false }
                return
            }
            switch name {
            case "a": closeAnchor()
            case "ul", "ol":
                lists = max(0, lists - 1)
                breakLine(lists > 0 ? 1 : 2)
            case "pre":
                preformatted = max(0, preformatted - 1)
                breakLine(2)
            case _ where HTMLTextEngine.paragraphElements.contains(name): breakLine(2)
            case _ where HTMLTextEngine.lineElements.contains(name): breakLine(1)
            default: break
            }
        }

        /// Absolute, and only for a link a reader could follow; an in-page `#…` link has none.
        private func link(_ href: String?) -> String? {
            guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines),
                !href.isEmpty, !href.hasPrefix("#"),
                let url = URL(string: href, relativeTo: base)?.absoluteURL,
                let scheme = url.scheme?.lowercased(), HTMLTextEngine.linkSchemes.contains(scheme)
            else { return nil }
            return url.absoluteString
        }

        private mutating func closeAnchor() {
            guard let open = anchor else { return }
            anchor = nil
            guard let href = open.href, open.start <= output.count else { return }
            let text = HTMLTextEngine.lossyText(output[open.start...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = ["https://", "http://", "mailto:"].first(where: href.hasPrefix)
                .map { String(href.dropFirst($0.count)) } ?? href
            guard !text.isEmpty, text != href, text != bare else { return }
            while output.last == 0x20 { output.removeLast() }
            output.append(contentsOf: Array(" (\(href))".utf8))
        }

        /// Where the content stops and where reading resumes, after the end tag's `>`.
        private func endOfRawText(_ name: String) -> (contentEnd: Int, end: Int) {
            var search = index
            while let start = position(of: "</", from: search) {
                let nameEnd = start + 2 + name.utf8.count
                if nameEnd <= bytes.count,
                    bytes[(start + 2)..<nameEnd].map(HTMLTextEngine.lowered).elementsEqual(name.utf8),
                    nameEnd == bytes.count || !HTMLTextEngine.isNameByte(bytes[nameEnd])
                {
                    let end = position(of: ">", from: nameEnd).map { $0 + 1 } ?? bytes.count
                    return (start, end)
                }
                search = start + 2
            }
            return (bytes.count, bytes.count)
        }

        private func starts(with text: String, at position: Int) -> Bool {
            let pattern = Array(text.utf8)
            guard position + pattern.count <= bytes.count else { return false }
            return bytes[position..<(position + pattern.count)].elementsEqual(pattern)
        }

        private func position(of text: String, from start: Int) -> Int? {
            let pattern = Array(text.utf8)
            guard let first = pattern.first, start < bytes.count else { return nil }
            var cursor = start
            while let found = bytes[cursor...].firstIndex(of: first) {
                if starts(with: text, at: found) { return found }
                cursor = found + 1
                guard cursor < bytes.count else { return nil }
            }
            return nil
        }
    }
}
