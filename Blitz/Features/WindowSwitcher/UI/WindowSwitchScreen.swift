import SwiftUI

struct WindowSwitchScreen: PaletteScreen {
    let session: WindowSwitchSession
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [WindowSwitchEntry] { session.filtered }

    var primaryActionTitle: String { "Switch to Window" }

    func hasActions(at selection: Int) -> Bool { actions(at: selection) != nil }

    private func entry(at selection: Int) -> WindowSwitchEntry? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        entry(at: selection).map { WindowSwitchActionsMenu.content(entry: $0, core: core) }
    }

    func activate(at selection: Int) {
        guard let entry = entry(at: selection) else { return }
        core.windowSwitchCoordinator.activate(entry)
    }

    func secondary(at selection: Int) -> Bool { false }

    /// ⌃⇧Q or ⌃⌥⇧Q — mirrors the Quit and Force Quit rows.
    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard shortcut == .quit || shortcut == .forceQuit, let entry = entry(at: selection)
        else { return false }
        core.launcherCoordinator.quit(bundleID: entry.bundleID, force: shortcut == .forceQuit)
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        if rows.isEmpty {
            EmptyResults(text: session.snapshot.isEmpty ? "No open windows" : "No windows found")
        } else {
            WindowSwitchList(
                entries: rows,
                selectedID: rows.indices.contains(selection) ? rows[selection].id : nil,
                scroll: scroll,
                onActivate: { core.windowSwitchCoordinator.activate($0) },
                onActions: { entry in
                    if let index = rows.firstIndex(of: entry) { vm.selection = index }
                    openActions()
                })
        }
    }
}

/// The ⌘K menu for a window row.
@MainActor
enum WindowSwitchActionsMenu {
    static func content(entry: WindowSwitchEntry, core: AppCore) -> PopoverMenuContent {
        let coordinator = core.windowSwitchCoordinator
        let switchIcon =
            entry.iconURL.map { PopoverMenuIcon.file(path: $0.path) } ?? .symbol("macwindow")
        var items = [
            PopoverMenuItem(title: "Switch to Window", icon: switchIcon, shortcut: "↵") {
                coordinator.activate(entry)
            },
            PopoverMenuItem(
                title: "Close Window", systemImage: "xmark.square", startsSection: true
            ) {
                coordinator.close(entry)
            },
        ]
        if !entry.isMinimized {
            items.append(
                PopoverMenuItem(title: "Minimize Window", systemImage: "minus.square") {
                    coordinator.minimize(entry)
                })
        }
        items += [
            PopoverMenuItem(
                title: "Quit \(entry.appName)", systemImage: "power", startsSection: true,
                shortcut: "⌃⇧Q"
            ) {
                core.launcherCoordinator.quit(bundleID: entry.bundleID)
            },
            PopoverMenuItem(
                title: "Force Quit \(entry.appName)", systemImage: "xmark.circle", shortcut: "⌃⌥⇧Q"
            ) {
                core.launcherCoordinator.quit(bundleID: entry.bundleID, force: true)
            },
        ]
        return PopoverMenuContent(header: entry.displayTitle, items: items)
    }
}
