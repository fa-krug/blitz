import AppKit

/// Owns custom commands: the library, the one run funnel with its gates, and a deletion's cleanup.
@MainActor
final class CustomCommandCoordinator {
    private let store: CustomCommandStore
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let hotKeys: HotKeyManager
    private let favorites: FavoritesStore
    private let visibility: VisibilityStore
    private let ranking: LauncherRankingStore
    private let aliases: AliasStore
    /// Dialog and message-HUD presentation only — never for state this type owns.
    private unowned let core: AppCore
    private let activationPolicy: ActivationPolicy
    /// Every open terminal window, oldest first; each leaves on its own close.
    private var terminals: [CommandTerminalPresenter] = []

    init(
        store: CustomCommandStore,
        settings: AppSettings,
        appIndex: AppIndex,
        paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator,
        hotKeys: HotKeyManager,
        favorites: FavoritesStore,
        visibility: VisibilityStore,
        ranking: LauncherRankingStore,
        aliases: AliasStore,
        activationPolicy: ActivationPolicy,
        core: AppCore
    ) {
        self.store = store
        self.settings = settings
        self.appIndex = appIndex
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.hotKeys = hotKeys
        self.favorites = favorites
        self.visibility = visibility
        self.ranking = ranking
        self.aliases = aliases
        self.activationPolicy = activationPolicy
        self.core = core
    }

    // MARK: - Feature presence

    func applyCustomCommandsPresence() {
        let visible = settings.customCommandsEnabled && settings.customCommandsShowInLauncher
        appIndex.setCustomCommands(visible ? store.commands : [])
    }

    // MARK: - Library

    @discardableResult
    func addCustomCommand(_ draft: CustomCommand) throws -> CustomCommand {
        try store.add(draft)
    }

    func updateCustomCommand(_ draft: CustomCommand) throws {
        try store.update(draft)
    }

    /// Keeps the command and its shortcut, but takes it out of every surface that could run it.
    func setCustomCommandEnabled(_ enabled: Bool, id: UUID) {
        store.setEnabled(enabled, id: id)
    }

    func deleteCustomCommand(id: UUID) {
        guard let command = store.command(id: id) else { return }
        removeCustomCommandReferences(ids: [id], entryIDs: [command.entryID])
        store.remove(id: id)
    }

    @discardableResult
    func replaceCustomCommands(_ commands: [CustomCommand]) -> Int {
        let previous = Dictionary(uniqueKeysWithValues: store.commands.map { ($0.id, $0) })
        let count = store.replace(with: commands)
        let liveIDs = Set(store.commands.map(\.id))
        let removed = Set(previous.keys).subtracting(liveIDs)
        let removedEntryIDs = Set(removed.compactMap { previous[$0]?.entryID })
        removeCustomCommandReferences(ids: removed, entryIDs: removedEntryIDs)
        return count
    }

    // MARK: - Importing

    /// Adds a folder of Raycast script commands, skipping any name already in the library.
    func importScriptDirectory() async {
        guard let directory = chooseScriptDirectory() else { return }
        let drafts = await Task.detached(priority: .userInitiated) {
            RaycastScriptImport.scan(directory: directory)
        }.value
        guard !drafts.isEmpty else {
            await core.showNotice(
                title: "Nothing to Import",
                message: "No Raycast script commands were found in this folder.",
                symbol: CustomCommand.sfSymbol, tone: .neutral)
            return
        }
        guard await confirmScriptImport(count: drafts.count) else { return }
        let added = store.add(contentsOf: drafts)
        // Everything offered was already here, so say so rather than "0 imported".
        guard added > 0 else {
            await core.showNotice(
                title: "Nothing to Import",
                message: "Every script in this folder is already in your library.",
                symbol: CustomCommand.sfSymbol, tone: .neutral)
            return
        }
        await core.showNotice(
            title: "Scripts Imported",
            message: importSummary(added: added, offered: drafts.count),
            symbol: CustomCommand.sfSymbol, tone: .success)
    }

    /// An accessory app must activate first, or the panel opens behind the frontmost app.
    private func chooseScriptDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a folder of Raycast script commands."
        NSApp.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Scripts run arbitrary code, so this warns the way a backup of custom commands does.
    private func confirmScriptImport(count: Int) async -> Bool {
        await core.confirm(
            title: count == 1 ? "Import 1 script?" : "Import \(count) scripts?",
            message:
                "Imported commands run these files with your user account. Only import scripts you "
                + "trust.",
            symbol: CustomCommand.sfSymbol, confirmTitle: "Import", confirmRole: .standard)
    }

    private func importSummary(added: Int, offered: Int) -> String {
        let imported = added == 1 ? "Imported 1 command." : "Imported \(added) commands."
        guard offered > added else { return imported }
        return imported + " Skipped \(offered - added) already in your library."
    }

    // MARK: - Running

    /// The one funnel, so no entry point skips a required value or the confirmation.
    func runCustomCommand(id: UUID, values: [String: String] = [:]) {
        // Also the feature switch: with it off a registered hotkey must run nothing.
        guard settings.customCommandsEnabled else { return }
        guard let command = store.command(id: id), command.isEnabled else { return }
        guard let arguments = command.positionalValues(from: values) else {
            paletteCoordinator.showArguments(of: AppEntry(command), values: values)
            return
        }
        perform(command, arguments: arguments) { [unowned self] in
            self.runCustomCommand(id: id, values: values)
        }
    }

