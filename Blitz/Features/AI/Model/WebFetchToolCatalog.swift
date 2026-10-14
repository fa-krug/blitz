import Foundation

/// How a chat model asks Blitz to fetch one web page, and how the page reads back as text.
enum WebFetchToolCatalog {
    static let origin = "Web"
    static let fetchName = "web_fetch"

    static let defaultCharacters = 20_000
    static let characterLimit = 100_000
    /// Bytes read from a body at most; the rest is never downloaded.
    static let byteLimit = 5 * 1024 * 1024
    static let redirectLimit = 5
    /// Silence allowed between two packets, and the whole fetch, redirects included.
    static let requestTimeout: TimeInterval = 15
    static let totalTimeout: TimeInterval = 30
    private static let sniffSize = 8 * 1024

    private typealias Invalid = AIToolArguments.Invalid

    /// A call, already checked: an http or https URL with a host and no credentials.
    struct Request: Equatable, Sendable {
        let url: URL
        let maxCharacters: Int

        var isLocalNetwork: Bool { LocalNetworkPolicy.isLocal(url) }

        var agentCall: AgentCall { .webFetch(isLocalNetwork: isLocalNetwork) }
    }

    /// What the network or the page said no to, worded for the model to read.
    struct Failure: Error, Equatable, Sendable {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    /// What came back, before it is read as text; `body` holds at most `byteLimit` bytes.
    struct Page: Equatable, Sendable {
        let requestedURL: URL
        let finalURL: URL
        let status: Int
        let mimeType: String?
        let charset: String?
        let body: Data
        /// The body was longer than `byteLimit`, so its tail was never read.
        let isTruncated: Bool
    }

    enum ContentKind: Equatable, Sendable {
        case html, text
        /// No type, or `application/octet-stream`: the bytes decide.
        case unlabeled
    }

