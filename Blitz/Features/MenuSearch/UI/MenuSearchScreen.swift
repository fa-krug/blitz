import SwiftUI

struct MenuSearchScreen: PaletteScreen {
    let session: MenuSearchSession
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [MenuSearchItem] { session.filtered }

    var primaryActionTitle: String { "Activate Menu Item" }

    func hasActions(at selection: Int) -> Bool { actions(at: selection) != nil }

    private func item(at selection: Int) -> MenuSearchItem? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard case .searchable(let appName) = session.target, let item = item(at: selection)
        else { return nil }
        return MenuSearchActionsMenu.content(item: item, appName: appName, core: core)
    }

    func activate(at selection: Int) {
        guard let item = item(at: selection) else { return }
        core.menuSearchCoordinator.activate(item)
    }

    func secondary(at selection: Int) -> Bool { false }

    /// ⌃⌘C — mirrors the Copy Menu Path row.
    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard shortcut == .copyPath, case .searchable = session.target,
            let item = item(at: selection)
        else { return false }
        core.menuSearchCoordinator.copyPath(item)
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        switch session.target {
        case .searchable(let name):
            if session.state == .reading {
                EmptyResults(text: "Reading menu…")
            } else if rows.isEmpty {
                EmptyResults(text: "No menu items found in \(name)")
            } else {
                MenuSearchList(
                    items: rows, targetName: name, isSearching: session.isSearching,
                    iconURL: core.menuSearchCoordinator.frozenIconURL,
                    iconStamp: core.menuSearchCoordinator.frozenIconStamp,
                    selectedID: rows.indices.contains(selection) ? rows[selection].id : nil,
                    scroll: scroll,
                    onActivate: { core.menuSearchCoordinator.activate($0) },
                    onActions: { item in
                        if let index = rows.firstIndex(of: item) { vm.selection = index }
                        openActions()
                    })
            }
        case .excluded(let name):
            EmptyResults(text: "Menu search is turned off for \(name)")
        case .selfTarget:
            EmptyResults(text: "Blitz has no menu to search")
        case .menuLess(let name):
            EmptyResults(text: "\(name) has no menu bar to search")
        case .noApplication:
            EmptyResults(text: "No application to search")
        }
    }
}

/// The ⌘K menu for a menu item row.
@MainActor
enum MenuSearchActionsMenu {
    static func content(item: MenuSearchItem, appName: String, core: AppCore) -> PopoverMenuContent {
        let coordinator = core.menuSearchCoordinator
        let activateIcon =
            coordinator.frozenIconURL.map { PopoverMenuIcon.file(path: $0.path) }
            ?? .symbol("menubar.rectangle")
        return PopoverMenuContent(
            header: item.title,
            items: [
                PopoverMenuItem(title: "Activate Menu Item", icon: activateIcon, shortcut: "↵") {
                    coordinator.activate(item)
                },
                PopoverMenuItem(
                    title: "Copy Menu Path", systemImage: "doc.on.doc", startsSection: true,
                    shortcut: "⌃⌘C"
                ) {
                    coordinator.copyPath(item)
                },
                PopoverMenuItem(
                    title: "Turn Off Menu Search for \(appName)", systemImage: "nosign",
                    startsSection: true
                ) {
                    coordinator.excludeTargetApp()
                },
            ])
    }
}
