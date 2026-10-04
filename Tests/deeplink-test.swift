// Copy Deeplink's two link forms: `blitz://run/` over every hotkey action, and the extension link.

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
}
