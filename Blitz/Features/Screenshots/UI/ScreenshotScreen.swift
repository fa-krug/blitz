import SwiftUI

/// File Search's list, preview and actions over the captures Spotlight knows about.
struct ScreenshotScreen: PaletteScreen {
    let session: FileSearchSession
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    private var metrics: InterfaceMetrics { core.settings.interfaceSize.metrics }

    var rows: [FileSearchResult] { session.results }

    private var isShowingRecents: Bool {
        ScreenshotQuery(parsing: vm.query).terms.isEmpty
    }

    var primaryActionTitle: String { "Open File" }

    private func result(at selection: Int) -> FileSearchResult? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let result = result(at: selection) else { return nil }
        let coordinator = core.screenshotCoordinator
        let copyText = PopoverMenuItem(
            title: "Copy Text", systemImage: "text.viewfinder", shortcut: "⇧⌘T"
        ) { coordinator.copyText(result) }
        return FileSearchActionsMenu.content(
            result: result, core: core, vm: vm, target: vm.pasteTarget, session: session,
            extraCopies: [copyText])
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
        let files = core.fileSearchCoordinator
        switch shortcut {
        case .copyFile: files.copyFile(result)
        case .copyName: files.copyName(result)
        case .copyPath: files.copyPath(result)
        case .pasteFile: files.pasteFile(result)
        case .copyText: core.screenshotCoordinator.copyText(result)
        case .quickLook: vm.fileSearchQuickLook.toggle()
        case .delete: core.screenshotCoordinator.trash(result)
        default: return false
        }
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        if session.state == .failed {
            EmptyResults(text: "Screenshot search is unavailable")
        } else if rows.isEmpty {
            emptyState
        } else {
            let selected = result(at: selection)
            HStack(spacing: 0) {
                FileSearchList(
                    title: isShowingRecents ? "Recent Screenshots" : "Results",
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

    @ViewBuilder
    private var emptyState: some View {
        if session.state != .ready {
            Color.clear
        } else if isShowingRecents {
            EmptyResults(text: "No screenshots found")
        } else {
            EmptyResults(text: "No matching screenshots")
        }
    }
}
