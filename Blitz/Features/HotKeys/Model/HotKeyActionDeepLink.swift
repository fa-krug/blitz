import Foundation

/// `blitz://run/<defaultsKey minus "hotkey.">`: a link and a binding spell an action one way.
extension HotKeyAction {
    static let deepLinkHost = "run"

    var deepLink: URL? {
        let token = String(defaultsKey.dropFirst(Self.defaultsKeyPrefix.count))
        // One path segment, whatever the token holds: a snippet's id is a file path.
        guard let segment = token.addingPercentEncoding(withAllowedCharacters: Self.segmentCharacters)
        else { return nil }
        return URL(string: "blitz://\(Self.deepLinkHost)/\(segment)")
    }

    init?(deepLink url: URL) {
        guard url.scheme?.lowercased() == "blitz", url.host?.lowercased() == Self.deepLinkHost,
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
            let token = String(path.drop { $0 == "/" }).removingPercentEncoding,
            let action = Self.action(token: token)
        else { return nil }
        self = action
    }

    private static let defaultsKeyPrefix = "hotkey."

    private static let segmentCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return allowed
    }()

    /// The inverse of `defaultsKey`; a command no chord may run, such as Quit, no link runs either.
    private static func action(token: String) -> HotKeyAction? {
        if token == "togglePalette" { return .togglePalette }
        if let command = CommandID(rawValue: token) { return command.hotKeyAction }
        guard let dot = token.firstIndex(of: ".") else { return nil }
        let value = String(token[token.index(after: dot)...])
        guard !value.isEmpty else { return nil }
        let uuid = UUID(uuidString: value)
        switch token[..<dot] {
        case "app": return .app(bundleID: value)
        case "pane": return .settingsPane(bundleID: value)
        case "customCommand": return uuid.map { .customCommand(id: $0) }
        case "systemAction": return SystemAction.ID(rawValue: value).map { .systemAction(id: $0) }
        case "windowCommand": return WindowCommand.ID(rawValue: value).map { .windowCommand(id: $0) }
        case "windowLayout": return uuid.map { .windowLayout(id: $0) }
        case "windowRoom": return uuid.map { .windowRoom(id: $0) }
        case "customWindowSize": return uuid.map { .customWindowSize(id: $0) }
        case "quicklink": return uuid.map { .quicklink(id: $0) }
        case "quickAction": return uuid.map { .quickAction(id: $0) }
        case "appleShortcut": return uuid.map { .appleShortcut(id: $0) }
        case "snippet": return .snippet(id: value)
        case "extensionCommand": return .extensionCommand(entryID: value)
        default: return nil
        }
    }
}
