import QuartzCore
import SwiftUI

/// Restated here so launcher motion can change without moving an extension surface.
@MainActor private enum ExtensionMenuMotion {
    private static let entryScale: CGFloat = 0.94
    private static let exitScaleDelta: CGFloat = 0.04

    static let panel = MenuPanelMotion(
        entryScale: entryScale,
        maximumScale: 1.003,
        exitScaleDelta: exitScaleDelta,
        expansionDuration: 0.10,
        settleDuration: 0.05,
        exitDuration: 0.18,
        expansionTiming: CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1),
        settleTiming: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1),
        exitTiming: CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1))
}

/// `ExtensionScreen` decides the row order; this maps `selection` 1:1 onto visible rows.
struct ExtensionCommandScreen: PaletteScreen {
    let screen: ExtensionScreen
    let extensions: ExtensionManager
    let vm: PaletteState
    let openActions: () -> Void

    /// `assets/` of the running extension, so the icons it names resolve.
    var assetsPath: String? {
        guard let name = extensions.running?.extensionName,
            let owner = extensions.extensionNamed(name)
        else { return nil }
        return owner.assetsPath
    }

    /// Selectable rows only: a section header is drawn but never landed on, and so is a separator.
    var rows: [ExtensionScreen.Item] { screen.items }

    /// A form owns the whole keyboard: its fields are the text, so the search field steps aside.
    var hidesSearchField: Bool { isForm }

    /// A form, a rowless Detail, an empty list's `EmptyView` and a failure all act without a row.
    var actsWithoutRows: Bool {
        isForm || screen.kind == .detail || screen.actsWithoutItems || failure != nil
    }

    /// A thrown error, or a root component this screen cannot draw.
    var failure: ExtensionFailure? {
        switch extensions.state {
        case .failed(let failure): return failure
        case .rendered:
            guard case .unsupported(let type) = screen.kind, !type.isEmpty else { return nil }
            return .unsupportedRoot(type)
        default: return nil
        }
    }

    /// One ⌘K row and what it does: an `ActionPanel` action, a toast button or a failure's remedy.
    private struct MenuEntry {
        var item: ExtensionActionItem
        let run: () -> Void
    }

