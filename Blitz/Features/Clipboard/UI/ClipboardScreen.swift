import SwiftUI

/// The clipboard browser: a filtered list beside a preview of whichever entry is selected.
struct ClipboardScreen: PaletteScreen {
    let store: ClipboardStore
    let core: AppCore
    let vm: PaletteState

    private var metrics: InterfaceMetrics { core.settings.interfaceSize.metrics }
    let openActions: () -> Void
    let scrollToFollow: () -> Void

    var rows: [ClipboardItem] { store.search(vm.query, filter: vm.clipboardFilter) }

    var landingSelection: Int { store.landingIndex(in: vm.query, filter: vm.clipboardFilter) }

    /// Pinned, then one section per date bucket, as `ClipboardList` heads them.
    var sectionStarts: [Int] {
        let titles = rows.map(ClipboardList.sectionTitle)
        return titles.indices.filter { $0 == 0 || titles[$0] != titles[$0 - 1] }
    }

    var primaryActionTitle: String {
        let defaultAction = core.settings.clipboardDefaultAction
        let action = item(at: vm.selection).flatMap { defaultAction.action(for: .return, on: $0) }
        return (action ?? defaultAction).title(pastingInto: vm.pasteTarget)
    }

    private func item(at selection: Int) -> ClipboardItem? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let item = item(at: selection) else { return nil }
        return ClipboardActionsMenu.content(
            item: item, core: core, store: store, target: vm.pasteTarget)
    }

    func activate(at selection: Int) {
        guard let item = item(at: selection) else { return }
        core.clipboardCoordinator.activate(item)
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        switch shortcut {
        case .commandDelete, .delete:
            delete(at: selection)
            return true
        case .deleteAll:
            deleteAll()
            return true
        case .pin: return pin(at: selection)
        case .favoriteSlot(let index): return activatePinned(at: index)
        case .copyText:
            guard let item = item(at: selection), item.offersTextExtraction else { return false }
            core.clipboardCoordinator.copyImageText(item)
            return true
        case .edit:
            guard let item = item(at: selection) else { return false }
            core.clipboardCoordinator.renameClip(item)
            return true
        case .editContent:
            guard let item = item(at: selection), item.kind == .text else { return false }
            core.clipboardCoordinator.editClipText(item)
            return true
        case .continueInChat:
            guard core.settings.aiEnabled, let item = item(at: selection) else { return false }
            core.clipboardCoordinator.sendToAI(item)
            return true
        case .openInApp: return open(at: selection)
        default: return false
        }
    }

    /// ⌘O — a file in its own app, a link in the browser, an address in Mail.
    private func open(at selection: Int) -> Bool {
        guard let item = item(at: selection) else { return false }
        if item.kind == .file {
            core.clipboardCoordinator.openClip(item)
            return true
        }
        guard item.openableURL != nil else { return false }
        core.clipboardCoordinator.openLink(item)
        return true
    }

    /// ⌘1…⌘0 — the Nth visible pinned entry (Pinned section order), like ↵.
    private func activatePinned(at index: Int) -> Bool {
        guard let item = store.pinnedItem(at: index, in: vm.query, filter: vm.clipboardFilter) else {
            return false
        }
        core.clipboardCoordinator.activate(item)
        return true
    }

    /// ⌘↵ — the action ↵ is not set to.
    func secondary(at selection: Int) -> Bool {
        guard let item = item(at: selection) else { return false }
        return core.clipboardCoordinator.activate(item, chord: .command)
    }

    /// ⌃⌘↵ — Paste as Plain Text, or Paste while that is the default.
    func tertiary(at selection: Int) -> Bool {
        guard let item = item(at: selection) else { return false }
        return core.clipboardCoordinator.activate(item, chord: .controlCommand)
    }

    /// ⌥↵ — the palette stays up, so a run of entries goes over without re-summoning it.
    func pasteKeepingWindowOpen(at selection: Int) -> Bool {
        guard let item = item(at: selection) else { return false }
        core.clipboardCoordinator.pasteKeepingWindowOpen(item)
        return true
    }

    /// ⌘. — mirrors the Actions menu row; pinning lifts the row into the Pinned section.
    private func pin(at selection: Int) -> Bool {
        guard let item = item(at: selection) else { return false }
        core.clipboardCoordinator.togglePinnedClip(item)
        return true
    }

    /// ⌘⌫ / ⌃X — the screen owns the chord whether or not a row sits under the selection.
    private func delete(at selection: Int) {
        guard let item = item(at: selection) else { return }
        Task { await core.clipboardCoordinator.deleteClip(item) }
    }

    /// ⌃⇧X — mirrors the Actions row, confirmation included; pinned entries are kept.
    private func deleteAll() {
        Task { await core.clipboardCoordinator.deleteAllClips() }
    }

    /// Follow a row the store moved; with a query typed the highlight stays put.
    private func follow(from old: ClipFollowKey, to new: ClipFollowKey) {
        // A nil `old.id` is the first load landing, not a row that moved.
        guard old.id != nil else { return }
        let rows = rows
        if vm.query.trimmingCharacters(in: .whitespaces).isEmpty, old.id != new.id, let id = new.id,
            let index = rows.firstIndex(where: { $0.id == id })
        {
            vm.selection = index
        }
        scrollToFollow()
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            content(selection: selection, scroll: scroll)
                .onChange(of: ClipFollowKey(id: store.items.first?.id, token: vm.followToken)) {
                    old, new in
                    follow(from: old, to: new)
                }
        )
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        let rows = rows
        // Empty history: centre one message across the panel, not in the list column.
        if rows.isEmpty {
            // Names the filter, so one hiding every entry doesn't read as an empty history.
            EmptyResults(text: vm.clipboardFilter.emptyMessage)
        } else {
            let selected = item(at: selection)
            HStack(spacing: 0) {
                ClipboardList(
                    results: rows,
                    selectedID: selected?.id,
                    scroll: scroll,
                    onSelect: { item in vm.selection = rows.firstIndex(of: item) ?? 0 },
                    onActivate: { activate(at: vm.selection) },
                    onActions: { item in
                        if let index = rows.firstIndex(of: item) { vm.selection = index }
                        openActions()
                    },
                    onDragPayload: { core.clipboardCoordinator.dragPayload(for: $0) },
                    onDropped: { core.paletteCoordinator.dragLanded() }
                )
                .frame(width: metrics.size.clipboardListWidth)
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(width: 1)
                ClipboardPreview(item: selected)
            }
        }
    }
}

