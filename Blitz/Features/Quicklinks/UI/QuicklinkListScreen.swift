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
        rows = store.listed(matching: vm.query, tag: vm.quicklinkTagFilter)
    }

    var primaryActionTitle: String { "Open Quicklink" }

    /// A prompt for one row opens on that row, so the show's reset can't move it back to the top.
    var landingSelection: Int {
        guard let pending = vm.pendingArgumentEntryID else { return 0 }
        return rows.firstIndex { $0.entryID == pending } ?? 0
    }

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

    /// Each chord runs its menu row's coordinator call, so the two can't drift.
    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        let coordinator = core.quicklinkCoordinator
        // The empty library's hint names ⌘N, so it is the one chord that needs no row.
        if shortcut == .newItem {
            coordinator.editQuicklink(
                nil, name: vm.query.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        }
        guard let quicklink = quicklink(at: selection) else { return false }
        switch shortcut {
        case .edit: coordinator.editQuicklink(quicklink)
        case .duplicate: coordinator.duplicateQuicklink(id: quicklink.id)
        case .pin: coordinator.toggleQuicklinkPinned(id: quicklink.id)
        case .showInFinder: return coordinator.showQuicklinkInFinder(quicklink)
        // Deletion honours the "confirm before deleting" setting inside `AppCore`.
        case .commandDelete: Task { await coordinator.deleteQuicklink(id: quicklink.id) }
        default: return false
        }
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        if rows.isEmpty {
            if store.enabled.isEmpty {
                EmptyResults(
                    text: "No quicklinks yet", symbol: Quicklink.sfSymbol,
                    hint: "Press ⌘N to create one")
            } else {
                EmptyResults(text: "No matching quicklinks")
            }
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
            PopoverMenuItem(
                title: "Edit Quicklink", systemImage: "pencil", startsSection: true, shortcut: "⌘E"
            ) {
                core.quicklinkCoordinator.editQuicklink(quicklink)
            })
        items.append(
            PopoverMenuItem(
                title: "Duplicate Quicklink", systemImage: "plus.square.on.square", shortcut: "⌘D"
            ) {
                core.quicklinkCoordinator.duplicateQuicklink(id: quicklink.id)
            })
        items.append(
            PopoverMenuItem(title: "New Quicklink", systemImage: "plus.circle", shortcut: "⌘N") {
                core.quicklinkCoordinator.editQuicklink(nil)
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
        if QuicklinkCoordinator.revealablePath(of: quicklink) != nil {
            items.append(
                PopoverMenuItem(
                    title: "Show in Finder", systemImage: "folder", startsSection: true, shortcut: "⌘F"
                ) {
                    core.quicklinkCoordinator.showQuicklinkInFinder(quicklink)
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