    /// A missing preference is fixed in Settings, so that is ↵; anything else is worth a retry.
    private func failureEntries(_ failure: ExtensionFailure) -> [MenuEntry] {
        let extensions = extensions
        func entry(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> MenuEntry {
            MenuEntry(
                item: ExtensionActionItem(
                    title: title, icon: ExtensionImage.Resolved(source: .symbol(symbol))),
                run: run)
        }
        let retry = entry("Retry", "arrow.clockwise") { extensions.retry() }
        let copy = entry("Copy Error", "doc.on.doc") { extensions.copyFailureReport(failure) }
        let preferences = entry("Open Extension Preferences", "gearshape") {
            extensions.openPreferences(scope: "extension")
        }
        var entries =
            failure.reason == .missingPreferences
            ? [preferences, retry, copy] : [retry, copy, preferences]
        entries[0].item.shortcut = ExtensionActionKeys.returnCaps
        entries[1].item.shortcut = ExtensionActionKeys.commandReturnCaps
        return entries
    }

    /// The panel's actions, with ↵ and ⌘↵ drawn on the two they fire, then the toast's buttons.
    private func menuEntries(at selection: Int) -> [MenuEntry] {
        if let failure { return failureEntries(failure) }
        let actions = panelActions(at: selection)
        let caps = ExtensionActionKeys.caps(for: actions.map(\.keySlot), isForm: isForm)
        let extensions = extensions
        var entries = zip(actions, ExtensionActionsMenu.rows(actions, assetsPath: assetsPath))
            .enumerated().map { index, pair in
                var item = pair.1
                item.shortcut = caps[index]
                let handler = pair.0.handler
                return MenuEntry(item: item) {
                    if let handler { extensions.dispatch(handler: handler) }
                }
            }
        for (index, action) in toastActions.enumerated() {
            entries.append(
                MenuEntry(
                    item: ExtensionActionItem(
                        title: action.title,
                        icon: ExtensionImage.Resolved(source: .symbol("bell")),
                        shortcut: ExtensionKeyShortcut(action.shortcut)?.caps.joined(),
                        startsSection: index == 0 && !entries.isEmpty),
                    run: { extensions.runToastAction(token: action.token) }))
        }
        return entries
    }

    /// The buttons of the toast showing over the screen, which ⌘K and their shortcuts also reach.
    private var toastActions: [ExtensionToast.Action] {
        guard let toast = extensions.toasts.last else { return [] }
        return [toast.primaryAction, toast.secondaryAction].compactMap(\.self)
    }

    private func panelActions(at selection: Int) -> [ExtensionAction] {
        ExtensionScreen.actions(in: screen.actionPanel(forItemAt: selection))
    }

    /// A text area edits with ↑/↓ itself, so only ⇥ leaves it.
    func ownsVerticalKeys(at selection: Int) -> Bool {
        guard isForm, rows.indices.contains(selection) else { return false }
        return ExtensionFormField(type: rows[selection].node.type).ownsVerticalKeys
    }

    /// ⇥ / ⇧⇥ walk the fields, wrapping at either end as Raycast's form does.
    func tabTarget(from selection: Int, backwards: Bool) -> Int? {
        guard isForm, !rows.isEmpty else { return nil }
        return (selection + (backwards ? -1 : 1) + rows.count) % rows.count
    }

    var sectionStarts: [Int] { PaletteRowIndex(sectionCounts: screen.sectionCounts).sectionStarts }

    /// A Grid needs both axes: without this ↓ walks sideways one tile at a time.
    func move(_ delta: Int, axis: PaletteAxis, from selection: Int) -> Int? {
        guard case .grid(let layout) = screen.kind, !rows.isEmpty else { return nil }
        switch axis {
        case .vertical:
            let geometry = ExtensionGridGeometry(
                counts: screen.sectionCounts, columns: layout.columns)
            return delta > 0 ? geometry.down(from: selection) : geometry.up(from: selection)
        case .horizontal:
            return min(max(selection + delta, 0), rows.count - 1)
        }
    }

    /// The primary action is the panel's first `Action`.
    private func primaryAction(at selection: Int) -> ExtensionAction? {
        panelActions(at: selection).first
    }

    /// A submenu reached first is a grouping device, so its title stands in for the leaf's.
    var primaryActionTitle: String {
        if let failure { return failureEntries(failure)[0].item.title }
        let primary = primaryAction(at: vm.selection)
        return primary?.enclosingSubmenuTitle ?? primary?.title ?? "Run"
    }

    func hasPrimaryAction(at selection: Int) -> Bool {
        failure != nil || primaryAction(at: selection) != nil
    }

    /// A form usually ships one Submit action, and a one-row ⌘K panel is noise beside its pill.
    func hasActions(at selection: Int) -> Bool {
        guard isForm, failure == nil else { return true }
        return panelActions(at: selection).count > 1
    }

    /// A form's pill stands even with no field to land on: the action belongs to the screen.
    var isForm: Bool {
        if case .form = screen.kind { return true }
        return false
    }

    /// A command's rows carry tinted icons and its panel scrolls; a menu row cannot.
    func menuContent(
        at selection: Int, searchQuery: ActionMenuSearchQuery, menuSelection: Binding<Int>,
        onActivate: @escaping (Int) -> Void
    ) -> PaletteMenuContent? {
        let entries = menuEntries(at: selection)
        guard !entries.isEmpty else { return nil }
        var pendingSection = false
        var filtered: [MenuEntry] = []
        var bestMatch: (index: Int, score: Int)?
        for entry in entries {
            if entry.item.startsSection { pendingSection = true }
            guard let score = searchQuery.score(entry.item.title) else { continue }
            var match = entry
            match.item.startsSection = pendingSection && !filtered.isEmpty
            filtered.append(match)
            pendingSection = false
            if score > (bestMatch?.score ?? .min) {
                bestMatch = (filtered.count - 1, score)
            }
        }
        let header =
            failure == nil ? ExtensionActionsMenu.header(screen: screen, selection: selection) : nil
        let items = filtered.map(\.item)
        return PaletteMenuContent(
            rowCount: filtered.count, preferredSelection: bestMatch?.index,
            view: { _ in
                AnyView(
                    ExtensionActionsPanel(
                        header: header, items: items, selection: menuSelection,
                        onActivate: onActivate))
            },
            activate: { index in filtered[index].run() },
            clipPath: { bounds, metrics, _ in
                UnevenRoundedRectangle(
                    topLeadingRadius: metrics.radius.menuPanel,
                    bottomLeadingRadius: metrics.radius.menuPanel,
                    bottomTrailingRadius: metrics.size.menuButton / 2,
                    topTrailingRadius: metrics.radius.menuPanel,
                    style: .continuous
                ).path(in: bounds).cgPath
            },
            motion: ExtensionMenuMotion.panel)
    }

    func activate(at selection: Int) {
        if let failure {
            failureEntries(failure)[0].run()
            return
        }
        guard let primary = primaryAction(at: selection) else { return }
        if primary.enclosingSubmenuTitle != nil {
            vm.selection = selection
            openActions()
            return
        }
        guard let handler = primary.handler else { return }
        extensions.dispatch(handler: handler)
    }

    /// The second action, unless one claims ⌘↵ for itself; a form's ⌘↵ submits instead.
    func secondary(at selection: Int) -> Bool {
        if let failure {
            failureEntries(failure)[1].run()
            return true
        }
        let actions = panelActions(at: selection)
        guard
            let index = ExtensionActionKeys.secondary(in: actions.map(\.keySlot), isForm: isForm),
            let handler = actions[index].handler
        else { return false }
        extensions.dispatch(handler: handler)
        return true
    }

    /// The `searchBarAccessory` dropdown; an empty one states and opens nothing, so it is none.
    var searchAccessory: ExtensionSearchAccessory? {
        guard let accessory = ExtensionSearchAccessory(node: screen.searchBarAccessory),
            !accessory.items.isEmpty
        else { return nil }
        return accessory
    }

    /// The header control for it, as an opaque box the palette only seats and toggles.
    func searchAccessoryButton(
        _ accessory: ExtensionSearchAccessory, isOpen: Bool, action: @escaping () -> Void
    ) -> AnyView {
        AnyView(
            ExtensionSearchAccessoryButton(
                accessory: accessory, value: extensions.accessorySelection(accessory),
                assetsPath: assetsPath, isOpen: isOpen, action: action))
    }

    /// A form's `Form.LinkAccessory`, as an opaque box the palette seats in its header.
    var linkAccessory: AnyView? {
        ExtensionLinkAccessory(node: screen.searchBarAccessory).map { AnyView($0) }
    }

    /// A refresh behind rows already shown; an empty list says "Loading…" in its body instead.
    var loadingIndicator: AnyView? {
        guard screen.isLoading else { return nil }
        switch screen.kind {
        case .list, .grid:
            guard !rows.isEmpty else { return nil }
        case .detail, .form:
            break
        case .unsupported:
            return nil
        }
        return AnyView(ExtensionLoadingIndicator())
    }

    /// Its choices as a palette menu, so the arrows, ↵, Escape and the click-away come free.
    func searchAccessoryMenu(
        searchQuery: ActionMenuSearchQuery, menuSelection: Binding<Int>,
        onActivate: @escaping (Int) -> Void
    ) -> PaletteMenuContent? {
        guard let accessory = searchAccessory else { return nil }
        var items: [ExtensionPickerItem] = []
        var bestMatch: (index: Int, score: Int)?
        for item in accessory.items {
            guard let score = searchQuery.score(item.title) else { continue }
            items.append(item)
            if score > (bestMatch?.score ?? .min) {
                bestMatch = (items.count - 1, score)
            }
        }
        let chosen = extensions.accessorySelection(accessory).map { Set([$0]) } ?? []
        let assetsPath = assetsPath
        let extensions = extensions
        return PaletteMenuContent(
            rowCount: items.count, preferredSelection: bestMatch?.index,
            view: { _ in
                AnyView(
                    ExtensionPickerList(
                        items: items, selection: menuSelection.wrappedValue,
                        chosen: chosen, assetsPath: assetsPath,
                        width: ExtensionSearchAccessoryButton.listWidth,
                        searchPlaceholder: "Search…", onSelect: onActivate,
                        onHighlight: { menuSelection.wrappedValue = $0 }))
            },
            activate: { index in
                extensions.chooseAccessorySelection(accessory, value: items[index].value)
            },
            clipPath: { bounds, metrics, _ in
                RoundedRectangle(cornerRadius: metrics.radius.menuPanel, style: .continuous)
                    .path(in: bounds).cgPath
            },
            motion: ExtensionMenuMotion.panel)
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            ExtensionCommandView(
                screen: screen,
                state: extensions.state,
                selection: selection,
                assetsPath: assetsPath,
                scroll: scroll,
                onSelect: { vm.selection = $0 },
                onActivate: { activate(at: $0) },
                onActions: { index in
                    vm.selection = index
                    openActions()
                },
                onFieldChange: { field, value in
                    guard let handler = field.handler("onBlitzChange") else { return }
                    extensions.dispatch(handler: handler, arguments: [value])
                },
                onReach: { reach($0) }
            ))
    }

    /// A row scrolled into view; the manager decides whether that is far enough to page.
    func reach(_ index: Int?) {
        guard let pagination = screen.pagination else { return }
        extensions.loadMore(
            pagination, reaching: index, itemCount: rows.count, isLoading: screen.isLoading)
    }

    /// Matched before the palette's own handling; true when an action fired.
    func dispatchShortcut(key: KeyEquivalent, modifiers: EventModifiers, at selection: Int) -> Bool {
        if let action = toastActions.first(where: {
            ExtensionKeyShortcut($0.shortcut)?.matches(key: key, modifiers: modifiers) == true
        }) {
            extensions.runToastAction(token: action.token)
            return true
        }
        let actions = panelActions(at: selection)
        guard
            let handler = actions.first(where: { $0.matches(key: key, modifiers: modifiers) })?
                .handler
        else { return false }
        extensions.dispatch(handler: handler)
        return true
    }
}