/// Change key for the follow-the-moved-row handler, read from the store, not the results.
private struct ClipFollowKey: Equatable {
    let id: ClipboardItem.ID?
    let token: UUID
}

/// Actions menu for an entry, shown bottom-right on right-click like `AppActionsMenu`.
@MainActor
enum ClipboardActionsMenu {
    static func content(
        item: ClipboardItem, core: AppCore, store: ClipboardStore, target: PasteTarget?
    ) -> PopoverMenuContent {
        let defaultAction = core.settings.clipboardDefaultAction
        // Chord order puts the default first, beside the ↵ it answers.
        var items: [PopoverMenuItem] = ClipboardChord.allCases.compactMap { chord in
            defaultAction.action(for: chord, on: item).map { action in
                PopoverMenuItem(
                    title: action.title(pastingInto: target), icon: icon(for: action, target: target),
                    shortcut: chord.label
                ) {
                    core.clipboardCoordinator.perform(action, on: item)
                }
            }
        }
        items.append(
            PopoverMenuItem(
                title: "Paste and Keep Window Open", icon: .paste(target, fallback: "macwindow"),
                shortcut: "⌥↵"
            ) {
                core.clipboardCoordinator.pasteKeepingWindowOpen(item)
            })
        items += pasteAsItems(item: item, core: core, target: target)
        items += handOffItems(item: item, core: core)
        items.append(
            PopoverMenuItem(
                title: item.isPinned ? "Unpin Entry" : "Pin Entry",
                systemImage: item.isPinned ? "pin.slash" : "pin", startsSection: true,
                shortcut: "⌘."
            ) {
                core.clipboardCoordinator.togglePinnedClip(item)
            })
        items.append(
            PopoverMenuItem(title: "Rename…", systemImage: "pencil", shortcut: "⌘E") {
                core.clipboardCoordinator.renameClip(item)
            })
        if item.kind == .text {
            items.append(
                PopoverMenuItem(
                    title: "Edit Text…", systemImage: "square.and.pencil", shortcut: "⌥⌘E"
                ) {
                    core.clipboardCoordinator.editClipText(item)
                })
            if core.settings.snippetsEnabled {
                items.append(
                    PopoverMenuItem(title: "Save as Snippet…", systemImage: "curlybraces") {
                        core.clipboardCoordinator.saveAsSnippet(item)
                    })
            }
        }
        if item.offersTextExtraction {
            items.append(
                PopoverMenuItem(
                    title: "Copy Text", systemImage: "doc.text.viewfinder",
                    startsSection: true, shortcut: "⇧⌘T"
                ) {
                    core.clipboardCoordinator.copyImageText(item)
                })
        }
        if item.kind == .image || item.kind == .file {
            items.append(
                PopoverMenuItem(
                    title: "Show in Finder", systemImage: "folder",
                    startsSection: !item.offersTextExtraction
                ) {
                    core.clipboardCoordinator.revealClip(item)
                })
        }
        if item.kind == .file {
            items.append(
                PopoverMenuItem(
                    title: "Open", systemImage: "arrow.up.forward.app", shortcut: "⌘O"
                ) {
                    core.clipboardCoordinator.openClip(item)
                })
            items.append(
                PopoverMenuItem(title: "Copy Path", systemImage: "doc.on.clipboard") {
                    core.clipboardCoordinator.copyClipPath(item)
                })
        }
        items.append(
            PopoverMenuItem(
                title: "Delete Entry", systemImage: "trash", startsSection: true, shortcut: "⌃X",
                isDestructive: true
            ) {
                Task { await core.clipboardCoordinator.deleteClip(item) }
            })
        items.append(
            PopoverMenuItem(
                title: "Delete All Entries", systemImage: "trash", shortcut: "⌃⇧X",
                isDestructive: true
            ) {
                Task { await core.clipboardCoordinator.deleteAllClips() }
            })
        return PopoverMenuContent(header: headerText(item), items: items)
    }

