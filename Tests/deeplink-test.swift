// Copy Deeplink's two link forms, `blitz://run/` and the extension link, plus a link's arguments.

import Foundation

@main
@MainActor
struct DeepLinkTests {
    static var failures = 0
    static var passes = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func main() {
        roundTrips()
        refusals()
        spelling()
        extensionLinks()
        linkArguments()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// Fails to compile when `HotKeyAction` gains a case, so `samples` cannot quietly miss it.
    static func sampled(_ action: HotKeyAction) -> Bool {
        switch action {
        case .togglePalette, .command, .app, .settingsPane, .customCommand, .systemAction,
            .windowCommand, .windowLayout, .windowRoom, .customWindowSize, .quicklink, .quickAction,
            .appleShortcut, .snippet, .extensionCommand:
            return true
        }
    }

    static let samples: [HotKeyAction] = [
        .togglePalette,
        .command(.clipboardHistory),
        .app(bundleID: "com.apple.Safari"),
        .settingsPane(bundleID: "com.apple.Bluetooth-Settings.extension"),
        .customCommand(id: UUID()),
        .systemAction(id: .sleepDisplays),
        .windowCommand(id: .leftHalf),
        .windowLayout(id: UUID()),
        .windowRoom(id: UUID()),
        .customWindowSize(id: UUID()),
        .quicklink(id: UUID()),
        .quickAction(id: UUID()),
        .appleShortcut(id: UUID()),
        .snippet(id: "/Users/me/Snippets/Sign off & thanks.md"),
        .extensionCommand(entryID: "extension:raycast/github/search-repositories")
    ]

    // MARK: - Round trips

    static func roundTrips() {
        for action in samples where sampled(action) {
            guard let link = action.deepLink else {
                check("\(action) has a link", false)
                continue
            }
            check("\(action) is a blitz link", link.scheme == "blitz", link.absoluteString)
            check("\(action) is addressed to run", link.host == "run", link.absoluteString)
            check(
                "\(action) round-trips", HotKeyAction(deepLink: link) == action,
                "\(link.absoluteString) → \(String(describing: HotKeyAction(deepLink: link)))")
        }
        for command in CommandID.allCases {
            guard let action = command.hotKeyAction else { continue }
            check(
                "\(command.rawValue) round-trips",
                action.deepLink.flatMap(HotKeyAction.init(deepLink:)) == action)
        }
    }

    // MARK: - Refusals

    static func refusals() {
        // Quit and the query-driven commands have no chord, so a link must not reach them either.
        for command in CommandID.allCases where command.hotKeyAction == nil {
            let url = URL(string: "blitz://run/\(command.rawValue)")!
            check("\(command.rawValue) cannot be linked", HotKeyAction(deepLink: url) == nil)
        }
        let refused = [
            "raycast://run/togglePalette",
            "blitz://extensions/togglePalette",
            "blitz://run/",
            "blitz://run/app.",
            "blitz://run/banana",
            "blitz://run/quicklink.not-a-uuid",
            "blitz://run/systemAction.self-destruct",
            "blitz://run/windowCommand.upside-down"
        ]
        for raw in refused {
            check("\(raw) is refused", URL(string: raw).flatMap(HotKeyAction.init(deepLink:)) == nil)
        }
    }

    // MARK: - Spelling

    static func spelling() {
        let command = HotKeyAction.command(.clipboardHistory).deepLink?.absoluteString
        check(
            "a command reads as its raw value", command == "blitz://run/command:clipboard-history",
            "got \(String(describing: command))")
        let app = HotKeyAction.app(bundleID: "com.apple.Safari").deepLink?.absoluteString
        check("an app reads as its bundle id", app == "blitz://run/app.com.apple.Safari")

        // A snippet's id is a path: its slashes must stay inside the one segment.
        let snippet = HotKeyAction.snippet(id: "/a/b c.md").deepLink
        check(
            "a path stays one segment", snippet?.pathComponents.count == 2,
            "got \(String(describing: snippet?.pathComponents))")

        let mixedCase = URL(string: "BLITZ://RUN/togglePalette")!
        check("scheme and host are case-blind", HotKeyAction(deepLink: mixedCase) == .togglePalette)
        let doubled = URL(string: "blitz://run//togglePalette")!
        check("a doubled slash is tolerated", HotKeyAction(deepLink: doubled) == .togglePalette)
    }

    // MARK: - Extensions

    static func extensionLinks() {
        let scoped = ExtensionDeepLink.url(extensionName: "raycast/github", commandName: "search")
        check(
            "a scoped extension links owner, extension, command",
            scoped?.absoluteString == "blitz://extensions/raycast/github/search",
            "got \(String(describing: scoped))")
        let parsed = scoped.flatMap(ExtensionDeepLink.parse(url:))
        check("the owner survives", parsed?.ownerOrAuthor == "raycast")
        check("the extension survives", parsed?.extensionName == "github")
        check("the command survives", parsed?.commandName == "search")
        check("it resolves to the manifest", parsed?.matches(manifestName: "raycast/github") == true)

        let bare = ExtensionDeepLink.url(extensionName: "emoji", commandName: "pick emoji")
            .flatMap(ExtensionDeepLink.parse(url:))
        check("a bare extension has no owner", bare?.ownerOrAuthor == nil)
        check("a spaced command name survives", bare?.commandName == "pick emoji")

        // The extension form is the one place `run` must not claim, or it would swallow it.
        let link = URL(string: "blitz://extensions/raycast/github/search")!
        check("run leaves extension links alone", HotKeyAction(deepLink: link) == nil)
    }

    // MARK: - Arguments

    static func linkArguments() {
        let id = UUID()
        let json = #"{"query":"swift actors","page":2}"#
        var components = URLComponents(string: "blitz://run/quicklink.\(id.uuidString.lowercased())")!
        components.queryItems = [URLQueryItem(name: "arguments", value: json)]
        let link = components.url!
        check("arguments leave the action alone", HotKeyAction(deepLink: link) == .quicklink(id: id))
        let arguments = HotKeyAction.deepLinkArguments(in: link)
        check(
            "Raycast's JSON fills the values",
            arguments == ["query": "swift actors", "page": "2"],
            "got \(arguments)")

        let bare = HotKeyAction.command(.clipboardHistory).deepLink!
        check("a bare link carries none", HotKeyAction.deepLinkArguments(in: bare).isEmpty)
        let junk = URL(string: "blitz://run/togglePalette?arguments=not-json")!
        check("malformed JSON is no arguments", HotKeyAction.deepLinkArguments(in: junk).isEmpty)
        let shouting = URL(string: "blitz://run/togglePalette?ARGUMENTS=%7B%22a%22:%22b%22%7D")!
        check("the key is case-blind", HotKeyAction.deepLinkArguments(in: shouting) == ["a": "b"])

        let command = CustomCommand(
            name: "Deploy", command: "deploy",
            arguments: [
                CustomCommandArgument(name: "branch"), CustomCommandArgument(name: "env"),
                CustomCommandArgument(name: "branch", isOptional: true)
            ])
        check(
            "a value can name its field by position",
            command.fieldValues(fromLink: ["$2": "staging"]) == ["$2": "staging"])
        check(
            "or by its argument's name, filling every field that shares it",
            command.fieldValues(fromLink: ["branch": "main"]) == ["$1": "main", "$3": "main"])
        check(
            "a position wins over a name for its own field",
            command.fieldValues(fromLink: ["$1": "dev", "branch": "main"]) == ["$1": "dev", "$3": "main"])
        check(
            "a key the command does not declare is dropped",
            command.fieldValues(fromLink: ["$9": "x", "region": "eu"]).isEmpty)
        check(
            "complete values run straight through",
            command.positionalValues(from: command.fieldValues(fromLink: ["branch": "main", "env": "prod"]))
                == ["main", "prod", "main"])
    }
}
