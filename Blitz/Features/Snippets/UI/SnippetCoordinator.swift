import AppKit

/// Owns the snippet flow: listener, browser, editor handoff, delivery, presence.
@MainActor
final class SnippetCoordinator {
    private let store: SnippetsStore
    private let listener: SnippetKeywordListener
    private let injector: TextInjector
    private let clipboardStore: ClipboardStore
    private let appIndex: AppIndex
    private let settings: AppSettings
    private let windowController: PaletteWindowController
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    /// Routed out so `MessageHUDController` stays owned by `AppCore`.
    private let showMessage: @MainActor (String, DialogTone) -> Void
    /// The consent dialog and the `pendingSnippetEdit` handoff to the Settings pane.
    private unowned let core: AppCore

    init(
        store: SnippetsStore,
        listener: SnippetKeywordListener,
        injector: TextInjector,
        clipboardStore: ClipboardStore,
        appIndex: AppIndex,
        settings: AppSettings,
        windowController: PaletteWindowController,
        paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator,
        showMessage: @escaping @MainActor (String, DialogTone) -> Void,
        core: AppCore
    ) {
        self.store = store
        self.listener = listener
        self.injector = injector
        self.clipboardStore = clipboardStore
        self.appIndex = appIndex
        self.settings = settings
        self.windowController = windowController
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.showMessage = showMessage
        self.core = core
    }

    // MARK: - Feature switch

    func revealSnippetsInFinder() {
        NSWorkspace.shared.open(store.snippetsDirectory)
    }

    /// Points the library at a folder as it is; nothing is moved out of the old one.
    func chooseSnippetsFolder() {
        guard
            let url = FolderPicker.choose(
                message: "Choose the folder your snippets are kept in.",
                startingAt: store.snippetsDirectory)
        else { return }
        settings.snippetsFolder = AppPaths.contentFolderSetting(for: url, named: "Snippets")
    }

    func resetSnippetsFolder() {
        settings.snippetsFolder = nil
    }

    /// The switch funnels here so enabling, which is also consent, confirms first.
    func setSnippetsEnabled(_ enabled: Bool) {
        guard enabled != settings.snippetsEnabled else { return }
        if !enabled {
            settings.snippetsEnabled = false
            return
        }

        NSApp.activateOverFrontmost()
        Task {
            guard
                await core.confirm(
                    title: "Enable snippets?",
                    message:
                        "Keyword expansion requires the Accessibility permission. Keystrokes stay on this Mac.",
                    symbol: "curlybraces", confirmTitle: "Continue", tone: .neutral,
                    confirmRole: .standard)
            else { return }

            settings.snippetsEnabled = true
            // The one prompt for this feature, raised from the gesture that asked for it.
            Permissions.ensureAccessibility()
        }
    }

    // MARK: - Feature presence

    /// Either switch off means the feature reaches the launcher not at all — rows and commands.
    func applySnippetsLauncherPresence() {
        let visible = settings.snippetsEnabled && settings.snippetsShowInLauncher
        let commands: Set<CommandID> = [.searchSnippets, .createSnippet]
        appIndex.setCommandsVisible(commands, settings.snippetsEnabled)
        appIndex.setCommandsListed(commands, settings.snippetsShowInLauncher)
        appIndex.updateSnippets(visible ? store.snippets : [])
    }

    /// Reconciles everything the switch owns; off tears down in dependency order.
    func applySnippetsEnabled() {
        if settings.snippetsEnabled {
            Task { await store.start() }
            // An unchanged library publishes no snapshot, so re-project what the store holds.
            applySnippetsLauncherPresence()
            startSnippetKeywordListener()
            return
        }
        listener.stop()
        injector.cancelAutomaticExpansion()
        store.stop()
        applySnippetsLauncherPresence()
    }

    // MARK: - Chat tools

    /// Offered only while snippets are on, though the row also opens to quicklinks.
    func chatTools(read: Bool) -> [AITool] {
        read && settings.snippetsEnabled ? SnippetToolCatalog.tools() : []
    }

