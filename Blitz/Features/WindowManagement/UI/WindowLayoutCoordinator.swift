import AppKit

/// Owns layouts: the library, the one run funnel with its gate, capture, and a deletion's cleanup.
@MainActor
final class WindowLayoutCoordinator {
    private let store: WindowLayoutStore
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let hotKeys: HotKeyManager
    private let favorites: FavoritesStore
    private let visibility: VisibilityStore
    private let ranking: LauncherRankingStore
    private let aliases: AliasStore
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    /// Dialog and message-HUD presentation, and the editor handoff. Never state this type owns.
    private unowned let core: AppCore
    /// One run at a time: a held shortcut must not stack two passes over the same windows.
    private var run: Task<WindowLayoutRunner.Outcome, Never>?

    init(
        store: WindowLayoutStore, settings: AppSettings, appIndex: AppIndex,
        hotKeys: HotKeyManager, favorites: FavoritesStore, visibility: VisibilityStore,
        ranking: LauncherRankingStore, aliases: AliasStore,
        paletteCoordinator: PaletteCoordinator, settingsCoordinator: SettingsCoordinator,
        core: AppCore
    ) {
        self.store = store
        self.settings = settings
        self.appIndex = appIndex
        self.hotKeys = hotKeys
        self.favorites = favorites
        self.visibility = visibility
        self.ranking = ranking
        self.aliases = aliases
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.core = core
    }

    // MARK: - Feature presence

    func applyWindowLayoutsPresence() {
        let visible = settings.windowManagementEnabled && settings.windowLayoutsShowInLauncher
        appIndex.setWindowLayouts(visible ? store.layouts : [])
        let commands: Set<CommandID> = [.createWindowLayout, .captureWindowLayout]
        appIndex.setCommandsVisible(commands, settings.windowManagementEnabled)
        appIndex.setCommandsListed(commands, settings.windowLayoutsShowInLauncher)
    }

    // MARK: - Running

    /// The one funnel for a palette row, a global shortcut and the pane's Apply alike.
    func runWindowLayout(id: UUID) {
        guard settings.windowManagementEnabled, let layout = store.layout(id: id) else { return }
        // Never restoreFocus: an opened app activates itself, and handing focus back races that.
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        let gap = CGFloat(settings.windowGap)
        run?.cancel()
        run = Task { [weak self] in
            let outcome = await WindowLayoutRunner.run(layout, gap: gap)
            await self?.report(outcome, for: layout)
            return outcome
        }
    }

    // MARK: - Chat tools

    /// The agent's funnel: the same switch and one-run rule, answered in text rather than a HUD.
    func runTool(_ call: AIToolCall, authorize: AgentAuthorization) async -> AIToolResult {
        let request: WindowLayoutToolCatalog.Request
        do throws(AIToolArguments.Invalid) {
            request = try WindowLayoutToolCatalog.request(name: call.name, arguments: call.arguments)
        } catch {
            return .failure(call.id, error.message)
        }
        guard settings.windowManagementEnabled else {
            return .failure(call.id, AgentRefusal.denied.message(for: .windowLayouts))
        }
        let layouts = store.layouts.map(Self.toolLayout)
        guard case .apply(let name) = request else {
            let answer = WindowLayoutToolCatalog.listing(layouts)
            return AIToolResult(callID: call.id, content: answer, isError: false)
        }
        let picked: WindowLayoutToolCatalog.Layout
        do throws(AIToolArguments.Invalid) {
            picked = try WindowLayoutToolCatalog.layout(named: name, in: layouts)
        } catch {
            return .failure(call.id, error.message)
        }
        // Checked, never prompted for: macOS's own request belongs to a gesture of the user's.
        guard Permissions.isAccessibilityTrusted() else {
            return .failure(call.id, WindowLayoutToolCatalog.needsAccessibility)
        }
        if let refusal = await authorize(WindowLayoutToolCatalog.prompt(for: picked)) {
            return .failure(call.id, refusal)
        }
        guard settings.windowManagementEnabled, let layout = store.layout(id: picked.id) else {
            return .failure(call.id, WindowLayoutToolCatalog.gone(picked))
        }
        let gap = CGFloat(settings.windowGap)
        run?.cancel()
        let task = Task { await WindowLayoutRunner.run(layout, gap: gap) }
        run = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if outcome.isBlockedOnPermission {
            return .failure(call.id, WindowLayoutToolCatalog.needsAccessibility)
        }
        let result = WindowLayoutToolCatalog.result(
            of: picked,
            outcome: .init(
                placed: outcome.placed, opened: outcome.opened, problems: Self.detail(for: outcome)))
        return AIToolResult(callID: call.id, content: result.text, isError: result.isError)
    }

    private static func toolLayout(_ layout: WindowLayout) -> WindowLayoutToolCatalog.Layout {
        WindowLayoutToolCatalog.Layout(id: layout.id, name: layout.name, summary: layout.summary)
    }

    func prepareForTermination() {
        run?.cancel()
        run = nil
    }

    // MARK: - Library