    /// Only a rich entry has a choice to make, and only among the flavours it actually stored.
    private static func pasteAsItems(
        item: ClipboardItem, core: AppCore, target: PasteTarget?
    ) -> [PopoverMenuItem] {
        guard item.isRichText else { return [] }
        var rows = ClipboardRichFormat.allCases.filter { item.formats[$0] != nil }.map { format in
            PopoverMenuItem(
                title: format.title, icon: .paste(target, fallback: "doc.richtext")
            ) {
                core.clipboardCoordinator.paste(item, as: format)
            }
        }
        rows.append(
            PopoverMenuItem(title: "Plain Text", icon: .paste(target, fallback: "doc.plaintext")) {
                core.clipboardCoordinator.pasteAsPlainText(item)
            })
        rows[0].sectionTitle = "Paste as"
        rows[0].startsSection = true
        return rows
    }

    /// Where an entry can go besides a paste: its link opened, a chat, or the share sheet.
    private static func handOffItems(item: ClipboardItem, core: AppCore) -> [PopoverMenuItem] {
        var rows: [PopoverMenuItem] = []
        if item.openableURL != nil {
            let isEmail = item.textForm == .email
            rows.append(
                PopoverMenuItem(
                    title: isEmail ? "Compose Email" : "Open Link",
                    systemImage: isEmail ? "envelope" : "safari", shortcut: "⌘O"
                ) {
                    core.clipboardCoordinator.openLink(item)
                })
        }
        if core.settings.aiEnabled {
            rows.append(
                PopoverMenuItem(title: "Send to AI", systemImage: "sparkles", shortcut: "⌘J") {
                    core.clipboardCoordinator.sendToAI(item)
                })
        }
        rows.append(
            PopoverMenuItem(title: "Share…", systemImage: "square.and.arrow.up") {
                core.clipboardCoordinator.shareClip(item)
            })
        rows[0].startsSection = true
        return rows
    }

    private static func icon(
        for action: ClipboardDefaultAction, target: PasteTarget?
    ) -> PopoverMenuIcon {
        switch action {
        case .paste: .paste(target, fallback: "doc.on.clipboard")
        case .copy: .symbol("doc.on.doc")
        case .pastePlainText: .paste(target, fallback: "doc.plaintext")
        }
    }

    private static func headerText(_ item: ClipboardItem) -> String {
        if let title = item.title { return String(title.prefix(40)) }
        switch item.kind {
        case .text:
            // Collapse whitespace so a multi-line copy stays a clean one-line title.
            let oneLine = (item.text ?? "").split(whereSeparator: \.isWhitespace).joined(
                separator: " ")
            return String(oneLine.prefix(40))
        case .image: return "Image"
        case .file: return (item.filePath as NSString?)?.lastPathComponent ?? "File"
        }
    }
}

extension ClipboardDefaultAction {
    /// A paste names the app it lands in, in the footer pill and the ⌘K menu alike.
    func title(pastingInto target: PasteTarget?) -> String {
        guard let target, self != .copy else { return title }
        return "\(title) to \(target.name)"
    }
}
