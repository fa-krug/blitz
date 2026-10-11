// Standalone test for QuicklinkCoordinator's open funnel and the argument strip's focus target.
import AppKit
import SwiftUI

@main
@MainActor
struct QuicklinkCoordinatorTests {
    static var failures = 0
    static var passes = 0

    static func main() async throws {
        try await missingSelection()
        try await readableSelection()
        try await clipboardFallback()
        try await combinedArguments()
        try await plainLink()
        try await promptOnRestoredScreen()
        try editing()
        try revealing()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func missingSelection() async throws {
        for token in ["selection", "selectedText"] {
            let fixture = try Fixture(link: "https://de.wikipedia.org/w/index.php?search={\(token)}")
            defer { fixture.cleanUp() }
            fixture.coordinator.openQuicklink(id: fixture.link.id, forcingDefaultApp: true)
            try await Task.sleep(for: .milliseconds(1))
            expect(QuicklinkLauncher.opened.isEmpty, "an unreadable \(token) never opens an empty search")
            expect(fixture.window.isVisible, "an unreadable \(token) shows Search Quicklinks")
            expect(fixture.core.palette.selection == 1, "the prompt selects the requested quicklink")
            expect(
                fixture.core.palette.pendingArgumentEntryID == fixture.link.entryID,
                "the prompt names the row whose field takes the caret")
            expect(
                fixture.accessory()?.firstIncompleteField == "Selected Text",
                "the selection field is owed while the prompt names its row")

            fixture.core.palette.pendingArgumentEntryID = nil
            expect(
                fixture.accessory()?.firstIncompleteField == nil,
                "without a prompt the selection field never holds ↵")
            fixture.coordinator.openQuicklink(id: fixture.link.id)
            try await Task.sleep(for: .milliseconds(1))
            expect(QuicklinkLauncher.opened.isEmpty, "submitting the empty selection field keeps prompting")
            fixture.coordinator.openQuicklink(id: fixture.link.id, values: ["Selected Text": "Swift & macOS"])
            await waitForOpen()
            expect(
                QuicklinkLauncher.opened.first?.link
                    == "https://de.wikipedia.org/w/index.php?search=Swift%20%26%20macOS",
                "a typed selection is encoded once")
            expect(QuicklinkLauncher.opened.first?.app == nil, "the default-app override survives the prompt")
            expect(!fixture.window.isVisible, "a completed prompt closes the palette")
        }
    }

    static func readableSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.injector.selection = "selected text"
        expect(fixture.accessory()?.firstIncompleteField == nil, "a selection chip stays optional")
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.link == "https://example.com/?q=selected%20text",
            "a readable selection opens immediately")
        expect(fixture.palette.shows == 0, "a readable selection needs no prompt")
        expect(QuicklinkLauncher.opened.first?.app == "com.example.browser", "the saved handler is used")