    @discardableResult
    func addWindowLayout(
        _ draft: WindowLayout
    ) throws(WindowLayoutValidationError) -> WindowLayout {
        try store.add(draft)
    }

    func updateWindowLayout(_ draft: WindowLayout) throws(WindowLayoutValidationError) {
        try store.update(draft)
    }

    func duplicateWindowLayout(id: UUID) {
        do {
            _ = try store.duplicate(id: id)
        } catch {
            Task { await report(failure: error) }
        }
    }

    func deleteWindowLayout(id: UUID) {
        guard let layout = store.remove(id: id) else { return }
        // Unwound only once the row is gone, so a kept record never loses its shortcut.
        removeWindowLayoutReferences(ids: [layout.id], entryIDs: [layout.entryID])
    }

    @discardableResult
    func replaceWindowLayouts(_ incoming: [WindowLayout]) -> Int {
        let previous = Dictionary(uniqueKeysWithValues: store.layouts.map { ($0.id, $0) })
        let count = store.replace(with: incoming)
        let live = Set(store.layouts.map(\.id))
        let removed = Set(previous.keys).subtracting(live)
        removeWindowLayoutReferences(
            ids: removed, entryIDs: Set(removed.compactMap { previous[$0]?.entryID }))
        return count
    }

    // MARK: - Editing

    /// Opens the Window Management pane with the editor showing `layout`; nil is a new one.
    func editWindowLayout(_ layout: WindowLayout?) {
        core.pendingWindowLayoutEdit = WindowLayoutEditRequest(layout: layout)
        settingsCoordinator.showSettings(tab: .windowManagement)
    }

    /// Capture never saves silently: the draft lands in the editor so it can be seen and named.
    func captureWindowLayout() {
        let (entries, frontmostEntryID) = WindowLayoutRunner.captureCurrentWindows()
        guard !entries.isEmpty else {
            core.showMessage("No windows to capture", tone: .neutral)
            return
        }
        // Gapless by construction, so a later change to `windowGap` can't move every window.
        let draft = WindowLayout(
            name: Self.uniqueCaptureName(among: store.layouts), usesPreferredGap: false,
            entries: entries, frontmostEntryID: frontmostEntryID)
        core.pendingWindowLayoutEdit = WindowLayoutEditRequest(layout: draft, isCapture: true)
        settingsCoordinator.showSettings(tab: .windowManagement)
    }

    // MARK: - Reporting

    private func report(_ outcome: WindowLayoutRunner.Outcome, for layout: WindowLayout) async {
        if outcome.isBlockedOnPermission {
            let openSettings = await core.reportFailure(
                title: "Blitz Needs Accessibility Access",
                message: "Arranging windows uses the same permission as pasting.",
                symbol: layout.symbol, recovery: "Open Settings")
            if openSettings { Permissions.openAccessibilitySettings() }
            return
        }
        // Placing windows is its own feedback, so a clean run says nothing at all.
        guard let detail = Self.detail(for: outcome) else { return }
        guard outcome.didAnything else {
            await core.showNotice(
                title: "Couldn't Run “\(layout.name)”", message: detail, symbol: layout.symbol,
                tone: .danger)
            return
        }
        core.showMessage("\(layout.name) — \(detail)", tone: .neutral)
    }

    /// What went wrong, or nil when everything the layout asked for happened.
    private static func detail(for outcome: WindowLayoutRunner.Outcome) -> String? {
        var parts: [String] = []
        if let skipped = WindowLayoutPlan(placements: [], skipped: outcome.skipped).skippedSummary {
            parts.append(skipped)
        }
        if !outcome.neverAppeared.isEmpty {
            let count = outcome.neverAppeared.count
            parts.append(count == 1 ? "1 app didn't open" : "\(count) apps didn't open")
        }
        let failed = outcome.openFailures.count
        if failed > 0 {
            parts.append(failed == 1 ? "1 app couldn't open" : "\(failed) apps couldn't open")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func report(failure: WindowLayoutValidationError) async {
        await core.showNotice(
            title: "Couldn't Save the Layout",
            message: failure.errorDescription ?? "The layout could not be saved.",
            symbol: WindowLayout.sfSymbol, tone: .danger)
    }

    private func removeWindowLayoutReferences(ids: Set<UUID>, entryIDs: Set<String>) {
        for id in ids {
            let action = HotKeyAction.windowLayout(id: id)
            if hotKeys.recordingAction == action { hotKeys.recordingAction = nil }
            hotKeys.setBinding(nil, for: action)
        }
        favorites.remove(keys: entryIDs)
        visibility.removeItemKeys(entryIDs)
        aliases.removeKeys(entryIDs)
        for entryID in entryIDs {
            ranking.reset(itemKey: entryID)
        }
    }

    /// "Captured Layout", then " 2", so the editor opens on a name that will validate.
    private static func uniqueCaptureName(among existing: [WindowLayout]) -> String {
        let taken = Set(existing.map { $0.name.lowercased() })
        let base = "Captured Layout"
        guard taken.contains(base.lowercased()) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }
}
