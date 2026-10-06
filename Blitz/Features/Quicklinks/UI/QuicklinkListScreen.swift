import AppKit
import SwiftUI

/// Search Quicklinks: the library filtered by the search field, pinned entries first.
struct QuicklinkListScreen: PaletteScreen {
    let store: QuicklinkStore
    let core: AppCore
    let vm: PaletteState

    private var metrics: InterfaceMetrics { core.settings.interfaceSize.metrics }
    let openActions: () -> Void
    /// Opens the palette's own menu for an `options=` field, keyed by argument name.
    let openArgumentOptions: (String) -> Void
    /// Filtered once per screen: every selection lookup reads it, and a library can be large.
    let rows: [Quicklink]

    init(
        store: QuicklinkStore, core: AppCore, vm: PaletteState,
        openActions: @escaping () -> Void, openArgumentOptions: @escaping (String) -> Void
    ) {
        self.store = store
        self.core = core
        self.vm = vm
        self.openActions = openActions
        self.openArgumentOptions = openArgumentOptions
        let query = vm.query.trimmingCharacters(in: .whitespaces)
        let tag = vm.quicklinkTagFilter
        rows = store.enabled.filter { quicklink in
            (tag.map(quicklink.hasTag) ?? true) && (query.isEmpty || quicklink.matches(query))
        }
    }

    var primaryActionTitle: String { "Open Quicklink" }

    private func quicklink(at selection: Int) -> Quicklink? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let quicklink = quicklink(at: selection) else { return nil }
        return QuicklinkActionsMenu.content(
            quicklink: quicklink, core: core,
            values: QuicklinkArgumentsAccessory.values(for: quicklink, core: core, vm: vm))
    }

    func activate(at selection: Int) {
        guard let quicklink = quicklink(at: selection) else { return }
        core.quicklinkCoordinator.openQuicklink(
            id: quicklink.id,
            values: QuicklinkArgumentsAccessory.values(for: quicklink, core: core, vm: vm))
    }

    /// The header's argument fields, which is where a templated link collects its values.
    func headerAccessory(
        at selection: Int, focus: FocusState<String?>.Binding
    ) -> PaletteHeaderAccessory? {
        QuicklinkArgumentsAccessory.make(
            quicklink: quicklink(at: selection), core: core, vm: vm, focus: focus,
            placement: .besideSearchField, onOpenOptions: openArgumentOptions,
            onSubmit: { activate(at: selection) })
    }

    /// ⌘↵ bypasses a saved "open with" app; without one there is nothing to bypass.
    func secondary(at selection: Int) -> Bool {
        guard let quicklink = quicklink(at: selection), quicklink.openWithBundleID != nil else {
            return false
        }
        core.quicklinkCoordinator.openQuicklink(
            id: quicklink.id, forcingDefaultApp: true,
            values: QuicklinkArgumentsAccessory.values(for: quicklink, core: core, vm: vm))
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        switch shortcut {
        case .commandDelete: return delete(at: selection)
        case .pin: return pin(at: selection)
        default: return false
        }
    }

    /// ⌘. — mirrors the Actions menu row; pinning lifts the row into the Pinned section.
    private func pin(at selection: Int) -> Bool {
        guard let quicklink = quicklink(at: selection) else { return false }
        core.quicklinkCoordinator.toggleQuicklinkPinned(id: quicklink.id)
        return true
    }

    /// ⌘⌫ — deletion honours the "confirm before deleting" setting inside `AppCore`.
    private func delete(at selection: Int) -> Bool {
        guard let quicklink = quicklink(at: selection) else { return false }
        Task { await core.quicklinkCoordinator.deleteQuicklink(id: quicklink.id) }
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        if rows.isEmpty {
            EmptyResults(text: store.enabled.isEmpty ? "No quicklinks yet" : "No matching quicklinks")
        } else {
            let selected = quicklink(at: selection)
            HStack(spacing: 0) {
                QuicklinkList(
                    results: rows, selectedID: selected?.id, scroll: scroll,
                    onSelect: { link in
                        if let index = rows.firstIndex(where: { $0.id == link.id }) {
                            vm.selection = index
                        }
                    },
                    onActivate: { activate(at: vm.selection) },
                    onActions: { link in
                        if let index = rows.firstIndex(where: { $0.id == link.id }) {
                            vm.selection = index
                        }
                        openActions()
                    }
                )
                .frame(width: metrics.size.clipboardListWidth)
                Rectangle().fill(Theme.Colors.separator).frame(width: Theme.Size.hairline)
                QuicklinkPreview(quicklink: selected)
            }
        }
    }
}

