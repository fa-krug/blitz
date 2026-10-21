// Standalone test for duplicate app installations: every copy indexed, each launched and quit alone.
import AppKit
import Observation
import Synchronization

private let receivedWorkspaceLaunch = Mutex(false)

@main
@MainActor
struct AppInstallationTest {
    private static var failures = 0

    static func main() {
        Task {
            do {
                try await runTests()
                exit(failures == 0 ? 0 : 1)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    private static func runTests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-installations-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await testIndex(root)
        if ProcessInfo.processInfo.environment["BLITZ_TEST_APP_LAUNCH"] == "1"
            || CommandLine.arguments.contains("--launch")
        {
            try await testLaunch(root)
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }

    private static func check(_ name: String, _ condition: Bool) {
        if !condition {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func makeApp(_ url: URL, id: String, version: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleShortVersionString": version,
            "CFBundleVersion": "1", "CFBundleName": url.deletingPathExtension().lastPathComponent,
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture", "LSUIElement": true,
            "NSPrincipalClass": "NSApplication"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// The stores read `UserDefaults.standard`; the argument domain shadows whatever is persisted.
    private static let preferenceKeys = [
        "favoriteApps", "launcherAliases", "hiddenLauncherItems", "hiddenLauncherKinds"
    ]

    private static func testIndex(_ root: URL) async throws {
        let id = "com.example.android-studio"
        let stable = root.appendingPathComponent("Stable/Android Studio.app", isDirectory: true)
        let old = root.appendingPathComponent("Old/Android Studio.app", isDirectory: true)
        let backup = root.appendingPathComponent("Backup/Android Studio.app", isDirectory: true)
        let preview = root.appendingPathComponent("Beta/Android Studio Preview.app", isDirectory: true)
        let utility = root.appendingPathComponent("Utility.app", isDirectory: true)
        for (url, version) in [(stable, "2026.1"), (old, "2025.2"), (backup, "2026.1"), (preview, "2026.2")] {
            try makeApp(url, id: id, version: version)
        }
        try makeApp(utility, id: "com.example.utility", version: "1.0")
        let alias = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: stable)

        let defaults = UserDefaults.standard
        let clean: [String: Any] = [
            "favoriteApps": [id], "launcherAliases": [String: String](),
            "hiddenLauncherItems": [String](), "hiddenLauncherKinds": [String]()
        ]
        defaults.setVolatileDomain(clean, forName: UserDefaults.argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            for key in preferenceKeys { defaults.removeObject(forKey: key) }
        }
        let aliases = AliasStore()
        let visibility = VisibilityStore()
        let ranking = LauncherRankingStore(fileURL: root.appendingPathComponent("ranking.json"))
        let settings = AppSettings()
        settings.searchScopes = [stable.path, root.path]
        let index = AppIndex(ranking: ranking, aliases: aliases)
        index.start(settings: settings)
        await index.refresh()
        let hotKeys = HotKeyManager()
        let favorites = FavoritesStore()
        func results(_ query: String) -> AppIndex.Results {
            index.orderedResults(query: query, visibility: visibility, favorites: favorites, hotKeys: hotKeys)
        }

        let copies = results("Android Studio").entries.filter { $0.bundleID == id }
        check("all four installations survive indexing", copies.count == 4)
        check(
            "overlapping scopes and symlinks do not duplicate an installation",
            Set(copies.map(\.id)).count == 4)
        check(
            "app-wide settings retain one representative",
            index.apps.filter { $0.bundleID == id }.count == 1)
        check(
            "scope priority retains the existing representative",
            index.apps.first { $0.bundleID == id }?.url == stable)
        check("each row retains its own launch URL", Set(copies.map(\.url)) == [stable, old, backup, preview])
        check(
            "same-version copies show their distinct folders",
            copies.first { $0.url == stable }?.subtitle?.contains("Stable") == true)
        check(
            "the second same-version copy shows its folder",
            copies.first { $0.url == backup }?.subtitle?.contains("Backup") == true)
        check("a distinct version needs no path label", copies.first { $0.url == old }?.subtitle == "2025.2")
        check(
            "preview keeps its own name",
            copies.first { $0.url == preview }?.name == "Android Studio Preview")
        check(
            "single installations keep their existing appearance",
            index.apps.first { $0.url == utility }?.subtitle == nil)
        check(
            "version metadata is searchable",
            results("Android Studio 2025.2").entries.contains { $0.url == old })
        check(
            "searching Preview selects Preview",
            results("Android Studio Preview").entries.first?.url == preview)
        check(
            "settings search does not expose duplicate controls",
            index.matches("Android Studio").filter { $0.bundleID == id }.count == 1)
        check(
            "a version name still finds its app-wide settings",
            index.matches("Android Studio Preview").first?.url == stable)
        check(
            "a copy configures its app's page",
            copies.allSatisfy { $0.settingsPage == index.apps.first { $0.bundleID == id }?.id })
        check(
            "only the primary installation is primary",
            copies.filter(\.isPrimaryInstallation).map(\.url) == [stable])

        let empty = results("")
        check(
            "an existing favorite retains the representative",
            empty.entries.first?.url == stable && empty.favoriteCount == 1)
        check(
            "favoriting the app does not hide its other copies",
            empty.entries.filter { $0.bundleID == id }.count == 4)

        defaults.setVolatileDomain(["favoriteApps": [String]()], forName: UserDefaults.argumentDomain)
        ranking.visit(itemKey: id, query: nil)
        let unpinned = index.orderedResults(
            query: "", visibility: visibility, favorites: FavoritesStore(), hotKeys: hotKeys)
        check(
            "Suggestions contain one representative per app",
            unpinned.entries.prefix(unpinned.suggestionCount).filter { $0.bundleID == id }.map(\.url)
                == [stable])
        check(
            "the copies Suggestions skip stay listed",
            unpinned.entries.filter { $0.bundleID == id }.count == 4)

        aliases.setAlias("ide", for: id)
        check("aliases remain app-wide", results("ide").entries.filter { $0.bundleID == id }.count == 4)
        guard let primary = index.apps.first(where: { $0.bundleID == id }) else {
            return check("the app has a primary installation", false)
        }
        visibility.setItemVisible(false, for: primary)
        check(
            "visibility remains app-wide",
            results("Android Studio").entries.allSatisfy { $0.bundleID != id })
        visibility.setItemVisible(true, for: primary)

        for url in [old, backup, preview] { try FileManager.default.removeItem(at: url) }
        await index.refresh()
        check(
            "removing duplicate installations invalidates search results",
            results("Android Studio").entries.filter { $0.bundleID == id }.count == 1)
        check(
            "the last installation no longer needs a version label",
            index.apps.first { $0.bundleID == id }?.subtitle == nil)
        check(
            "the last installation regains single-app actions",
            index.apps.first { $0.bundleID == id }?.primaryInstallationID == nil)
        await ranking.flush()
    }

    private static func testLaunch(_ root: URL) async throws {
        let id = "com.example.installation-fixture.\(UUID().uuidString.lowercased())"
        let first = root.appendingPathComponent("First.app", isDirectory: true)
        let second = root.appendingPathComponent("Second.app", isDirectory: true)
        let source = root.appendingPathComponent("Fixture.swift")
        let executable = root.appendingPathComponent("Fixture")
        try """
        import AppKit

        final class Delegate: NSObject, NSApplicationDelegate {
            func applicationDidFinishLaunching(_ notification: Notification) {
                let bundle = Bundle.main.bundleURL
                let marker = bundle.deletingLastPathComponent()
                    .appendingPathComponent(bundle.lastPathComponent + ".ready")
                try! Data().write(to: marker)
            }

            func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
                let bundle = Bundle.main.bundleURL
                let marker = bundle.deletingLastPathComponent()
                    .appendingPathComponent(bundle.lastPathComponent + ".reopened")
                try! Data().write(to: marker)
                return true
            }
        }

        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        """.write(to: source, atomically: true, encoding: .utf8)
        guard
            try await runProgram(
                "/usr/bin/xcrun", ["swiftc", "-swift-version", "6", source.path, "-o", executable.path]) == 0
        else { throw CocoaError(.fileReadCorruptFile) }
        for url in [first, second] {
            try makeApp(url, id: id, version: "1.0")
            let macOS = url.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: executable, to: macOS.appendingPathComponent("Fixture"))
            guard try await runProgram("/usr/bin/codesign", ["--force", "--sign", "-", url.path]) == 0
            else { throw CocoaError(.fileReadCorruptFile) }
        }
        defer {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                app.forceTerminate()
            }
        }
        func running(_ url: URL) -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url
            }
        }
        let firstEntry = AppEntry(id: first.path, name: "First", url: first, bundleID: id, kind: .application)
        let secondEntry = AppEntry(
            id: second.path, name: "Second", url: second, bundleID: id, kind: .application)
        let center = NSWorkspace.shared.notificationCenter
        receivedWorkspaceLaunch.withLock { $0 = false }
        let observer = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier == id
            {
                receivedWorkspaceLaunch.withLock { $0 = true }
            }
        }
        defer { center.removeObserver(observer) }

        try await AppLauncher.launch(first, allowsRunningApplicationSubstitution: false)
        check("the first selected installation launches", await waitUntil { running(first) != nil })
        check(
            "the first fixture completes AppKit launch",
            await waitUntil {
                FileManager.default.fileExists(atPath: root.appendingPathComponent("First.app.ready").path)
            })
        let receivesEvents = await waitUntil(timeout: .seconds(2)) {
            receivedWorkspaceLaunch.withLock { $0 }
        }
        if !receivesEvents {
            print("SKIP: workspace lifecycle notifications are unavailable in this session")
        }
        let monitor = RunningAppsMonitor()
        check(
            "the running dot belongs to the selected path",
            monitor.isRunning(firstEntry) && !monitor.isRunning(secondEntry))
        try await AppLauncher.launch(second, allowsRunningApplicationSubstitution: false)
        check(
            "another running version cannot replace the selection",
            await waitUntil { running(second) != nil })
        check(
            "the second fixture completes AppKit launch",
            await waitUntil {
                FileManager.default.fileExists(atPath: root.appendingPathComponent("Second.app.ready").path)
            })
        if receivesEvents {
            check(
                "the monitor updates even when the bundle-ID set stays unchanged",
                await waitUntil { monitor.isRunning(secondEntry) })
        }
        let bothRunning = RunningAppsMonitor()
        check(
            "running paths distinguish copies with one bundle ID",
            bothRunning.isRunning(firstEntry) && bothRunning.isRunning(secondEntry))
        let secondPID = running(second)?.processIdentifier
        try await AppLauncher.launch(second, allowsRunningApplicationSubstitution: false)
        try await Task.sleep(for: .milliseconds(300))
        check("reopening reuses the selected installation", running(second)?.processIdentifier == secondPID)
        check("Quit finds the selected version", AppLauncher.quit(bundleID: id, url: second))
        check(
            "Quit leaves its sibling running",
            await waitUntil { running(second) == nil && running(first) != nil })
        if receivesEvents {
            check(
                "the running dot clears for only the version that quit",
                await waitUntil { !monitor.isRunning(secondEntry) && monitor.isRunning(firstEntry) })
        }
        try await AppLauncher.launch(second, allowsRunningApplicationSubstitution: false)
        check("the second installation can reopen", await waitUntil { running(second) != nil })
        let siblingPID = running(second)?.processIdentifier
        let firstPID = running(first)?.processIdentifier
        await AppLauncher.restart(bundleID: id, url: first)
        check(
            "Restart reopens the selected version",
            await waitUntil { running(first).map { $0.processIdentifier != firstPID } ?? false })
        check("Restart leaves the sibling process alone", running(second)?.processIdentifier == siblingPID)
        let canceled = Task { await AppLauncher.restart(bundleID: id, url: second) }
        canceled.cancel()
        await canceled.value
        check("a canceled restart leaves the app running", running(second)?.processIdentifier == siblingPID)
        check(
            "quitting one copy before uninstalling leaves its sibling alone",
            await AppLauncher.quitAwaitingExit(bundleID: id, url: second)
                && running(second) == nil && running(first) != nil)
        check(
            "nothing left running at that path already counts as quit",
            await AppLauncher.quitAwaitingExit(bundleID: id, url: second))
        try await AppLauncher.launch(second, allowsRunningApplicationSubstitution: false)
        check("the second installation reopens again", await waitUntil { running(second) != nil })
        _ = AppLauncher.quit(bundleID: id, url: second, force: true)
        check(
            "Force Quit targets the selected path",
            await waitUntil { running(second) == nil && running(first) != nil })
        let survivingPID = running(first)?.processIdentifier
        let reopened = root.appendingPathComponent("First.app.reopened")
        try? FileManager.default.removeItem(at: reopened)
        try await AppLauncher.launch(second)
        check(
            "ordinary app opens reach a running instance",
            await waitUntil {
                FileManager.default.fileExists(atPath: reopened.path) || running(second) != nil
            })
        check(
            "ordinary app opens allow running-version substitution",
            FileManager.default.fileExists(atPath: reopened.path)
                && running(first)?.processIdentifier == survivingPID && running(second) == nil)
        _ = AppLauncher.quit(bundleID: id, url: second, force: true)
        _ = AppLauncher.quit(bundleID: id, url: first, force: true)
        check(
            "fixture processes are cleaned up",
            await waitUntil { NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty })
    }