    static func handles(_ name: String) -> Bool { name == fetchName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: fetchName,
                description: "Fetch one web page and read it as text: its title, its words, and "
                    + "each link followed by its address. Use it for a URL the user gave or a web "
                    + "search found, not to guess addresses. Only http and https. HTML, plain "
                    + "text, JSON, XML and Markdown come back; images, PDFs and other files are "
                    + "refused. At most maxCharacters characters of text come back, and the "
                    + "answer says how much was cut. Blitz supplies this tool with the user's "
                    + "permission: the user may be asked to confirm and may decline, and an "
                    + "address on the user's own Mac or local network is always asked about.",
                parameters: AIToolJSON.object(
                    properties: [
                        "url": AIToolJSON.string(
                            "The page, a full http or https URL such as https://example.com/page."),
                        "maxCharacters": AIToolJSON.integer(
                            "How much text to return at most. Default: \(defaultCharacters); "
                                + "larger values are capped at \(characterLimit).")
                    ],
                    required: ["url"]),
                origin: origin, title: "Fetch Page")
        ]
    }

    // MARK: - Reading a call

    static func request(arguments: String) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        let url = try checkedURL(try arguments.requiredString("url"))
        guard arguments.contains("maxCharacters") else {
            return Request(url: url, maxCharacters: defaultCharacters)
        }
        guard let count = arguments.int("maxCharacters"), count >= 1 else {
            throw Invalid("\u{201C}maxCharacters\u{201D} must be a whole number from 1.")
        }
        return Request(url: url, maxCharacters: min(count, characterLimit))
    }

    /// An http or https URL with a host and no user name or password, else a sentence saying so.
    static func checkedURL(_ text: String) throws(AIToolArguments.Invalid) -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            throw Invalid(
                "\u{201C}url\u{201D} must be a full URL starting with http:// or https://, such "
                    + "as https://\(text).")
        }
        return try checked(url, scheme: scheme, named: "\u{201C}url\u{201D}")
    }

    private static func checked(
        _ url: URL, scheme: String, named: String
    ) throws(AIToolArguments.Invalid) -> URL {
        guard scheme == "http" || scheme == "https" else {
            throw Invalid("\(named) is a \(scheme): URL; web_fetch fetches http and https only.")
        }
        guard url.user(percentEncoded: false) == nil, url.password(percentEncoded: false) == nil
        else {
            throw Invalid(
                "\(named) carries a user name or password; web_fetch never sends credentials, so "
                    + "leave them out.")
        }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw Invalid("\(named) has no host name, such as example.com.")
        }
        return url
    }

    /// A redirect is checked like the call; one into the local network stays on the asked host.
    static func redirectTarget(
        _ location: String, from current: URL, approved: URL
    ) throws(Failure) -> URL {
        guard let target = URL(string: location, relativeTo: current)?.absoluteURL,
            let scheme = target.scheme?.lowercased()
        else {
            throw Failure("\(current.absoluteString) redirected to an address Blitz cannot read.")
        }
        let next: URL
        do throws(AIToolArguments.Invalid) {
            next = try checked(target, scheme: scheme, named: target.absoluteString)
        } catch {
            throw Failure(
                "\(current.absoluteString) redirected to \(target.absoluteString), which Blitz "
                    + "does not follow: \(error.message)")
        }
        let isSameHost =
            next.host(percentEncoded: false)?.lowercased()
            == approved.host(percentEncoded: false)?.lowercased()
        if LocalNetworkPolicy.isLocal(next), !isSameHost {
            throw Failure(
                "\(current.absoluteString) redirected to \(next.absoluteString), on this Mac or "
                    + "its local network; Blitz does not follow a redirect there. Fetch that URL "
                    + "itself if the user wants it, and they will be asked.")
        }
        return next
    }

    // MARK: - Asking

    static func prompt(for request: Request) -> AgentPrompt {
        .webFetch(
            host: shownHost(of: request.url), url: request.url.absoluteString,
            isLocalNetwork: request.isLocalNetwork)
    }

    /// The host as the reader would type it, with its port, and an IPv6 literal in brackets.
    static func shownHost(of url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        let named = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(named):\($0)" } ?? named
    }

    // MARK: - Content

    /// Nil for a type web_fetch refuses: images, PDFs, archives and every other binary.
    static func contentKind(of mimeType: String?) -> ContentKind? {
        guard let type = mimeType?.lowercased(), !type.isEmpty else { return .unlabeled }
        if type == "application/octet-stream" { return .unlabeled }
        if type == "text/html" || type == "application/xhtml+xml" { return .html }
        if type.hasPrefix("text/") || type.hasSuffix("+json") || type.hasSuffix("+xml") {
            return .text
        }
        let textual: Set<String> = [
            "application/json", "application/xml", "application/javascript",
            "application/x-javascript", "application/ecmascript", "application/yaml",
            "application/x-yaml", "application/toml", "application/x-ndjson",
            "application/markdown"
        ]
        return textual.contains(type) ? .text : nil
    }

    static func refusedType(_ mimeType: String, url: URL) -> Failure {
        Failure(
            "\(url.absoluteString) is \(mimeType), not a web page or text; web_fetch reads HTML, "
                + "text, JSON, XML and Markdown only.")
    }

    /// A byte-order mark first, then the header's charset, then a `<meta>` one; UTF-8 otherwise.
    static func decoded(_ body: Data, charset: String?, isHTML: Bool) -> String {
        let bytes = [UInt8](body)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return HTMLTextEngine.lossyText(bytes.dropFirst(3))
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
            let text = String(data: body, encoding: .utf16)
        {
            return text
        }
        let named = charset ?? (isHTML ? metaCharset(in: bytes.prefix(sniffSize)) : nil)
        if let named, let encoding = encoding(named: named), encoding != .utf8,
            let text = String(data: body, encoding: encoding)
        {
            return text
        }
        return HTMLTextEngine.lossyText(bytes)
    }

    /// As browsers read them, Latin-1 and ASCII labels mean Windows-1252.
    static func encoding(named name: String) -> String.Encoding? {
        let label = name.trimmingCharacters(in: .whitespaces).lowercased()
        if ["iso-8859-1", "latin1", "us-ascii", "ascii", "windows-1252"].contains(label) {
            return .windowsCP1252
        }
        let encoding = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    /// `<meta charset="…">` or `<meta http-equiv … content="…; charset=…">` near the top.
    static func metaCharset(in bytes: ArraySlice<UInt8>) -> String? {
        let head = HTMLTextEngine.lossyText(bytes).lowercased()
        var searchStart = head.startIndex
        while let meta = head.range(of: "<meta", range: searchStart..<head.endIndex) {
            let end = head[meta.upperBound...].firstIndex(of: ">") ?? head.endIndex
            let tag = head[meta.upperBound..<end]
            if let charset = tag.range(of: "charset=") {
                let value = tag[charset.upperBound...]
                    .drop { $0 == "\"" || $0 == "'" || $0 == " " }
                    .prefix { $0.isLetter || $0.isNumber || "-_:.".contains($0) }
                if !value.isEmpty { return String(value) }
            }
            searchStart = end
        }
        return nil
    }

    // MARK: - Answers

    /// The final URL, the status and the title first, then the text, cut at `maxCharacters`.
    static func answer(for page: Page, maxCharacters: Int) -> Result<String, Failure> {
        guard var kind = contentKind(of: page.mimeType) else {
            return .failure(refusedType(page.mimeType ?? "unlabeled", url: page.finalURL))
        }
        if kind == .unlabeled {
            let sample = page.body.prefix(sniffSize)
            guard !sample.contains(0) else {
                return .failure(
                    Failure(
                        "\(page.finalURL.absoluteString) did not say what it is, and it is not "
                            + "text; web_fetch reads HTML, text, JSON, XML and Markdown only."))
            }
            kind = looksLikeHTML(sample) ? .html : .text
        }
        let decoded = decoded(page.body, charset: page.charset, isHTML: kind == .html)
        let title: String?
        let text: String
        if kind == .html {
            let read = HTMLTextEngine.page(from: decoded, baseURL: page.finalURL)
            (title, text) = (read.title, read.text)
        } else {
            (title, text) = (nil, decoded.replacing("\r\n", with: "\n"))
        }
        var lines = ["URL: \(page.finalURL.absoluteString)"]
        if page.finalURL != page.requestedURL {
            lines.append("Redirected from: \(page.requestedURL.absoluteString)")
        }
        lines.append("Status: \(status(page.status))")
        if let mimeType = page.mimeType { lines.append("Type: \(mimeType)") }
        if let title { lines.append("Title: \(title)") }
        var answer = lines.joined(separator: "\n") + "\n\n"
        answer += text.isEmpty ? "[The page has no readable text.]" : clipped(text, to: maxCharacters)
        if page.isTruncated {
            answer += "\n[The page is larger than \(byteLimit / 1024 / 1024) MB; only its start "
                + "was read.]"
        }
        return .success(answer)
    }

    static func clipped(_ text: String, to maxCharacters: Int) -> String {
        let total = text.count
        guard total > maxCharacters else { return text }
        let more =
            maxCharacters < characterLimit
            ? " Fetch again with a larger maxCharacters, up to \(characterLimit), for more." : ""
        return String(text.prefix(maxCharacters))
            + "\n[Cut at \(maxCharacters) of \(total) characters; \(total - maxCharacters) more "
            + "were not shown.\(more)]"
    }

    private static func looksLikeHTML(_ sample: Data) -> Bool {
        let head = HTMLTextEngine.lossyText(sample.prefix(1024)).lowercased()
        return ["<!doctype html", "<html", "<head", "<body"].contains { head.contains($0) }
    }

    /// Fixed reasons, never the locale's, so the model and a harness read the same text.
    static func status(_ code: Int) -> String {
        let reasons = [
            200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
            204: "No Content", 206: "Partial Content", 300: "Multiple Choices",
            301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
            307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request",
            401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout",
            410: "Gone", 418: "I'm a teapot", 429: "Too Many Requests",
            451: "Unavailable For Legal Reasons", 500: "Internal Server Error",
            501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
            504: "Gateway Timeout"
        ]
        return reasons[code].map { "\(code) \($0)" } ?? "\(code)"
    }

    // MARK: - Failures

    static func tooManyRedirects(from url: URL) -> Failure {
        Failure(
            "\(url.absoluteString) redirected more than \(redirectLimit) times, so Blitz stopped "
                + "following it.")
    }

    static func timedOut(_ url: URL) -> Failure {
        Failure(
            "\(shownHost(of: url)) took longer than \(Int(totalTimeout)) seconds, so the fetch "
                + "was stopped.")
    }

    /// The network's error as a sentence; codes, never `localizedDescription`, decide the words.
    static func failure(for error: any Error, url: URL) -> Failure {
        let host = shownHost(of: url)
        guard let error = error as? URLError else {
            return error is CancellationError
                ? Failure("The fetch of \(url.absoluteString) was stopped.")
                : Failure("Could not fetch \(url.absoluteString).")
        }
        switch error.code {
        case .timedOut:
            return Failure("\(host) did not answer within \(Int(requestTimeout)) seconds.")
        case .cannotFindHost, .dnsLookupFailed:
            return Failure("No server called \(host) could be found.")
        case .cannotConnectToHost:
            return Failure("Could not connect to \(host).")
        case .notConnectedToInternet:
            return Failure("This Mac is not connected to the internet.")
        case .networkConnectionLost:
            return Failure("The connection to \(host) was lost.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
            .clientCertificateRequired, .clientCertificateRejected:
            return Failure(
                "The secure connection to \(host) failed, so nothing was fetched.")
        case .appTransportSecurityRequiresSecureConnection:
            return Failure(
                "macOS lets Blitz fetch \(url.absoluteString) only over https; try the https "
                    + "address instead.")
        case .cancelled:
            return Failure("The fetch of \(url.absoluteString) was stopped.")
        default:
            return Failure(
                "Could not fetch \(url.absoluteString) (URL error \(error.code.rawValue)).")
        }
    }
}
