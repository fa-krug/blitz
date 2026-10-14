import Foundation
import Synchronization

// The fetcher runs against `Stub`, a URLProtocol on its own session: nothing here reaches a network.
struct Route: Sendable {
    var status = 200
    var headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]
    var body = Data()
    var hangs = false
}

final class Stub: URLProtocol, @unchecked Sendable {
    static let routes = Mutex<[String: Route]>([:])
    static let seen = Mutex<[URLRequest]>([])

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(request) }
        guard let url = request.url, let route = Self.routes.withLock({ $0[url.absoluteString] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        guard !route.hangs else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
            headerFields: route.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct WebFetchTests {
    static func main() async {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        // MARK: Schema

        let tools = WebFetchToolCatalog.tools()
        check("one tool, web_fetch", tools.map(\.name) == ["web_fetch"])
        check("the catalog claims its name", WebFetchToolCatalog.handles("web_fetch"))
        check("and no other", !WebFetchToolCatalog.handles("files_read"))
        check(
            "the wire name maps to the Fetch Web Pages row",
            AgentTool(builtInToolName: "web_fetch") == .webFetch)
        check("so the row is hosted", AgentTool.webFetch.isHosted)
        let schema = tools.first?.parameters.objectValue
        check("only the url is required", schema?["required"] == .array([.string("url")]))
        check(
            "maxCharacters is an integer",
            schema?["properties"]?.objectValue?["maxCharacters"]?.objectValue?["type"]
                == .string("integer"))
        let description = tools.first?.description ?? ""
        check(
            "the description says the user may decline and local addresses ask",
            description.contains("may decline") && description.contains("local network"))
        check("the tool is a Web row", tools.first?.origin == "Web")
        check(
            "the wire name is pinned",
            AgentTool(wireName: WebFetchToolCatalog.fetchName) == .webFetch)

        // MARK: Reading a call

        typealias Reading = Result<WebFetchToolCatalog.Request, AIToolArguments.Invalid>
        func read(_ arguments: String) -> Reading {
            Result { () throws(AIToolArguments.Invalid) in
                try WebFetchToolCatalog.request(arguments: arguments)
            }
        }
        func refusal(_ arguments: String) -> String? {
            guard case .failure(let invalid) = read(arguments) else { return nil }
            return invalid.message
        }
        let plain = try? read(#"{"url":"https://example.com/a"}"#).get()
        check(
            "a URL with the default length",
            plain?.url.absoluteString == "https://example.com/a"
                && plain?.maxCharacters == WebFetchToolCatalog.defaultCharacters)
        check("the default is 20 000", WebFetchToolCatalog.defaultCharacters == 20_000)
        check(
            "a length is taken",
            (try? read(#"{"url":"https://example.com","maxCharacters":500}"#).get())?
                .maxCharacters == 500)
        check(
            "a length sent as text is taken",
            (try? read(#"{"url":"https://example.com","maxCharacters":"800"}"#).get())?
                .maxCharacters == 800)
        check(
            "a length past the cap is capped",
            (try? read(#"{"url":"https://example.com","maxCharacters":5000000}"#).get())?
                .maxCharacters == WebFetchToolCatalog.characterLimit)
        check("the cap is 100 000", WebFetchToolCatalog.characterLimit == 100_000)
        check(
            "a zero length is refused",
            refusal(#"{"url":"https://example.com","maxCharacters":0}"#)?
                .contains("whole number from 1") == true)
        check("a missing url is refused", refusal("{}")?.contains("is required") == true)
        check("garbage is refused", refusal("nope")?.contains("one JSON object") == true)
        check(
            "an ftp URL is refused naming the scheme",
            refusal(#"{"url":"ftp://example.com/file"}"#)?.contains("ftp: URL") == true)
        check(
            "a file URL is refused",
            refusal(#"{"url":"file:///etc/passwd"}"#)?.contains("http and https only") == true)
        check(
            "a javascript URL is refused",
            refusal(#"{"url":"javascript:alert(1)"}"#) != nil)
        check(
            "a URL with no scheme suggests https",
            refusal(#"{"url":"example.com/page"}"#)?.contains("https://example.com/page") == true)
        check(
            "a password in the URL is refused",
            refusal(#"{"url":"https://me:secret@example.com/"}"#)?.contains("user name or password")
                == true)
        check(
            "a user name alone is refused too",
            refusal(#"{"url":"https://me@example.com/"}"#)?.contains("never sends credentials")
                == true)
        check(
            "an empty host is refused",
            refusal(#"{"url":"https:///path"}"#)?.contains("no host name") == true)
        check(
            "an uppercase scheme is fine",
            (try? read(#"{"url":"HTTPS://Example.com/"}"#).get()) != nil)

        // MARK: The local-network classifier

        func local(_ url: String) -> Bool { LocalNetworkPolicy.isLocal(URL(string: url)!) }
        for url in [
            "http://localhost/", "http://LOCALHOST:8080/", "http://localhost./",
            "http://app.localhost/", "http://printer.local/", "http://nas.home.arpa/",
            "http://wiki.internal/",
            "http://127.0.0.1/", "http://127.8.9.10/", "http://10.0.0.1/", "http://10.255.1.1/",
            "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.1.20:8080/",
            "http://169.254.169.254/latest/meta-data/", "http://0.0.0.0/", "http://100.64.0.1/",
            "http://127.1/", "http://0x7f.0.0.1/", "http://2130706433/", "http://017700000001/",
            "http://[::1]/", "http://[::]/", "http://[fe80::1%25en0]/", "http://[fd12:3456::1]/",
            "http://[fc00::1]/", "http://[::ffff:192.168.0.1]/", "http://[::ffff:7f00:1]/",
            "http://[fec0::1]/"
        ] {
            check("\(url) is local", local(url))
        }
        for url in [
            "https://example.com/", "https://8.8.8.8/", "https://172.32.0.1/",
            "https://172.15.255.255/", "https://192.169.0.1/", "https://100.128.0.1/",
            "https://11.0.0.1/", "https://[2001:4860:4860::8888]/", "https://[::ffff:8.8.8.8]/",
            "https://localhost.example.com/", "https://local.example/", "https://1e100.net/",
            "https://example.localdomain.com/", "https://10.example.com/"
        ] {
            check("\(url) is not local", !local(url))
        }
        check("an empty host counts as local", LocalNetworkPolicy.isLocal(host: ""))
        check(
            "inet_aton forms parse",
            LocalNetworkPolicy.ipv4("127.1") == 0x7F00_0001
                && LocalNetworkPolicy.ipv4("10.1.2") == 0x0A01_0002
                && LocalNetworkPolicy.ipv4("0300.0250.1.1") == 0xC0A8_0101)
        check(
            "out-of-range parts are no address",
            LocalNetworkPolicy.ipv4("256.1.1.1") == nil
                && LocalNetworkPolicy.ipv4("1.2.3.4.5") == nil
                && LocalNetworkPolicy.ipv4("4294967296") == nil
                && LocalNetworkPolicy.ipv4("1..2") == nil)
        check(
            "a request knows when it is local",
            (try? read(#"{"url":"http://192.168.0.2/admin"}"#).get())?.isLocalNetwork == true
                && plain?.isLocalNetwork == false)

        // MARK: Policy

        func decide(
            _ call: AgentCall, _ decision: AgentDecision, mode: AgentMode = .manual,
            granted: Bool = false
        ) -> AgentDecision {
            var scope = AgentSessionScope()
            scope.mode = mode
            if granted { scope.grant(.webFetch) }
            return AgentPolicy.decision(
                for: call, rules: AgentRules([.webFetch: decision]), mcpTrust: { _ in .deny },
                scope: scope)
        }
        let publicCall = AgentCall.webFetch(isLocalNetwork: false)
        let localCall = AgentCall.webFetch(isLocalNetwork: true)
        check("a public fetch on Allow runs", decide(publicCall, .allow) == .allow)
        check("a public fetch on Ask asks", decide(publicCall, .ask) == .ask)
        check("a local fetch on Allow asks", decide(localCall, .allow) == .ask)
        check("a local fetch on Ask asks", decide(localCall, .ask) == .ask)
        check("a local fetch on Deny is denied", decide(localCall, .deny) == .deny)
        check("Auto runs a public fetch", decide(publicCall, .ask, mode: .auto) == .allow)
        check(
            "Auto still asks before a local fetch",
            decide(localCall, .ask, mode: .auto) == .ask
                && decide(localCall, .allow, mode: .auto) == .ask)
        check("Auto never lifts a Deny", decide(localCall, .deny, mode: .auto) == .deny)
        check(
            "a chat grant answers a public fetch, never a local one",
            decide(publicCall, .ask, granted: true) == .allow
                && decide(localCall, .ask, granted: true) == .ask)
        check(
            "Plan keeps a public fetch at its row and asks a local one",
            decide(publicCall, .allow, mode: .plan) == .allow
                && decide(publicCall, .ask, mode: .plan) == .ask
                && decide(localCall, .allow, mode: .plan) == .ask)
        var plan = AgentSessionScope()
        plan.mode = .plan
        check(
            "Plan offers web fetch, which only looks",
            AgentPolicy.isOffered(
                .webFetch, rules: AgentRules([.webFetch: .ask]), mcpTrust: { _ in .deny },
                scope: plan) && localCall.isReadOnly)
        check(
            "a Deny row is not offered",
            !AgentPolicy.isOffered(
                .webFetch, rules: AgentRules([.webFetch: .deny]), mcpTrust: { _ in .deny },
                scope: AgentSessionScope()))
        check("the bare row is not a local call", !AgentCall(tool: .webFetch).isLocalNetwork)

        // MARK: The dialog

        let publicPrompt = WebFetchToolCatalog.prompt(
            for: .init(url: URL(string: "https://example.com/docs?q=1")!, maxCharacters: 10))
        check("the title names the host", publicPrompt.title == "Let the agent open example.com?")
        check(
            "the message has the full URL and the provider",
            publicPrompt.message?.contains("https://example.com/docs?q=1") == true
                && publicPrompt.message?.contains("provider") == true)
        check(
            "a public page may be allowed for the chat",
            publicPrompt.choices == [.allowOnce("Allow"), .allowThisChat, .refuse("Don't Allow")]
                && publicPrompt.defaultIndex == 0)
        let localPrompt = WebFetchToolCatalog.prompt(
            for: .init(url: URL(string: "http://[::1]:8080/")!, maxCharacters: 10))
        check("a local title shows the port", localPrompt.title == "Let the agent open [::1]:8080?")
        check(
            "a local page is asked each time",
            localPrompt.choices == [.allowOnce("Allow"), .refuse("Don't Allow")])
        check(
            "and the dialog says it is local",
            localPrompt.message?.contains("local network") == true)
        check(
            "no Always Allow is offered",
            !publicPrompt.choices.contains { $0.title.hasPrefix("Always") })

        // MARK: HTML to text

        let base = URL(string: "https://example.com/docs/page.html")!
        let html = """
            <!DOCTYPE html>
            <html><head>
            <meta charset="utf-8"><title>  Caf&eacute; &amp; Co  </title>
            <style>body { color: red; } .x > p { }</style>
            <script>var s = "</div> secret"; if (a < b) {}</script>
            </head>
            <body>
            <!-- a comment -->
            <noscript>Enable JS</noscript>
            <svg><title>Icon</title><path d="M0"/></svg>
            <h1>Hello&nbsp;world</h1>
            <p>Fish &lt;&gt; chips &#8212; &#x1F600; &unknown; a&b
               spread   across lines.</p>
            <ul><li>One</li><li><a href="/two">Two</a></li><li><p>Three</p></li></ul>
            <p>See <a href="https://other.org/x">the other site</a>, or
            <a href="#top">top</a> or <a href="javascript:void(0)">nothing</a>
            or <a href="sub/more.html">more</a> or <a href="https://same.org/">https://same.org/</a>.</p>
            <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
            <pre>  keep
                spaces</pre>
            line<br>break
            <template><p>Hidden template</p></template>
            </body></html>
            """
        let read = HTMLTextEngine.page(from: html, baseURL: base)
        check("the title is kept, decoded and trimmed", read.title == "Café & Co")
        check("the svg's own title is not the page's", read.title != "Icon")
        check("scripts are dropped", !read.text.contains("secret") && !read.text.contains("var s"))
        check("styles are dropped", !read.text.contains("color: red"))
        check("comments are dropped", !read.text.contains("a comment"))
        check("noscript is dropped", !read.text.contains("Enable JS"))
        check("svg is dropped", !read.text.contains("Icon"))
        check("templates are dropped", !read.text.contains("Hidden template"))
        check("the title is not repeated in the text", !read.text.contains("Café"))
        check("the heading is a line of its own", read.text.hasPrefix("Hello world\n\n"))
        check(
            "entities are decoded",
            read.text.contains("Fish <> chips \u{2014} \u{1F600} &unknown; a&b"))
        check("whitespace is collapsed", read.text.contains("a&b spread across lines."))
        check(
            "list items become dashes, links absolutised",
            read.text.contains("- One\n- Two (https://example.com/two)\n- Three"))
        check(
            "a link keeps its text and URL",
            read.text.contains("See the other site (https://other.org/x), or"))
        check(
            "in-page and script links keep only their text",
            read.text.contains("top or nothing or"))
        check(
            "a relative link resolves against the page",
            read.text.contains("more (https://example.com/docs/sub/more.html)"))
        check(
            "a link whose text is its URL is not repeated",
            read.text.contains("or https://same.org/.") && !read.text.contains("(https://same.org/)"))
        check("table cells are separated", read.text.contains("A | B\n1 | 2"))
        check("pre keeps its spaces", read.text.contains("  keep\n    spaces"))
        check("br breaks the line", read.text.contains("line\nbreak"))
        check("no line ends in a space", !read.text.contains(" \n"))
        check("no run of blank lines", !read.text.contains("\n\n\n"))

        let based = HTMLTextEngine.page(
            from: #"<head><base href="https://cdn.example.net/root/"></head><a href="x">X</a>"#,
            baseURL: base)
        check("<base href> moves the base", based.text == "X (https://cdn.example.net/root/x)")
        let headless = HTMLTextEngine.page(
            from: "<html><head><title>T</title><meta x><p>Body text", baseURL: base)
        check(
            "a start tag that cannot be in head ends it",
            headless.title == "T" && headless.text == "Body text")
        let bare = HTMLTextEngine.page(from: "1 < 2 and 3 > 2 <3", baseURL: nil)
        check("a lone < is text", bare.text == "1 < 2 and 3 > 2 <3")
        check(
            "a quoted > does not end a tag",
            HTMLTextEngine.page(from: #"<a title="x > y" href="/z">Z</a>"#, baseURL: base).text
                == "Z (https://example.com/z)")
        check(
            "an unclosed script swallows only itself",
            HTMLTextEngine.page(from: "Before<script>var x = 1;", baseURL: nil).text == "Before")
        check(
            "nested svg is dropped whole",
            HTMLTextEngine.page(from: "<svg><svg></svg>in</svg>out", baseURL: nil).text == "out")
        check(
            "numeric references to 128–159 are Windows-1252",
            HTMLTextEngine.collapsed("&#150; &#147;x&#148;") == "\u{2013} \u{201C}x\u{201D}")
        check("an invalid reference is a replacement", HTMLTextEngine.collapsed("&#0;") == "\u{FFFD}")
        check(
            "an empty list item still breaks the line",
            HTMLTextEngine.page(from: "<ul><li></li><li>B</li></ul>", baseURL: nil).text
                == "-\n- B")
        check(
            "mailto links keep their address",
            HTMLTextEngine.page(from: #"<a href="mailto:a@b.c">Mail us</a>"#, baseURL: base).text
                == "Mail us (mailto:a@b.c)")

        // MARK: Content types

        check("html is html", WebFetchToolCatalog.contentKind(of: "text/html") == .html)
        check("xhtml is html", WebFetchToolCatalog.contentKind(of: "application/xhtml+xml") == .html)
        for type in [
            "text/plain", "text/markdown", "text/csv", "application/json", "application/ld+json",
            "application/xml", "application/rss+xml", "text/xml", "application/yaml"
        ] {
            check("\(type) passes through", WebFetchToolCatalog.contentKind(of: type) == .text)
        }
        for type in [
            "image/png", "application/pdf", "application/zip", "video/mp4", "audio/mpeg",
            "font/woff2", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        ] {
            check("\(type) is refused", WebFetchToolCatalog.contentKind(of: type) == nil)
        }
        check(
            "no type, or octet-stream, is sniffed",
            WebFetchToolCatalog.contentKind(of: nil) == .unlabeled
                && WebFetchToolCatalog.contentKind(of: "application/octet-stream") == .unlabeled)
        check(
            "a refusal names the type",
            WebFetchToolCatalog.refusedType("image/png", url: base).message.contains("image/png"))

        func page(
            _ body: String, type: String? = "text/html", status: Int = 200,
            truncated: Bool = false, from: URL = base, at: URL = base
        ) -> WebFetchToolCatalog.Page {
            WebFetchToolCatalog.Page(
                requestedURL: from, finalURL: at, status: status, mimeType: type, charset: nil,
                body: Data(body.utf8), isTruncated: truncated)
        }
        func answer(_ page: WebFetchToolCatalog.Page, max: Int = 20_000) -> String? {
            try? WebFetchToolCatalog.answer(for: page, maxCharacters: max).get()
        }
        let htmlAnswer = answer(page("<title>Doc</title><p>Body</p>"))
        check(
            "the answer starts with the URL, status, type and title",
            htmlAnswer
                == "URL: \(base.absoluteString)\nStatus: 200 OK\nType: text/html\nTitle: Doc\n\nBody")
        let moved = answer(page("x", type: "text/plain", from: URL(string: "http://a.com")!))
        check(
            "a redirected answer names where it started",
            moved?.contains("Redirected from: http://a.com") == true)
        check(
            "a 404 carries its status",
            answer(page("<p>gone</p>", status: 404))?.contains("Status: 404 Not Found") == true)
        check("an unknown status is its number", WebFetchToolCatalog.status(599) == "599")
        check(
            "JSON passes through untouched",
            answer(page(#"{"a": [1, 2]}"#, type: "application/json"))?
                .hasSuffix("\n\n{\"a\": [1, 2]}") == true)
        check(
            "markdown passes through with its markup",
            answer(page("# Title\n\n- item", type: "text/markdown"))?.hasSuffix("# Title\n\n- item")
                == true)
        check(
            "an unlabeled HTML body is read as HTML",
            answer(page("<!doctype html><title>U</title><p>hi", type: nil))?.contains("Title: U")
                == true)
        check(
            "an unlabeled text body passes through",
            answer(page("just text", type: nil))?.hasSuffix("\n\njust text") == true)
        let binary = WebFetchToolCatalog.Page(
            requestedURL: base, finalURL: base, status: 200, mimeType: nil, charset: nil,
            body: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0]), isTruncated: false)
        check(
            "an unlabeled binary body is refused",
            (try? WebFetchToolCatalog.answer(for: binary, maxCharacters: 10).get()) == nil)
        check(
            "an image page is refused at the answer too",
            (try? WebFetchToolCatalog.answer(for: page("x", type: "image/png"), maxCharacters: 10)
                .get()) == nil)
        check(
            "an empty page says so",
            answer(page("<script>x</script>"))?.hasSuffix("[The page has no readable text.]")
                == true)

        // MARK: Clipping

        let long = String(repeating: "a", count: 150)
        let clipped = WebFetchToolCatalog.clipped(long, to: 100)
        check(
            "the text is cut at maxCharacters with a note",
            clipped.hasPrefix(String(repeating: "a", count: 100) + "\n[Cut at 100 of 150 characters; 50 more")
                && clipped.contains("larger maxCharacters"))
        check("short text is untouched", WebFetchToolCatalog.clipped("abc", to: 100) == "abc")
        check(
            "at the cap there is no larger maxCharacters to suggest",
            !WebFetchToolCatalog.clipped(
                String(repeating: "b", count: 100_001), to: 100_000
            ).contains("larger maxCharacters"))
        check(
            "characters, not bytes, are counted",
            WebFetchToolCatalog.clipped("ééééé", to: 3).hasPrefix("ééé\n[Cut at 3 of 5"))
        check(
            "a truncated body says so",
            answer(page("<p>x", truncated: true))?.contains("larger than 5 MB") == true)

        // MARK: Charsets

        let latin = Data([0x63, 0x61, 0x66, 0xE9])
        check(
            "a header charset decodes",
            WebFetchToolCatalog.decoded(latin, charset: "ISO-8859-1", isHTML: false) == "café")
        check(
            "a meta charset decodes when the header has none",
            WebFetchToolCatalog.decoded(
                Data(#"<meta charset="windows-1252"><p>"#.utf8) + latin, charset: nil, isHTML: true)
                .hasSuffix("café"))
        check(
            "an http-equiv charset is read",
            WebFetchToolCatalog.metaCharset(
                in: Array(#"<META http-equiv="Content-Type" content="text/html; charset=Shift_JIS">"#.utf8)[...])
                == "shift_jis")
        check(
            "invalid UTF-8 falls back lossily",
            WebFetchToolCatalog.decoded(latin, charset: nil, isHTML: false) == "caf\u{FFFD}")
        check(
            "an unknown charset falls back to UTF-8",
            WebFetchToolCatalog.decoded(Data("ok".utf8), charset: "x-made-up", isHTML: false) == "ok")
        check(
            "a byte-order mark wins",
            WebFetchToolCatalog.decoded(
                Data([0xEF, 0xBB, 0xBF]) + Data("é".utf8), charset: "iso-8859-1", isHTML: false)
                == "é")
        check(
            "UTF-16 with a mark decodes",
            WebFetchToolCatalog.decoded(
                Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]), charset: nil, isHTML: false) == "hi")

        // MARK: Redirect targets

        func target(
            _ location: String, from: String, approved: String? = nil
        ) -> Result<URL, WebFetchToolCatalog.Failure> {
            Result { () throws(WebFetchToolCatalog.Failure) in
                try WebFetchToolCatalog.redirectTarget(
                    location, from: URL(string: from)!, approved: URL(string: approved ?? from)!)
            }
        }
        check(
            "a relative redirect resolves",
            (try? target("/b?x=1", from: "https://a.com/x/y").get())?.absoluteString
                == "https://a.com/b?x=1")
        check(
            "a redirect to another scheme is refused",
            (try? target("ftp://a.com/", from: "https://a.com/").get()) == nil)
        check(
            "a redirect carrying credentials is refused",
            (try? target("https://u:p@a.com/", from: "https://a.com/").get()) == nil)
        check(
            "a redirect into the local network is refused",
            (try? target("http://192.168.0.1/", from: "https://a.com/").get()) == nil)
        if case .failure(let failure) = target("http://localhost/", from: "https://a.com/") {
            check(
                "and the sentence says to fetch it directly",
                failure.message.contains("local network") && failure.message.contains("asked"))
        } else {
            check("a redirect to localhost is refused", false)
        }
        check(
            "a local page may redirect on its own host",
            (try? target("/login", from: "http://192.168.0.5/", approved: "http://192.168.0.5/")
                .get())?.absoluteString == "http://192.168.0.5/login")
        check(
            "but not to another local host",
            (try? target("http://10.0.0.1/", from: "http://192.168.0.5/").get()) == nil)

        // MARK: The fetcher, against the stub

        let configuration = WebFetchRunner.configuration()
        check("the session caches nothing", configuration.urlCache == nil)
        check(
            "and keeps no cookies",
            configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies)
        check(
            "and stores no credentials", configuration.urlCredentialStorage == nil)
        check(
            "the timeouts are 15 s idle and 30 s in all",
            configuration.timeoutIntervalForRequest == 15
                && configuration.timeoutIntervalForResource == 30)
        check("the user agent names Blitz", WebFetchRunner.userAgent.contains("Blitz"))
        check("at most 5 redirects", WebFetchToolCatalog.redirectLimit == 5)
        check("at most 5 MB", WebFetchToolCatalog.byteLimit == 5 * 1024 * 1024)
        configuration.protocolClasses = [Stub.self]
        let session = WebFetchRunner.makeSession(configuration)

        func route(_ url: String, _ route: Route) {
            Stub.routes.withLock { $0[url] = route }
        }
        func redirect(_ from: String, to: String, status: Int = 302) {
            route(from, Route(status: status, headers: ["Location": to], body: Data()))
        }
        func fetch(
            _ url: String, max: Int = 20_000, timeout: TimeInterval = 10,
            byteLimit: Int = WebFetchToolCatalog.byteLimit
        ) async -> Result<WebFetchToolCatalog.Page, WebFetchToolCatalog.Failure> {
            await WebFetchRunner.fetch(
                .init(url: URL(string: url)!, maxCharacters: max), session: session,
                totalTimeout: timeout, byteLimit: byteLimit)
        }

        route(
            "https://site.test/", Route(body: Data("<title>Home</title><p>Welcome</p>".utf8)))
        if case .success(let home) = await fetch("https://site.test/") {
            check("a page comes back with its status", home.status == 200)
            check("and its type", home.mimeType == "text/html" && home.charset == "utf-8")
            check("unredirected, it ends where it started", home.finalURL == home.requestedURL)
        } else {
            check("a page comes back", false)
        }
        let sent = Stub.seen.withLock { $0.last }
        check(
            "the request names Blitz",
            sent?.value(forHTTPHeaderField: "User-Agent")?.contains("Blitz") == true)

        redirect("https://site.test/old", to: "/new")
        route("https://site.test/new", Route(body: Data("<p>New</p>".utf8)))
        if case .success(let followed) = await fetch("https://site.test/old") {
            check(
                "a redirect is followed and reported",
                followed.finalURL.absoluteString == "https://site.test/new"
                    && followed.requestedURL.absoluteString == "https://site.test/old")
        } else {
            check("a redirect is followed", false)
        }
        for hop in 0..<6 {
            redirect("https://loop.test/\(hop)", to: "https://loop.test/\(hop + 1)", status: 301)
        }
        route("https://loop.test/6", Route(body: Data("end".utf8)))
        if case .failure(let failure) = await fetch("https://loop.test/0") {
            check("a sixth redirect is refused", failure.message.contains("more than 5 times"))
        } else {
            check("a sixth redirect is refused", false)
        }
        if case .success(let fifth) = await fetch("https://loop.test/1") {
            check("five redirects are followed", fifth.finalURL.absoluteString == "https://loop.test/6")
        } else {
            check("five redirects are followed", false)
        }
        redirect("https://site.test/ftp", to: "ftp://site.test/file")
        if case .failure(let failure) = await fetch("https://site.test/ftp") {
            check("a redirect to ftp is refused", failure.message.contains("does not follow"))
        } else {
            check("a redirect to ftp is refused", false)
        }
        redirect("https://site.test/inside", to: "http://127.0.0.1:631/")
        if case .failure(let failure) = await fetch("https://site.test/inside") {
            check("a redirect into the local network is refused", failure.message.contains("local"))
        } else {
            check("a redirect into the local network is refused", false)
        }
        route("https://site.test/nolocation", Route(status: 302, headers: [:]))
        if case .success(let unmoved) = await fetch("https://site.test/nolocation") {
            check("a 3xx with no Location is the answer", unmoved.status == 302)
        } else {
            check("a 3xx with no Location is the answer", false)
        }

        route(
            "https://site.test/cookie",
            Route(headers: ["Content-Type": "text/plain", "Set-Cookie": "id=1; Path=/"]))
        _ = await fetch("https://site.test/cookie")
        _ = await fetch("https://site.test/")
        check(
            "a cookie set is never sent back",
            Stub.seen.withLock { $0.last }?.value(forHTTPHeaderField: "Cookie") == nil)

        route(
            "https://site.test/big",
            Route(headers: ["Content-Type": "text/plain"], body: Data(repeating: 0x61, count: 3000)))
        if case .success(let big) = await fetch("https://site.test/big", byteLimit: 1000) {
            check(
                "the body stops at the byte cap",
                big.body.count == 1000 && big.isTruncated)
        } else {
            check("the body stops at the byte cap", false)
        }
        if case .success(let whole) = await fetch("https://site.test/big", byteLimit: 3000) {
            check("a body at the cap is whole", whole.body.count == 3000 && !whole.isTruncated)
        } else {
            check("a body at the cap is whole", false)
        }

        route(
            "https://site.test/image.png",
            Route(headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50])))
        if case .failure(let failure) = await fetch("https://site.test/image.png") {
            check("an image is refused naming its type", failure.message.contains("image/png"))
        } else {
            check("an image is refused", false)
        }
        route(
            "https://site.test/doc.pdf",
            Route(headers: ["Content-Type": "application/pdf"], body: Data("%PDF".utf8)))
        if case .failure(let failure) = await fetch("https://site.test/doc.pdf") {
            check("a PDF is refused naming its type", failure.message.contains("application/pdf"))
        } else {
            check("a PDF is refused", false)
        }

        route(
            "https://site.test/latin",
            Route(headers: ["Content-Type": "text/html; charset=iso-8859-1"],
                body: Data("<p>".utf8) + latin))
        let latinAnswer = await WebFetchRunner.run(
            .init(url: URL(string: "https://site.test/latin")!, maxCharacters: 100),
            session: session)
        check(
            "the header's charset decodes the body",
            (try? latinAnswer.get())?.hasSuffix("café") == true)
        route(
            "https://site.test/meta",
            Route(headers: ["Content-Type": "text/html"],
                body: Data(#"<meta charset="iso-8859-1"><p>"#.utf8) + latin))
        let metaAnswer = await WebFetchRunner.run(
            .init(url: URL(string: "https://site.test/meta")!, maxCharacters: 100),
            session: session)
        check(
            "a meta charset decodes the body",
            (try? metaAnswer.get())?.hasSuffix("café") == true)

        route(
            "https://site.test/missing",
            Route(status: 404, body: Data("<title>Nope</title><p>Not here</p>".utf8)))
        let missing = await WebFetchRunner.run(
            .init(url: URL(string: "https://site.test/missing")!, maxCharacters: 100),
            session: session)
        check(
            "a 404 comes back with its status and text",
            (try? missing.get()).map {
                $0.contains("Status: 404 Not Found") && $0.contains("Title: Nope")
                    && $0.hasSuffix("Not here")
            } == true)
        route(
            "https://site.test/long",
            Route(headers: ["Content-Type": "text/plain"],
                body: Data(String(repeating: "z", count: 500).utf8)))
        let long500 = await WebFetchRunner.run(
            .init(url: URL(string: "https://site.test/long")!, maxCharacters: 100),
            session: session)
        check(
            "the answer is clipped to maxCharacters",
            (try? long500.get())?.contains("[Cut at 100 of 500 characters; 400 more") == true)

        route("https://slow.test/", Route(hangs: true))
        let started = Date()
        if case .failure(let failure) = await fetch("https://slow.test/", timeout: 0.5) {
            check("a page that never answers times out", failure.message.contains("longer than"))
            check("on the total clock", Date().timeIntervalSince(started) < 5)
        } else {
            check("a page that never answers times out", false)
        }
        if case .failure(let failure) = await fetch("https://nowhere.test/") {
            check("a host that is not there is a sentence", failure.message.contains("nowhere.test"))
        } else {
            check("a host that is not there fails", false)
        }
        check(
            "ATS's refusal suggests https",
            WebFetchToolCatalog.failure(
                for: URLError(.appTransportSecurityRequiresSecureConnection),
                url: URL(string: "http://plain.example/")!
            ).message.contains("https"))

        print(failures == 0 ? "\nAll web fetch tests passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