    /// A deep link's `arguments`, translated to the inline fields `runCustomCommand` reads.
    func runCustomCommand(id: UUID, linkArguments: [String: String]) {
        let values = store.command(id: id)?.fieldValues(fromLink: linkArguments) ?? [:]
        runCustomCommand(id: id, values: values)
    }

    /// The launcher fallback: a one-off shell line, always in a terminal window.
    func runShellCommand(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        // Shell config sourced, so `ll` is the user's alias; no working directory means home.
        let command = CustomCommand(
            name: CommandID.runShellCommand.name, command: text, loadsShellEnvironment: true,
            opensTerminal: true)
        let rerun = { [unowned self] in self.runShellCommand(text) }
        Task { await execute(command, arguments: [], rerun: rerun) }
    }

    /// A Dock click belongs to the newest terminal window still open, not to a fresh launcher.
    func focusTerminalWindow() -> Bool {
        terminals.last?.focus() ?? false
    }

    /// `rerun` is the window's Run Again, back through the funnel that started this run.
    private func perform(
        _ command: CustomCommand, arguments: [String], rerun: @escaping () -> Void
    ) {
        guard settings.customCommandsEnabled else { return }
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        Task {
            if command.requiresConfirmation {
                guard
                    // Neutral, not destructive: their own command just wants a second tap.
                    await core.confirm(
                        title: command.name,
                        message: "Are you sure you want to run this command?\n\n\(command.command)",
                        symbol: command.symbol, confirmTitle: "Run",
                        tone: .neutral, confirmRole: .standard)
                else { return }
            }
            await execute(command, arguments: arguments, rerun: rerun)
        }
    }

    /// Where a run goes: a terminal window of its own, or quietly in the background.
    private func execute(
        _ command: CustomCommand, arguments: [String], rerun: @escaping () -> Void
    ) async {
        guard !command.opensTerminal else {
            openTerminal(command, arguments: arguments, rerun: rerun)
            return
        }
        let result = await ShellCommandRunner.run(
            command.command, arguments: arguments,
            loadingShellEnvironment: command.loadsShellEnvironment,
            workingDirectory: command.workingDirectory)
        await report(command, result: result)
    }

    /// Every run gets a new window, cascaded off the newest one still open.
    private func openTerminal(
        _ command: CustomCommand, arguments: [String], rerun: @escaping () -> Void
    ) {
        let presenter = CommandTerminalPresenter(
            command: command, arguments: arguments, cascadingFrom: terminals.last?.frame,
            activation: activationPolicy,
            describe: { [unowned self] result in
                CommandOutcome(
                    summary: summary(of: result),
                    hint: shellEnvironmentHint(command: command, result: result),
                    succeeded: result.succeeded, finishedAt: Date())
            },
            rerun: rerun,
            openSettings: { [unowned self] in settingsCoordinator.showSettings(tab: .commands) },
            onClose: { [weak self] closed in self?.terminals.removeAll { $0 === closed } })
        terminals.append(presenter)
        presenter.show()
    }

    private func removeCustomCommandReferences(ids: Set<UUID>, entryIDs: Set<String>) {
        for id in ids {
            let action = HotKeyAction.customCommand(id: id)
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

    // MARK: - Reporting

    /// Background runs only: a terminal window already shows how its run ended.
    private func report(_ command: CustomCommand, result: ShellCommandResult) async {
        guard !result.succeeded else {
            // What the command said beats a bare "it ran"; on finish, so a slow one reports late.
            if command.showsConfirmation {
                core.showMessage(result.lastOutputLine ?? "Ran \(command.name)")
            }
            return
        }
        let hint = shellEnvironmentHint(command: command, result: result)
        guard
            await core.reportFailure(
                title: "“\(command.name)” Failed",
                message: failureMessage(command: command, result: result),
                symbol: command.symbol, recovery: hint == nil ? nil : "Open Settings…")
        else { return }
        settingsCoordinator.showSettings(tab: .commands)
    }

    private func summary(of result: ShellCommandResult) -> String {
        switch result.termination {
        case .launchFailed: return "The shell could not be started."
        case .stopped: return "Stopped"
        case .exited(let status):
            return status == 0 ? "Finished successfully." : "The command exited with status \(status)."
        }
    }

    private func failureMessage(command: CustomCommand, result: ShellCommandResult) -> String {
        var parts = [summary(of: result)]
        if case .launchFailed(let detail) = result.termination { parts.append(detail) }
        if let standardError = result.standardError { parts.append(standardError) }
        if let hint = shellEnvironmentHint(command: command, result: result) { parts.append(hint) }
        return parts.joined(separator: "\n\n")
    }

    /// `127` is also a plain typo, so this is gated on the status rather than on stderr.
    private func shellEnvironmentHint(
        command: CustomCommand, result: ShellCommandResult
    ) -> String? {
        guard case .exited(status: 127) = result.termination, !command.loadsShellEnvironment else {
            return nil
        }
        return "If this is a shell alias or function, turn on Load Shell Environment for this command."
    }
}
