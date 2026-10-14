import Foundation

/// How a chat model asks Blitz to open an app, a file or folder, or a web or mail link.
enum OpenToolCatalog {
    static let origin = "Mac"
    static let openName = "mac_open"
    /// Anything else could hand an app an action of its own, such as a `shortcuts:` run.
    static let schemes: Set<String> = ["http", "https", "mailto"]

    private typealias Invalid = AIToolArguments.Invalid

    /// A call, already checked; a path is absolute and canonical, not yet resolved on disk.
    enum Target: Equatable, Sendable {
        case app(String)
        case path(String)
        case url(URL)
    }

    /// An installed app as the launcher's index holds it.
    struct App: Equatable, Sendable {
        let name: String
        let alternateNames: [String]
        let bundleID: String?
        let path: String
    }

    /// What a resolved path is, which decides the dialog and whether it may be opened at all.
    enum ItemKind: Equatable, Sendable {
        case file, folder, app
    }

    /// Why opening a file of this extension would do more than show it.
    enum Hazard: Equatable, Sendable {
        case runs, installs, links
    }

    /// Opening one runs code, installs into macOS, or follows an address that could be anything.
    static let hazards: [String: Hazard] = {
        let runs = [
            "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "ksh", "tcsh", "fish",
            "py", "pyw", "pyc", "rb", "pl", "php", "jar", "jnlp", "workflow", "action"
        ]
        let installs = [
            "pkg", "mpkg", "mobileconfig", "prefpane", "saver", "qlgenerator", "mdimporter",
            "kext", "dext", "systemextension", "appex", "plugin", "bundle", "osax", "component",
            "xpc", "shortcut", "wdgt"
        ]
        let links = ["webloc", "inetloc", "fileloc", "url"]
        return Dictionary(
            uniqueKeysWithValues: runs.map { ($0, Hazard.runs) }
                + installs.map { ($0, Hazard.installs) } + links.map { ($0, Hazard.links) })
    }()