    /// Templates as written, never expanded: expanding would read the clipboard and the date.
    func runTool(_ call: AIToolCall, authorize: AgentAuthorization) async -> AIToolResult {
        let request: SnippetToolCatalog.Request
        do throws(AIToolArguments.Invalid) {
            request = try SnippetToolCatalog.request(name: call.name, arguments: call.arguments)
        } catch {
            return .failure(call.id, error.message)
        }
        let denied = AgentRefusal.denied.message(for: .snippetsRead)
        guard settings.snippetsEnabled else { return .failure(call.id, denied) }
        switch request {
        case .list(let query):
            if let refusal = await authorize(AgentPrompt.readSnippets(nil)) {
                return .failure(call.id, refusal)
            }
            guard settings.snippetsEnabled else { return .failure(call.id, denied) }
            let answer = SnippetToolCatalog.listing(store.snippets.map(\.snippet), query: query)
            return AIToolResult(callID: call.id, content: answer, isError: false)
        case .read(let name):
            let snippet: Snippet
            do throws(AIToolArguments.Invalid) {
                snippet = try SnippetToolCatalog.snippet(
                    named: name, in: store.snippets.map(\.snippet))
            } catch {
                return .failure(call.id, error.message)
            }
            if let refusal = await authorize(AgentPrompt.readSnippets(snippet.name)) {
                return .failure(call.id, refusal)
            }
            guard settings.snippetsEnabled else { return .failure(call.id, denied) }
            let library = store.snippets.map(\.snippet)
            guard let current = try? SnippetToolCatalog.snippet(named: name, in: library) else {
                return .failure(call.id, SnippetToolCatalog.gone(snippet.name))
            }
            let answer = SnippetToolCatalog.answer(current)
            return AIToolResult(callID: call.id, content: answer, isError: false)
        }
    }

    // MARK: - Browsing and editing

    /// The switch gates the browser, the way Search Files re-checks its own before opening.
    func showSnippets() {
        guard settings.snippetsEnabled else { return }
        paletteCoordinator.togglePalette(mode: .snippets)
    }

    /// Opens the Snippets pane with the editor showing `record`; nil is a new one, from `draft`.
    func editSnippet(_ record: StoredSnippet?, draft: Snippet? = nil) {
        core.pendingSnippetEdit = SnippetEditRequest(record: record, draft: draft)
        settingsCoordinator.showSettings(tab: .snippets)
    }