/// The ⌘K menu for a quicklink row.
@MainActor
enum QuicklinkActionsMenu {
    /// `values` are the header's argument fields, so a menu row opens with what ↵ would have used.
    static func content(
        quicklink: Quicklink, core: AppCore, values: [String: String]
    ) -> PopoverMenuContent {
        var openIcon = PopoverMenuIcon.symbol(quicklink.symbol)
        if let favicon = quicklink.favicon { openIcon = .thumbnail(id: quicklink.id, data: favicon) }
        var items: [PopoverMenuItem] = [
            PopoverMenuItem(title: "Open Quicklink", icon: openIcon, shortcut: "↵") {
                core.quicklinkCoordinator.openQuicklink(id: quicklink.id, values: values)
            }
        ]
        // A flat menu has no picker, so the palette offers only the system-handler bypass.
        if quicklink.openWithBundleID != nil {
            items.append(
                PopoverMenuItem(
                    title: "Open With Default App", systemImage: "arrow.up.forward.app",
                    shortcut: "⌘↵"
                ) {
                    core.quicklinkCoordinator.openQuicklink(
                        id: quicklink.id, forcingDefaultApp: true, values: values)
                })
        }
        items += openWithItems(quicklink: quicklink, core: core, values: values)
        items.append(
            PopoverMenuItem(title: "Edit Quicklink", systemImage: "pencil", startsSection: true) {
                core.paletteCoordinator.hidePalette(restoreFocus: false)
                core.quicklinkCoordinator.editQuicklink(quicklink)
            })
        items.append(
            PopoverMenuItem(title: "Duplicate Quicklink", systemImage: "plus.square.on.square") {
                core.quicklinkCoordinator.duplicateQuicklink(id: quicklink.id)
            })
        items.append(
            quicklink.isPinned
                ? PopoverMenuItem(
                    title: "Unpin Quicklink", systemImage: "pin.slash", startsSection: true,
                    shortcut: "⌘."
                ) {
                    core.quicklinkCoordinator.toggleQuicklinkPinned(id: quicklink.id)
                }
                : PopoverMenuItem(
                    title: "Pin Quicklink", systemImage: "pin", startsSection: true, shortcut: "⌘."
                ) {
                    core.quicklinkCoordinator.toggleQuicklinkPinned(id: quicklink.id)
                })
        items.append(
            PopoverMenuItem(
                title: quicklink.showsInRootSearch
                    ? "Hide from Root Search" : "Show in Root Search",
                systemImage: quicklink.showsInRootSearch ? "eye.slash" : "eye"
            ) {
                core.quicklinkCoordinator.setQuicklinkShowsInRootSearch(
                    !quicklink.showsInRootSearch, id: quicklink.id)
            })
        // Revealing needs a real path, which a template lacks until it expands.
        if case .path(let path)? = QuicklinkDestination.detect(quicklink.link),
            !QuicklinkDestination.containsPlaceholder(quicklink.link)
        {
            items.append(
                PopoverMenuItem(
                    title: "Show in Finder", systemImage: "folder", startsSection: true, shortcut: "⌘F"
                ) {
                    core.paletteCoordinator.hidePalette(restoreFocus: false)
                    AppLauncher.showInFinder(URL(fileURLWithPath: path))
                })
        }
        items.append(
            PopoverMenuItem(
                title: "Delete Quicklink", systemImage: "trash", startsSection: true, shortcut: "⌘⌫",
                isDestructive: true
            ) {
                Task { await core.quicklinkCoordinator.deleteQuicklink(id: quicklink.id) }
            })
        return PopoverMenuContent(header: quicklink.name, items: items)
    }

    /// Past the default, this many of the other apps that can open the link; the editor has all.
    private static let alternativeAppLimit = 6

    /// The system default first, then other handlers; choosing one opens once without saving it.
    private static func openWithItems(
        quicklink: Quicklink, core: AppCore, values: [String: String]
    ) -> [PopoverMenuItem] {
        guard let probe = QuicklinkDestination.handlerProbe(quicklink.link) else { return [] }
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: probe)?.standardizedFileURL
        var apps = defaultApp.map { [$0] } ?? []
        for app in workspace.urlsForApplications(toOpen: probe).map(\.standardizedFileURL)
        where !apps.contains(app) && apps.count < alternativeAppLimit + 1 {
            apps.append(app)
        }
        return apps.enumerated().compactMap { index, app in
            guard let bundleID = Bundle(url: app)?.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: app.path)
            return PopoverMenuItem(
                title: app == defaultApp ? "\(name) (Default)" : name,
                icon: .file(path: app.path), sectionTitle: index == 0 ? "Open With" : nil,
                startsSection: index == 0
            ) {
                core.quicklinkCoordinator.openQuicklink(
                    id: quicklink.id, openingWith: bundleID, values: values)
            }
        }
    }
}