    static func handles(_ name: String) -> Bool { name == openName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: openName,
                description: "Open something on the user's Mac, as double-clicking it would: an "
                    + "app by its name or bundle id (it launches or comes forward), a file or "
                    + "folder by its path (in its default app, or in Finder), or an http, https "
                    + "or mailto link (in the default browser or mail app; a mail is never "
                    + "sent). Scripts, installers and other files that would run or install "
                    + "something are refused. The user may be asked to confirm, and may decline.",
                parameters: AIToolJSON.object(
                    properties: [
                        "target": AIToolJSON.string(
                            "An app's name or bundle id, such as Safari or com.apple.Safari; a "
                                + "path starting with / or ~; or a link starting with https://, "
                                + "http:// or mailto:.")
                    ],
                    required: ["target"]),
                origin: origin, title: "Open")
        ]
    }

    static func target(
        arguments: String, homeDirectory: String
    ) throws(AIToolArguments.Invalid) -> Target {
        let text = try AIToolArguments(arguments).requiredString("target")
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return .path(FileToolCatalog.absolute(text, homeDirectory: homeDirectory))
        }
        guard let scheme = scheme(of: text) else { return .app(text) }
        return .url(try link(text, scheme: scheme))
    }

    /// Lowercased, from text that starts like a URL; nil reads the text as an app's name.
    static func scheme(of text: String) -> String? {
        text.prefixMatch(of: /([A-Za-z][A-Za-z0-9+.\-]*):/).map { $0.1.lowercased() }
    }

    private static func link(_ text: String, scheme: String) throws(Invalid) -> URL {
        guard scheme != "file" else {
            throw Invalid("To open a file, give its path, such as ~/Documents/report.pdf.")
        }
        guard schemes.contains(scheme) else {
            throw Invalid(
                "Only http, https and mailto links can be opened: a \(scheme): link can make an "
                    + "app act on its own.")
        }
        guard let url = URL(string: text) else {
            throw Invalid("\u{201C}\(text)\u{201D} is not a link Blitz can read.")
        }
        if scheme == "mailto" {
            guard !text.dropFirst("mailto:".count).isEmpty else {
                throw Invalid(
                    "A mailto link names who the mail is to, such as mailto:ada@example.com.")
            }
            return url
        }
        guard let host = url.host(), !host.isEmpty else {
            throw Invalid("\u{201C}\(text)\u{201D} has no host.")
        }
        guard url.user() == nil, url.password() == nil else {
            throw Invalid("A link with a user name or password in it is not opened.")
        }
        return url
    }

    // MARK: - Apps

    static func match(_ name: String, among apps: [App]) -> AgentNameMatch<App> {
        let wanted = AgentNameMatch<App>.folded(name)
        if let byID = apps.first(where: { $0.bundleID.map(AgentNameMatch<App>.folded) == wanted }) {
            return .found(byID)
        }
        let bare = wanted.hasSuffix(".app") ? String(wanted.dropLast(4)) : wanted
        return AgentNameMatch.match(bare, among: apps) { [$0.name] + $0.alternateNames }
    }

    /// The one installed app answering to the name, or a refusal naming what it might have meant.
    static func app(named name: String, in apps: [App]) throws(AIToolArguments.Invalid) -> App {
        switch match(name, among: apps) {
        case .found(let app): return app
        case .ambiguous(let apps):
            throw Invalid(
                "More than one app is called \u{201C}\(name)\u{201D}: "
                    + apps.map(described).joined(separator: "; ")
                    + ". Name the one to open by its bundle id.")
        case .missing(let near):
            let similar = near.map(described).joined(separator: "; ")
            let guesses = near.isEmpty ? "" : " Installed apps with a similar name: \(similar)."
            throw Invalid(
                "No app called \u{201C}\(name)\u{201D} is installed.\(guesses) "
                    + "\(openName) also takes a path starting with / or ~, or a link starting "
                    + "with https://, http:// or mailto:.")
        }
    }

    private static func described(_ app: App) -> String {
        app.bundleID.map { "\(app.name) (\($0))" } ?? "\(app.name) at \(app.path)"
    }

    // MARK: - Paths

    /// Nil when the item may be opened; `isProgram` is a file with no extension that may run.
    static func refusal(forPath path: String, isProgram: Bool, homeDirectory: String) -> String? {
        let shown = FileToolCatalog.shown(path, homeDirectory: homeDirectory)
        let ext = (path as NSString).pathExtension.lowercased()
        switch hazards[ext] {
        case .runs:
            return "Opening \(shown) would run it, so \(openName) never opens a .\(ext) file."
        case .installs:
            return "Opening \(shown) would install it into macOS, so \(openName) never opens a "
                + ".\(ext) file."
        case .links:
            return "\(shown) is a link file that can point anywhere, so \(openName) never opens a "
                + ".\(ext) file; open the address in it instead."
        case nil:
            guard isProgram else { return nil }
            return "\(shown) is a program: opening it would run it in Terminal, so \(openName) "
                + "does not open it."
        }
    }

    /// An app is a folder named `.app`; a pipe, a device or a socket is never opened.
    static func kind(
        of path: String, isFolder: Bool, isFile: Bool, homeDirectory: String
    ) -> Result<ItemKind, FileToolCatalog.Failure> {
        if isFolder {
            return .success((path as NSString).pathExtension.lowercased() == "app" ? .app : .folder)
        }
        guard isFile else {
            let shown = FileToolCatalog.shown(path, homeDirectory: homeDirectory)
            return .failure(FileToolCatalog.Failure("\(shown) is not a file or a folder."))
        }
        return .success(.file)
    }

    static func missing(_ path: String, homeDirectory: String) -> String {
        "There is nothing at \(FileToolCatalog.shown(path, homeDirectory: homeDirectory))."
    }

    /// Asked again once the dialog closes, so a path swapped for a link while it was up is refused.
    static func changed(_ path: String, homeDirectory: String) -> String {
        "\(FileToolCatalog.shown(path, homeDirectory: homeDirectory)) changed while the user was "
            + "asked, so nothing was opened."
    }

    // MARK: - Dialogs and answers

    static func prompt(forApp app: App) -> AgentPrompt {
        AgentPrompt.open(
            app.name,
            detail: "It launches \(app.name), or brings it forward if it is running.")
    }

    static func prompt(forPath path: String, kind: ItemKind, homeDirectory: String) -> AgentPrompt {
        let detail =
            switch kind {
            case .file: "It opens in its default app."
            case .folder: "It opens in Finder."
            case .app: "It launches the app, or brings it forward if it is running."
            }
        return AgentPrompt.open(
            FileToolCatalog.shown(path, homeDirectory: homeDirectory), detail: detail)
    }

    static func prompt(forURL url: URL) -> AgentPrompt {
        guard url.scheme?.lowercased() == "mailto" else {
            return AgentPrompt.open(
                "\(url.host() ?? url.absoluteString) in your browser",
                detail: "\(url.absoluteString)\n\nIt opens in your default browser.")
        }
        let address = String(url.absoluteString.dropFirst("mailto:".count))
        let recipient =
            address.split(separator: "?", maxSplits: 1).first.map(String.init) ?? address
        return AgentPrompt.open(
            "a new mail to \(recipient.removingPercentEncoding ?? recipient)",
            detail: "\(url.absoluteString)\n\nIt opens in your mail app. Nothing is sent until you "
                + "send it.")
    }

    static func opened(app name: String) -> String { "Opened \(name)." }

    static func opened(path: String, homeDirectory: String) -> String {
        "Opened \(FileToolCatalog.shown(path, homeDirectory: homeDirectory))."
    }

    static func opened(url: URL) -> String {
        url.scheme?.lowercased() == "mailto"
            ? "Opened a new mail in the mail app; it is not sent."
            : "Opened \(url.absoluteString) in the default browser."
    }

    static func notOpened(_ subject: String, reason: String?) -> String {
        "macOS could not open \(subject)" + (reason.map { ": \($0)" } ?? ".")
    }
}