    private static func runProgram(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func waitUntil(timeout: Duration = .seconds(8), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

// Empty feature catalogs keep this harness focused on the shipped launcher.
enum SettingsTab: Hashable, Sendable { case ai }
enum ExtensionRefreshState: Hashable, Sendable { case idle }
enum EntryIcon: Hashable, Sendable {
    case file(stamp: Int), symbol(String), artwork(path: String, extent: Int)
}
enum IconCache {
    static func observeStyle() {}
    static func icon(for source: EntryIcon, fileURL: URL) -> NSImage { NSImage() }
}
enum QuicklinkFavicon { static let extent = 0 }
enum SettingsAnchor: Hashable, Sendable {
    case navigationMenuSearch, fileSearchScreenshots, applicationsApplications
    case systemSettingsSystemSettings, commandsCommands, quickActionsActions, commandsCustomCommands
    case snippetsLibrary, systemActionsSystemActions, windowManagementCustomSizes
    case windowManagementLayouts, windowManagementRooms, quicklinksQuicklinks, appleShortcutsShortcuts
    case group
    static func windowCommands(in group: Int) -> Self { .group }
    static func commands(ownedBy tab: SettingsTab) -> Self? { nil }
}
enum SettingsTarget: Hashable, Sendable { case row(SettingsAnchor, String) }
enum CommandID: String, Sendable {
    case fixture, searchMenuItems, searchScreenshots
    var sfSymbol: String { "" }
    var hotKeyAction: HotKeyAction? { nil }
    var suggestionPriority: Int? { nil }
    var boostedTerms: Set<String> { [] }
    var owner: SettingsTab? { nil }
}
enum CommandCatalog {
    static let all: [AppEntry] = []
    static func command(for entry: AppEntry) -> CommandID? { nil }
    static func isQueryDriven(_ entry: AppEntry) -> Bool { false }
}
enum HotKeyAction: Hashable, Sendable {
    case togglePalette, command(CommandID)
    case app(bundleID: String), settingsPane(bundleID: String), quickAction(id: UUID)
    case customCommand(id: UUID), systemAction(id: SystemAction.ID), windowCommand(id: WindowCommand.ID)
    case customWindowSize(id: UUID), windowLayout(id: UUID), windowRoom(id: UUID), quicklink(id: UUID)
    case appleShortcut(id: UUID), snippet(id: UUID), extensionCommand(entryID: String)
    var deepLink: URL? { nil }
}
struct ExtensionCommandRef {
    var extensionName = ""
    var commandName = ""
    init?(entryID: String) { nil }
}
enum ExtensionDeepLink {
    static func url(extensionName: String, commandName: String) -> URL? { nil }
}
struct OtherEntry<Tag: Sendable>: Sendable {
    var id = UUID()
    var entryID: String { id.uuidString }
    var name = ""
    var iconSymbol: String?
    var isEnabled = true
    var showsInRootSearch = true
    var link = ""
    static var sfSymbol: String { "" }
    static func id(fromEntryID id: String) -> UUID? { nil }
    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool { lhs.name < rhs.name }
}
enum LayoutTag: Sendable {}
enum RoomTag: Sendable {}
enum SizeTag: Sendable {}
enum QuickActionTag: Sendable {}
enum CommandTag: Sendable {}
enum QuicklinkTag: Sendable {}
enum ShortcutTag: Sendable {}
typealias WindowLayout = OtherEntry<LayoutTag>
typealias Room = OtherEntry<RoomTag>
typealias CustomWindowSize = OtherEntry<SizeTag>
typealias CustomQuickAction = OtherEntry<QuickActionTag>
typealias CustomCommand = OtherEntry<CommandTag>
typealias Quicklink = OtherEntry<QuicklinkTag>
typealias AppleShortcut = OtherEntry<ShortcutTag>
struct SystemAction: Sendable {
    enum ID: String, Sendable { case fixture }
    var id = ID.fixture
    var entryID = ""
    var name = ""
    var sfSymbol = ""
}
enum SystemActionCatalog {
    static let all: [SystemAction] = []
    static func action(forEntryID id: String) -> SystemAction? { nil }
}
struct WindowCommand: Sendable {
    enum ID: String, Sendable { case fixture }
    var id = ID.fixture
    var entryID = ""
    var name = ""
    var sfSymbol = ""
    var group = 0
}
enum WindowCommandCatalog {
    static let all: [WindowCommand] = []
    static func command(forEntryID id: String) -> WindowCommand? { nil }
}
enum QuicklinkDestination {
    static func detect(_ link: String) -> Self? { nil }
    var defaultSymbol: String { "" }
}
struct StoredSnippet {
    struct Snippet {
        var isEnabled = true
        var name = ""
        var keyword: String?
    }
    var snippet = Snippet()
    var entryID = ""
    var fileURL = URL(fileURLWithPath: "/")
    static let sfSymbol = ""
    static func id(fromEntryID id: String) -> UUID? { nil }
}
enum SettingsPaneScanner {
    struct Cache: Sendable {}
    static func scan(languages: [String], cache: Cache?) -> ([AppEntry], Cache?) { ([], nil) }
}
@MainActor
@Observable
final class AppSettings {
    var searchScopes: [String] = []
    var launcherShowsSuggestions = true
    var rootSearchSensitivity = SearchSensitivity.default
}
@MainActor
final class HotKeyManager {
    var revision = 0
    func binding(for action: HotKeyAction) -> Int? { nil }
}