        QuicklinkLauncher.opened = []
        fixture.window.isVisible = true
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        await waitForOpen()
        expect(fixture.injector.target == .previous, "palette activation reads the app behind it")
    }

    static func clipboardFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.quicklinkSelectionFallback = .clipboard
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.link == "https://example.com/?q=clipboard%20text",
            "clipboard fallback still opens without prompting")
        expect(fixture.palette.shows == 0, "clipboard fallback never asks for the selection")
        expect(fixture.accessory() == nil, "clipboard fallback has no selection chip")
    }

    static func combinedArguments() async throws {
        let fixture = try Fixture(link: "https://example.com/?q={selection}&site={argument name=\"Site\"}")
        defer { fixture.cleanUp() }
        fixture.coordinator.openQuicklink(id: fixture.link.id, values: ["Site": "swift.org"])
        try await Task.sleep(for: .milliseconds(1))
        expect(QuicklinkLauncher.opened.isEmpty, "filled arguments cannot bypass a missing selection")
        expect(
            fixture.accessory()?.firstIncompleteField == "Selected Text",
            "filled arguments leave the selection field focused")
        expect(
            fixture.core.palette.commandArguments[PaletteState.argumentKey(fixture.link.entryID, "Site")]
                == "swift.org",
            "the selection prompt keeps the values already entered")

        fixture.coordinator.openQuicklink(id: fixture.link.id, values: ["Selected Text": "Swift"])
        expect(
            fixture.accessory()?.firstIncompleteField == "Site",
            "a declared argument is focused ahead of the selection")
        fixture.coordinator.openQuicklink(
            id: fixture.link.id, values: ["Selected Text": "Swift", "Site": "swift.org"])
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.link == "https://example.com/?q=Swift&site=swift.org",
            "selection and declared arguments resolve together")
    }

    static func plainLink() async throws {
        let fixture = try Fixture(link: "https://example.com/")
        defer { fixture.cleanUp() }
        fixture.settings.quicklinksEnabled = false
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(
            QuicklinkLauncher.opened.isEmpty && fixture.palette.shows == 0,
            "a disabled feature opens nothing")
        fixture.settings.quicklinksEnabled = true
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        await waitForOpen()
        expect(QuicklinkLauncher.opened.first?.link == fixture.link.link, "a plain link opens as is")
    }

    static func promptOnRestoredScreen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.palette.restoresScreen = true
        fixture.core.palette.query = "wiki"
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(
            fixture.core.palette.selection == 0,
            "a restored screen's query decides which row the prompt selects")
        fixture.core.palette.query = ""
        fixture.core.palette.quicklinkTagFilter = "missing"
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(fixture.core.palette.selection == 0, "a row the filter hides falls back to the top")
    }

    static func editing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.window.isVisible = true
        fixture.coordinator.editQuicklink(fixture.link)
        expect(!fixture.window.isVisible, "editing leaves the palette for Settings")
        expect(
            fixture.core.pendingQuicklinkEdit?.quicklink?.id == fixture.link.id,
            "the editor opens on the chosen quicklink")
    }

    static func revealing() throws {
        let folder = try Fixture(link: "/Applications")
        defer { folder.cleanUp() }
        AppLauncher.revealed = []
        folder.window.isVisible = true
        expect(folder.coordinator.showQuicklinkInFinder(folder.link), "a folder link is revealed")
        expect(
            AppLauncher.revealed == [URL(fileURLWithPath: "/Applications")],
            "Finder is shown the folder itself")
        expect(!folder.window.isVisible, "revealing leaves the palette")

        for link in ["https://example.com/", "~/Notes/{date}.md"] {
            let fixture = try Fixture(link: link)
            defer { fixture.cleanUp() }
            fixture.window.isVisible = true
            expect(!fixture.coordinator.showQuicklinkInFinder(fixture.link), "\(link) has nothing to reveal")
            expect(fixture.window.isVisible, "\(link) leaves the palette open")
        }
        expect(AppLauncher.revealed.count == 1, "only the folder link reached Finder")
    }

    static func waitForOpen() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while QuicklinkLauncher.opened.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        expect(QuicklinkLauncher.opened.count == 1, "one destination opens")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    @MainActor
    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: QuicklinkStore
        let link: Quicklink
        let core = AppCore()
        var settings: AppSettings { core.settings }
        let injector = TextInjector()
        let window = PaletteWindowController()
        let palette: PaletteCoordinator
        let coordinator: QuicklinkCoordinator

        init(link: String = "https://example.com/?q={selection}") throws {
            QuicklinkLauncher.opened = []
            store = QuicklinkStore(directory: directory)
            try store.add(Quicklink(name: "A different quicklink", link: "https://example.com/"))
            self.link = try store.add(
                Quicklink(name: "Wikipedia", link: link, openWithBundleID: "com.example.browser"))
            palette = PaletteCoordinator(window: window, state: core.palette)
            coordinator = QuicklinkCoordinator(
                store: store, settings: core.settings, appIndex: AppIndex(), injector: injector,
                hotKeys: HotKeyManager(), favorites: FavoritesStore(), visibility: VisibilityStore(),
                ranking: LauncherRankingStore(), aliases: AliasStore(), windowController: window,
                paletteCoordinator: palette, settingsCoordinator: SettingsCoordinator(),
                clipboardHistory: { ["clipboard text"] }, core: core)
            core.quicklinkCoordinator = coordinator
        }

        func accessory() -> PaletteHeaderAccessory? {
            QuicklinkArgumentsAccessory.make(
                quicklink: store.quicklink(id: link.id), core: core, vm: core.palette,
                focus: FocusState<String?>().projectedValue, placement: .besideSearchField,
                onOpenOptions: { _ in }, onSubmit: {})
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}