    func showSnippetInFinder(_ record: StoredSnippet) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(record.fileURL)
    }

    /// The selection follows the row across the Pinned boundary, as the clipboard's does.
    func toggleSnippetPinned(id: StoredSnippet.ID) async {
        guard settings.snippetsEnabled, var record = store.record(id: id) else { return }
        record.snippet.isPinned.toggle()
        do {
            try await store.save(record)
        } catch {
            await core.showNotice(
                title: "Couldn’t Save the Change", message: error.localizedDescription,
                symbol: "pin", tone: .danger)
            return
        }
        let palette = core.palette
        guard palette.mode == .snippets,
            let index = store.browserRows(matching: palette.query).firstIndex(where: { $0.id == id })
        else { return }
        palette.selection = index
    }

    func duplicateSnippet(_ record: StoredSnippet) {
        Task {
            do {
                try await store.duplicate(id: record.id)
            } catch {
                await core.showNotice(
                    title: "Couldn’t Duplicate “\(record.snippet.name)”",
                    message: error.localizedDescription, symbol: "curlybraces", tone: .danger)
            }
        }
    }

    /// Always asks, as the pane does: the file itself goes, and nothing brings it back.
    func deleteSnippet(_ record: StoredSnippet) async {
        guard
            await core.confirm(
                title: "Delete “\(record.snippet.name)”?",
                message: "This removes \(record.fileURL.lastPathComponent) from your snippets folder.",
                symbol: "curlybraces", confirmTitle: "Delete")
        else { return }
        do {
            try await store.delete(id: record.id)
        } catch {
            await core.showNotice(
                title: "Couldn’t Delete “\(record.snippet.name)”",
                message: error.localizedDescription, symbol: "curlybraces", tone: .danger)
        }
    }

    // MARK: - Expansion

    /// How far back `{clipboard offset=N}` reaches; deeper isn't a snippet idiom.
    private static let clipboardHistoryDepth = 20

    func startSnippetKeywordListener() {
        // `beginAutomaticExpansion` is the gate, so this callback doesn't re-check anything.
        listener.start(
            onUserActivity: { [weak self] in self?.injector.cancelAutomaticExpansion() },
            onMatch: { [weak self] id, keyword, keywordLength, target in
                guard let self,
                    let generation = self.injector.beginAutomaticExpansion(target: target)
                else { return }
                self.expandSnippet(
                    id: id,
                    target: target,
                    expectedKeyword: keyword,
                    keywordLength: keywordLength,
                    automaticGeneration: generation)
            })
    }

    /// Recent copies, newest first; the live pasteboard leads, the poller may lag behind.
    func clipboardHistoryForExpansion() -> [String] {
        var history = clipboardStore.items
            .filter { $0.kind == .text }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.clipboardHistoryDepth)
            .compactMap(\.text)
        if let current = NSPasteboard.general.string(forType: .string), current != history.first {
            history.insert(current, at: 0)
        }
        return history
    }

    /// The browser's ↵. The target has to be read before the panel hides, as the launcher's does.
    func expandSnippetFromPalette(id: StoredSnippet.ID) {
        let target = windowController.previousTarget
        // One of our own editors is only reachable again once the palette hands key back to it.
        paletteCoordinator.hidePalette(restoreFocus: target?.ownEditor != nil)
        expandSnippet(id: id, target: target)
    }

    func performFromPalette(_ action: SnippetDefaultAction, id: StoredSnippet.ID) {
        switch action {
        case .paste: expandSnippetFromPalette(id: id)
        case .copy: copySnippetFromPalette(id: id)
        }
    }

    /// Needs no Accessibility: nothing is typed, so the target only feeds `{selection}`.
    func copySnippetFromPalette(id: StoredSnippet.ID) {
        let target = windowController.previousTarget
        paletteCoordinator.hidePalette()
        let records = store.snippets
        guard let record = records.first(where: { $0.id == id }) else { return }
        resolveExpansion(
            record, records: records, target: target,
            onCancel: { target?.restoreFocus() },
            onExpanded: { [weak self] result, prompted in
                self?.copy(result, of: record)
                if prompted { target?.restoreFocus() }
            })
    }

    /// Unmarked, so the expansion enters clipboard history like any other copy.
    private func copy(_ result: SnippetTemplateEngine.ExpansionResult, of record: StoredSnippet) {
        guard Paster.copyPlainText(result.text) else {
            showMessage("Couldn’t copy \(record.snippet.name)", .danger)
            return
        }
        guard record.snippet.showsConfirmation else { return }
        showMessage("Copied \(record.snippet.name)", .success)
    }

    /// A shortcut lands where the caret is; over the palette, that's what the palette covered.
    func expandSnippetFromHotKey(id: StoredSnippet.ID) {
        guard settings.snippetsEnabled, store.record(id: id)?.snippet.isEnabled == true else {
            return
        }
        if windowController.isVisible {
            expandSnippetFromPalette(id: id)
            return
        }
        // A window of ours that isn't an editor, such as Settings, has no caret to type at.
        guard let target = InjectionTarget.current() else {
            showMessage("Click into a text field first", .neutral)
            return
        }
        expandSnippet(id: id, target: target)
    }

    func expandSnippet(
        id: StoredSnippet.ID,
        target: InjectionTarget?,
        expectedKeyword: String? = nil,
        keywordLength: Int = 0,
        automaticGeneration: UInt? = nil
    ) {
        let records = store.snippets
        guard let record = records.first(where: { $0.id == id }) else {
            injector.cancelArgumentPrompt(
                automaticGeneration: automaticGeneration,
                target: target)
            return
        }
        // Only the interactive path needs this: it must fail before the prompt, not after.
        if automaticGeneration == nil {
            guard injector.prepareInteractiveExpansion(target: target) else { return }
        }
        let confirmation = record.snippet.showsConfirmation ? "Inserted \(record.snippet.name)" : nil
        resolveExpansion(
            record, records: records, target: target,
            onCancel: { [weak self] in
                self?.injector.cancelArgumentPrompt(
                    automaticGeneration: automaticGeneration, target: target)
            },
            onExpanded: { [weak self] result, _ in
                self?.completeSnippetExpansion(
                    result,
                    target: target,
                    expectedKeyword: expectedKeyword,
                    keywordLength: keywordLength,
                    automaticGeneration: automaticGeneration,
                    confirmation: confirmation)
            })
    }

    /// Reads the context, asks for any missing argument, and hands over the finished text.
    private func resolveExpansion(
        _ record: StoredSnippet,
        records: [StoredSnippet],
        target: InjectionTarget?,
        onCancel: @escaping @MainActor () -> Void,
        onExpanded: @escaping @MainActor (SnippetTemplateEngine.ExpansionResult, _ prompted: Bool) -> Void
    ) {
        guard SnippetTemplateEngine.usesBrowserTab(record, snippets: records) else {
            expand(
                record, records: records, browserTab: nil, target: target,
                onCancel: onCancel, onExpanded: onExpanded)
            return
        }
        // Real typing during the read bumps the generation, so a stale match can't land later.
        let browser = BrowserTabs.browser(
            preferring: [target?.externalApp, windowController.previousApp])
        Task {
            var tab: BrowserTab?
            if let browser {
                do throws(BrowserTabs.Failure) {
                    tab = try await BrowserTabs.frontTab(of: browser)
                } catch {
                    onCancel()
                    await core.reportBrowserTabFailure(
                        error, title: "Couldn’t Read the Browser Tab")
                    return
                }
            }
            expand(
                record, records: records, browserTab: tab, target: target,
                onCancel: onCancel, onExpanded: onExpanded)
        }
    }

    private func expand(
        _ record: StoredSnippet,
        records: [StoredSnippet],
        browserTab: BrowserTab?,
        target: InjectionTarget?,
        onCancel: @escaping @MainActor () -> Void,
        onExpanded: @escaping @MainActor (SnippetTemplateEngine.ExpansionResult, Bool) -> Void
    ) {
        let context = injector.captureExpansionContext(
            target: target,
            clipboardHistory: clipboardHistoryForExpansion(),
            browserTab: browserTab,
            calculate: core.calculatorCoordinator.placeholderEvaluator())
        let result = SnippetTemplateEngine.expand(
            record,
            snippets: records,
            context: context)
        guard result.missingArguments.isEmpty else {
            promptSnippetArguments(
                record: record,
                records: records,
                context: context,
                missingArgs: result.missingArguments,
                onCancel: onCancel,
                onExpanded: { onExpanded($0, true) })
            return
        }
        onExpanded(result, false)
    }

    private func promptSnippetArguments(
        record: StoredSnippet,
        records: [StoredSnippet],
        context: SnippetTemplateEngine.ExpansionContext,
        missingArgs: [SnippetTemplateEngine.MissingArgument],
        onCancel: @escaping @MainActor () -> Void,
        onExpanded: @escaping @MainActor (SnippetTemplateEngine.ExpansionResult) -> Void
    ) {
        // The open dialog would refuse this prompt, and its end must not clear the flag under it.
        guard !core.isShowingDialog else { return onCancel() }
        listener.isPromptingForArguments = true
        Task {
            let arguments = await core.fillSnippetArguments(
                snippetName: record.snippet.name,
                arguments: missingArgs)
            listener.isPromptingForArguments = false
            guard let arguments else { return onCancel() }
            onExpanded(
                SnippetTemplateEngine.expand(
                    record,
                    snippets: records,
                    context: context,
                    userArguments: arguments))
        }
    }

    private func completeSnippetExpansion(
        _ result: SnippetTemplateEngine.ExpansionResult,
        target: InjectionTarget?,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: UInt?,
        confirmation: String?
    ) {
        injector.deliver(
            InjectedText(result.text, cursorOffsetFromEnd: result.cursorOffsetFromEnd),
            target: target,
            expectedKeyword: expectedKeyword,
            keywordLength: keywordLength,
            automaticGeneration: automaticGeneration,
            onDelivered: { [weak self] in
                guard let self, let confirmation else { return }
                self.showMessage(confirmation, .success)
            })
    }
}
