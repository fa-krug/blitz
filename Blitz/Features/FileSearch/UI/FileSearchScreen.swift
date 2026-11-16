import SwiftUI

struct FileSearchScreen: PaletteScreen {
    let session: FileSearchSession
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    private var metrics: InterfaceMetrics { core.settings.interfaceSize.metrics }

    var rows: [FileSearchResult] { session.results }

    private var isShowingRecents: Bool {
        vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var primaryActionTitle: String {
        guard let result = result(at: vm.selection) else { return "Open File" }
        return result.isDirectory ? "Open Folder" : "Open File"
    }

    private func result(at selection: Int) -> FileSearchResult? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let result = result(at: selection) else { return nil }
        let coordinator = core.fileSearchCoordinator
        return FileSearchActionsMenu.content(
            result: result, core: core, vm: vm, target: vm.pasteTarget,
            favorites: FavoriteActions(
                isFavorite: coordinator.isFavorite(result),
                toggle: { coordinator.toggleFavorite(result) }))
    }

    func activate(at selection: Int) {
        guard let result = result(at: selection) else { return }
        core.fileSearchCoordinator.open(result)
    }

    func secondary(at selection: Int) -> Bool {
        guard let result = result(at: selection) else { return false }
        core.fileSearchCoordinator.showInFinder(result)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard let result = result(at: selection) else { return false }
        switch shortcut {
        // ⌘Y — the overlay follows the selection, so toggling is all the state it needs.
        case .quickLook: vm.fileSearchQuickLook.toggle()
        case .toggleFavorite: core.fileSearchCoordinator.toggleFavorite(result)
        default: return FileSearchActionsMenu.perform(shortcut, result: result, core: core)
        }
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        if session.state == .failed {
            EmptyResults(text: "File search is unavailable")
        } else if rows.isEmpty {
            emptyState
        } else {
            let selected = result(at: selection)
            HStack(spacing: 0) {
                FileSearchList(
                    title: isShowingRecents ? "Recently Used" : "Results",
                    results: rows,
                    selectedID: selected?.id,
                    scroll: scroll,
                    onSelect: { result in vm.selection = rows.firstIndex(of: result) ?? 0 },
                    onActivate: { core.fileSearchCoordinator.open($0) },
                    onActions: { result in
                        if let index = rows.firstIndex(of: result) { vm.selection = index }
                        openActions()
                    },
                    onDropped: { core.paletteCoordinator.dragLanded() }
                )
                .frame(width: metrics.size.clipboardListWidth)
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(width: Theme.Size.hairline)
                FileSearchPreview(result: selected)
            }
            .overlay {
                if vm.fileSearchQuickLook, let selected {
                    FileSearchQuickLook(result: selected) { vm.fileSearchQuickLook = false }
                }
            }
        }
    }

    /// Nothing is said while a query runs: the rows it replaces would only flash a message.
    @ViewBuilder
    private var emptyState: some View {
        if session.state != .ready {
            Color.clear
        } else if isShowingRecents {
            EmptyResults(text: "Type to search files and folders")
        } else {
            EmptyResults(text: vm.fileSearchFilter.emptyMessage)
        }
    }
}

@MainActor
enum FileSearchActionsMenu {
    /// `extraCopies` join the copy section, and `session` is the list a trashed row leaves.
    static func content(
        result: FileSearchResult, core: AppCore, vm: PaletteState, target: PasteTarget?,
        session: FileSearchSession? = nil, extraCopies: [PopoverMenuItem] = [],
        favorites: FavoriteActions? = nil, quickLook: Bool = true
    ) -> PopoverMenuContent {
        let coordinator = core.fileSearchCoordinator
        var opening = [
            PopoverMenuItem(
                title: result.isDirectory ? "Open Folder" : "Open File",
                systemImage: result.isDirectory ? "folder" : "doc", shortcut: "↵"
            ) { coordinator.open(result) },
            PopoverMenuItem(
                title: "Show in Finder", systemImage: "folder", shortcut: "⌘↵"
            ) { coordinator.showInFinder(result) },
            PopoverMenuItem(title: "Share…", systemImage: "square.and.arrow.up") {
                coordinator.share(result)
            }
        ]
        // Only a screen that draws the overlay can offer it; root search has no preview.
        if quickLook {
            opening.insert(
                PopoverMenuItem(title: "Quick Look", systemImage: "eye", shortcut: "⌘Y") {
                    vm.fileSearchQuickLook = true
                }, at: 2)
        }
        opening += favorites?.items ?? []
        let copies = [
            PopoverMenuItem(
                title: "Copy File", systemImage: "doc.on.clipboard", startsSection: true,
                shortcut: "⇧⌘C"
            ) { coordinator.copyFile(result) },
            PopoverMenuItem(
                title: target.map { "Paste File to \($0.name)" } ?? "Paste File",
                icon: .paste(target, fallback: "doc.on.clipboard"), shortcut: "⇧⌘V"
            ) { coordinator.pasteFile(result) },
            PopoverMenuItem(
                title: "Copy Name", systemImage: "doc.on.clipboard", shortcut: "⌥⌘C"
            ) { coordinator.copyName(result) },
            PopoverMenuItem(
                title: "Copy Path", systemImage: "doc.on.clipboard", shortcut: "⌃⌘C"
            ) { coordinator.copyPath(result) }
        ]
        let trash = PopoverMenuItem(
            title: "Move to Trash", systemImage: "trash", startsSection: true,
            shortcut: "⌃X", isDestructive: true
        ) { coordinator.trash(result, from: session) }
        return PopoverMenuContent(
            header: result.name, items: opening + copies + extraCopies + [trash])
    }

    /// The menu's chords, so a screen listing files among other rows answers them identically.
    static func perform(_ shortcut: PaletteShortcut, result: FileSearchResult, core: AppCore) -> Bool {
        let coordinator = core.fileSearchCoordinator
        switch shortcut {
        case .copyFile: coordinator.copyFile(result)
        case .copyName: coordinator.copyName(result)
        case .copyPath: coordinator.copyPath(result)
        case .pasteFile: coordinator.pasteFile(result)
        // No ⌃⇧X: there is no "all" to trash, only the row under the selection.
        case .delete: coordinator.trash(result)
        default: return false
        }
        return true
    }
}