// Every collaborator below is inert, so the shipped coordinator never opens or reads anything real.

@MainActor
final class AppSettings {
    var quicklinksEnabled = true
    var quicklinksShowInLauncher = true
    var quicklinkSelectionFallback = QuicklinkSelectionFallback.ask
    var quicklinkOpensNewWindow = false
    var quicklinkPrefersExistingTabs = false
    var quicklinkConfirmsBeforeDelete = false
    var interfaceSize = InterfaceSize()
}

struct InterfaceSize { var metrics: InterfaceMetrics { InterfaceMetrics() } }
struct InterfaceMetrics {}
enum CommandID { case createQuicklink, searchQuicklinks, importQuicklinks, exportQuicklinks }

@MainActor
final class AppIndex {
    func setQuicklinks(_ links: [Quicklink], faviconPaths: [UUID: String]) {}
    func setCommandsVisible(_ commands: Set<CommandID>, _ visible: Bool) {}
    func setCommandsListed(_ commands: Set<CommandID>, _ listed: Bool) {}
}

struct EntryIcon {}
struct AppEntry {
    init(_ quicklink: Quicklink, faviconPath: String?) {}
    var iconSource: EntryIcon { EntryIcon() }
}

enum InjectionTarget: Equatable {
    case frontmost, previous
    static func current() -> Self? { .frontmost }
    var externalApp: NSRunningApplication? { nil }
}

@MainActor
final class TextInjector {
    var selection = ""
    var target: InjectionTarget?
    func captureExpansionContext(
        target: InjectionTarget?, clipboardHistory: [String], browserTab: BrowserTab?,
        calculate: (@Sendable (String) -> String?)?
    ) -> SnippetTemplateEngine.ExpansionContext {
        self.target = target
        return .init(
            clipboardHistory: clipboardHistory, selection: selection, now: .distantPast,
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!, browserTab: browserTab, calculate: calculate)
    }
}

@MainActor
enum BrowserTabs {
    struct Failure: Error {}
    static func browser(preferring candidates: [NSRunningApplication?]) -> NSRunningApplication? { nil }
    static func frontTab(of app: NSRunningApplication) async throws(Failure) -> BrowserTab {
        throw Failure()
    }
    static func isSupported(bundleID: String?) -> Bool { false }
}

enum HotKeyAction: Equatable { case quicklink(id: UUID) }
@MainActor
final class HotKeyManager {
    var recordingAction: HotKeyAction?
    func setBinding(_ binding: String?, for action: HotKeyAction) {}
}
final class FavoritesStore { func remove(keys: Set<String>) {} }
final class VisibilityStore { func removeItemKeys(_ keys: Set<String>) {} }
final class LauncherRankingStore { func reset(itemKey: String) {} }
final class AliasStore { func removeKeys(_ keys: Set<String>) {} }

@MainActor
final class PaletteWindowController {
    var isVisible = false
    var previousTarget: InjectionTarget? = .previous
    var previousApp: NSRunningApplication? { nil }
}

enum PaletteMode { case quicklinks }
@MainActor
final class PaletteState {
    var selection = 0
    var query = ""
    var quicklinkTagFilter: String?
    var commandArguments: [String: String] = [:]
    var pendingArgumentEntryID: String?
    static func argumentKey(_ entryID: String, _ name: String) -> String { entryID + "\u{1}" + name }
}

