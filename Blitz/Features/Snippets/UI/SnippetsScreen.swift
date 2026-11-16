import SwiftUI

/// Search Snippets: the enabled library filtered by the search field, previewed before it pastes.
struct SnippetsScreen: PaletteScreen {
    let store: SnippetsStore
    let core: AppCore
    let vm: PaletteState

    private var metrics: InterfaceMetrics { core.settings.interfaceSize.metrics }
    let openActions: () -> Void

    var rows: [StoredSnippet] { store.browserRows(matching: vm.query) }

    private var defaultAction: SnippetDefaultAction { core.settings.snippetDefaultAction }

    var primaryActionTitle: String { defaultAction.menuTitle }

    private func record(at selection: Int) -> StoredSnippet? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let record = record(at: selection) else { return nil }
        return SnippetActionsMenu.content(record: record, defaultAction: defaultAction, core: core)
    }

    func activate(at selection: Int) {
        guard let record = record(at: selection) else { return }
        core.snippetCoordinator.performFromPalette(defaultAction, id: record.id)
    }

    func secondary(at selection: Int) -> Bool {
        guard let record = record(at: selection) else { return false }
        core.snippetCoordinator.performFromPalette(defaultAction.alternate, id: record.id)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        switch shortcut {
        case .newItem:
            let name = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
            core.paletteCoordinator.hidePalette(restoreFocus: false)
            core.snippetCoordinator.editSnippet(
                nil, draft: name.isEmpty ? nil : Snippet(name: name, text: ""))
        case .edit:
            guard let record = record(at: selection) else { return false }
            core.paletteCoordinator.hidePalette(restoreFocus: false)
            core.snippetCoordinator.editSnippet(record)
        case .pin:
            guard let record = record(at: selection) else { return false }
            Task { await core.snippetCoordinator.toggleSnippetPinned(id: record.id) }
        case .showInFinder:
            guard let record = record(at: selection) else { return false }
            core.snippetCoordinator.showSnippetInFinder(record)
        case .commandDelete:
            guard let record = record(at: selection) else { return false }
            Task { await core.snippetCoordinator.deleteSnippet(record) }
        default:
            return false
        }
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        let rows = rows
        if rows.isEmpty {
            emptyState
        } else {
            let selected = record(at: selection)
            HStack(spacing: 0) {
                SnippetsList(
                    results: rows, selectedID: selected?.id, scroll: scroll,
                    onSelect: { record in
                        vm.selection = rows.firstIndex(of: record) ?? 0
                    },
                    onActivate: { activate(at: vm.selection) },
                    onActions: { record in
                        if let index = rows.firstIndex(of: record) { vm.selection = index }
                        openActions()
                    }
                )
                .frame(width: metrics.size.clipboardListWidth)
                Rectangle().fill(Theme.Colors.separator).frame(width: Theme.Size.hairline)
                SnippetPreview(record: selected)
            }
        }
    }

    /// An empty library and an over-narrow filter are different problems with different answers.
    private var emptyState: EmptyResults {
        if store.state == .loading {
            return EmptyResults(text: "Loading snippets…", symbol: "curlybraces")
        }
        return store.snippets.contains(where: { $0.snippet.isEnabled })
            ? EmptyResults(text: "No matching snippets")
            : EmptyResults(
                text: "No snippets yet", symbol: "curlybraces", hint: "Press ⌘N to create one")
    }
}

@MainActor
enum SnippetActionsMenu {
    static func content(
        record: StoredSnippet, defaultAction: SnippetDefaultAction, core: AppCore
    ) -> PopoverMenuContent {
        let isPinned = record.snippet.isPinned
        return PopoverMenuContent(
            header: record.snippet.name,
            items: [
                item(defaultAction, shortcut: "↵", record: record, core: core),
                item(defaultAction.alternate, shortcut: "⌘↵", record: record, core: core),
                PopoverMenuItem(
                    title: "Edit Snippet", systemImage: "pencil", startsSection: true, shortcut: "⌘E"
                ) {
                    core.paletteCoordinator.hidePalette(restoreFocus: false)
                    core.snippetCoordinator.editSnippet(record)
                },
                PopoverMenuItem(title: "Duplicate Snippet", systemImage: "plus.square.on.square") {
                    core.snippetCoordinator.duplicateSnippet(record)
                },
                PopoverMenuItem(title: "Create Snippet", systemImage: "plus", shortcut: "⌘N") {
                    core.paletteCoordinator.hidePalette(restoreFocus: false)
                    core.snippetCoordinator.editSnippet(nil)
                },
                PopoverMenuItem(
                    title: isPinned ? "Unpin Snippet" : "Pin Snippet",
                    systemImage: isPinned ? "pin.slash" : "pin", startsSection: true, shortcut: "⌘."
                ) {
                    Task { await core.snippetCoordinator.toggleSnippetPinned(id: record.id) }
                },
                PopoverMenuItem(
                    title: "Show in Finder", systemImage: "folder", startsSection: true, shortcut: "⌘F"
                ) {
                    core.snippetCoordinator.showSnippetInFinder(record)
                },
                PopoverMenuItem(
                    title: "Delete Snippet", systemImage: "trash", startsSection: true,
                    shortcut: "⌘⌫", isDestructive: true
                ) {
                    Task { await core.snippetCoordinator.deleteSnippet(record) }
                }
            ])
    }

    private static func item(
        _ action: SnippetDefaultAction, shortcut: String, record: StoredSnippet, core: AppCore
    ) -> PopoverMenuItem {
        PopoverMenuItem(title: action.menuTitle, systemImage: action.systemImage, shortcut: shortcut) {
            core.snippetCoordinator.performFromPalette(action, id: record.id)
        }
    }
}

extension SnippetDefaultAction {
    fileprivate var menuTitle: String {
        switch self {
        case .paste: "Paste Snippet"
        case .copy: "Copy Snippet"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .paste: "text.quote"
        case .copy: "doc.on.doc"
        }
    }
}