@MainActor
final class PaletteCoordinator {
    let window: PaletteWindowController
    let state: PaletteState
    var shows = 0
    /// A re-summon inside the pop-to-root window keeps the screen as it was left.
    var restoresScreen = false
    init(window: PaletteWindowController, state: PaletteState) {
        self.window = window
        self.state = state
    }
    var isVisible: Bool { window.isVisible }
    func showPalette(mode: PaletteMode) {
        shows += 1
        window.isVisible = true
        guard !restoresScreen else { return }
        state.selection = 0
        state.query = ""
        state.quicklinkTagFilter = nil
        state.commandArguments = [:]
        state.pendingArgumentEntryID = nil
    }
    func hidePalette(restoreFocus: Bool) { window.isVisible = false }
}

@MainActor
enum AppLauncher {
    static var revealed: [URL] = []
    static func showInFinder(_ url: URL) { revealed.append(url) }
}

enum SettingsTab { case quicklinks }
final class SettingsCoordinator { func showSettings(tab: SettingsTab) {} }
struct QuicklinkEditRequest {
    var quicklink: Quicklink?
    var browserTab: BrowserTab?
    var name = ""
}
enum DialogTone { case danger, neutral, success }

@MainActor
final class CalculatorCoordinator {
    func placeholderEvaluator() -> @Sendable (String) -> String? { { _ in nil } }
}

@MainActor
final class AppCore {
    let palette = PaletteState()
    let settings = AppSettings()
    let calculatorCoordinator = CalculatorCoordinator()
    lazy var quicklinkCoordinator: QuicklinkCoordinator = {
        fatalError("The fixture wires the coordinator")
    }()
    var pendingQuicklinkEdit: QuicklinkEditRequest?
    var messages: [String] = []
    func showNotice(
        title: String, message: String, symbol: String, artwork: String? = nil, tone: DialogTone
    ) async {}
    func reportFailure(
        title: String, message: String, symbol: String, artwork: String? = nil, recovery: String?
    ) async -> Bool { false }
    func confirm(
        title: String, message: String, symbol: String, artwork: String? = nil, confirmTitle: String
    ) async -> Bool { false }
    func reportBrowserTabFailure(_ failure: BrowserTabs.Failure, title: String) async {}
    func showMessage(_ message: String, tone: DialogTone = .success) { messages.append(message) }
}

enum BackupActions {
    static func chooseSaveLocation(named: String) -> URL? { nil }
    static func chooseJSONFile() -> URL? { nil }
}

@MainActor
enum QuicklinkLauncher {
    struct Opened { let link: String; let app: String? }
    static var opened: [Opened] = []
    enum Failure: LocalizedError {
        case refused
        var missingApplicationBundleID: String? { nil }
    }
    enum Outcome {
        case opened
        case openedWithoutTabLookup(BrowserTabs.Failure)
    }
    static func open(
        _ link: String, openWithBundleID: String?, inNewWindow: Bool, prefersExistingTab: Bool
    ) async throws(Failure) -> Outcome {
        opened.append(Opened(link: link, app: openWithBundleID))
        return .opened
    }
}

struct InlineArgument {
    let id: String
    let title: String
    var options: [String] = []
    var isOptional = false
}
struct InlineArgumentFields: View {
    let arguments: [InlineArgument]
    let icon: EntryIcon?
    let value: (String) -> Binding<String>
    let focused: FocusState<String?>.Binding
    let openOptions: (String) -> Void
    let onSubmit: () -> Void
    var body: some View { EmptyView() }
    static func totalWidth(
        for arguments: [InlineArgument], hasIcon: Bool, metrics: InterfaceMetrics
    ) -> CGFloat { 0 }
}

struct PaletteHeaderAccessory {
    enum Placement { case afterQuery, besideSearchField }
    let width: CGFloat
    let fieldNames: [String]
    let firstIncompleteField: String?
    let optionsMenu: (String) -> PopoverMenuContent?
    let placement: Placement
    let view: AnyView
}

struct PopoverMenuContent {
    let header: String
    let items: [PopoverMenuItem]
}
enum PopoverMenuIcon { case symbol(String), blank }
struct PopoverMenuItem {
    let title: String
    let icon: PopoverMenuIcon
    let action: () -> Void
    init(title: String, icon: PopoverMenuIcon, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }
}
