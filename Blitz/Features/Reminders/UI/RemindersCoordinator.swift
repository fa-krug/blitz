import AppKit

/// Owns the reminders feature: the consent gate, the commands, and every write to a reminder.
@MainActor
@Observable
final class RemindersCoordinator {
    private let store: RemindersStore
    private let appIndex: AppIndex
    private let settings: AppSettings
    private let paletteCoordinator: PaletteCoordinator
    /// Dialogs, the HUD and the AI route, so all three stay owned by `AppCore`.
    private unowned let core: AppCore

    /// The Smart Reminder in flight; its progress pill's ✕ cancels it.
    @ObservationIgnored private var smartReminder: Task<Void, Never>?

    init(
        store: RemindersStore,
        appIndex: AppIndex,
        settings: AppSettings,
        paletteCoordinator: PaletteCoordinator,
        core: AppCore
    ) {
        self.store = store
        self.appIndex = appIndex
        self.settings = settings
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    // MARK: - Feature switch

    /// The switch funnels here so enabling, which is also consent, confirms first.
    func setRemindersEnabled(_ enabled: Bool) {
        if !enabled {
            guard settings.remindersEnabled else { return }
            settings.remindersEnabled = false
            return
        }

        // Asking again is the only way back: Settings cannot add an app TCC has no record of.
        store.refreshAccess()
        guard !settings.remindersEnabled || store.access != .granted else { return }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: "Enable reminders?",
                    message:
                        "Blitz lists your open reminders and lets you edit, complete and create "
                        + "them. Your reminders are never sent anywhere.",
                    symbol: "checklist", confirmTitle: "Continue", tone: .neutral,
                    confirmRole: .standard)
            else { return }

            guard await store.requestAccess() else { return }
            // The flag is consent, so it is written only once macOS has actually granted access.
            settings.remindersEnabled = true
            applyEnabled()
        }
    }

    /// Publishes or withdraws everything the feature contributes to the launcher.
    func applyEnabled() {
        applyCommands()
        guard settings.remindersEnabled else {
            cancelSmartReminder()
            store.stop()
            return
        }
        store.start()
    }

    /// Smart Reminder needs a model as well, so it also follows the AI switch.
    func applyCommands() {
        let enabled = settings.remindersEnabled
        appIndex.setCommandsVisible([.myReminders, .createReminder], enabled)
        appIndex.setCommandsVisible([.smartReminder], enabled && settings.aiEnabled)
        if !settings.aiEnabled { cancelSmartReminder() }
    }

    /// Access revoked in System Settings announces nothing, so opening the list re-reads it.
    func remindersWillShow() {
        guard settings.remindersEnabled else { return }
        store.reload()
    }

    // MARK: - Commands

    func showReminders() {
        paletteCoordinator.togglePalette(mode: .reminders)
    }

    func createReminder() {
        paletteCoordinator.hidePalette(restoreFocus: false)
        guard isReady() else { return }
        NSApp.activate(ignoringOtherApps: true)
        Task { await create(startingFrom: ReminderDraft()) }
    }

    /// A blank note opens root search on the row, its one field focused, as a shortcut lands there.
    func createSmartReminder(note: String = "") {
        // Before the field opens, so nobody types a sentence that has nowhere to go.
        guard isReady(), isAIReady() else {
            paletteCoordinator.hidePalette(restoreFocus: false)
            return
        }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else {
            guard let entry = CommandCatalog.entry(for: .smartReminder) else { return }
            paletteCoordinator.showArguments(of: entry, values: [:])
            return
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        Task {
            cancelSmartReminder()
            let run = Task { await interpret(note) }
            smartReminder = run
            await run.value
            if smartReminder == run { smartReminder = nil }
        }
    }

    /// The model is the slow part, so the pill says it is working and its ✕ stops it.
    private func interpret(_ note: String) async {
        core.showProgress("Creating reminder…", onCancel: { [weak self] in
            self?.cancelSmartReminder()
        })
        let result: Result<ReminderDraft, any Error>
        do {
            let provider = try core.smartReminderProvider()
            let draft = try await SmartReminderRunner.draft(
                from: note, now: Date(), calendar: .current, using: provider)
            result = .success(draft)
        } catch {
            result = .failure(error)
        }
        // Cancelling already took the pill down, and nothing more should follow it.
        guard !Task.isCancelled else { return }
        core.hideProgress()
        switch result {
        case .success(let draft):
            // Written straight away; the banner's Open is the way to fix a misread sentence.
            guard let id = store.create(draft) else {
                await reportNoList()
                return
            }
            let due = draft.due?.title(now: Date(), calendar: .current) ?? "No due date"
            core.showBanner(
                title: draft.trimmedTitle, detail: "Reminder created · \(due)",
                symbol: "checklist", actionTitle: "Open",
                action: { [weak self] in self?.open(id) })
        case .failure(let error):
            // What was typed is never lost: it seeds the manual prompt.
            guard
                await core.reportFailure(
                    title: "Couldn't create the reminder", message: error.localizedDescription,
                    symbol: "wand.and.stars", recovery: "Write It Myself")
            else { return }
            await create(startingFrom: ReminderDraft(title: note))
        }
    }

    private func cancelSmartReminder() {
        guard let smartReminder else { return }
        smartReminder.cancel()
        self.smartReminder = nil
        core.hideProgress()
    }

    private func create(startingFrom draft: ReminderDraft) async {
        guard let draft = await core.editReminder(draft, isNew: true) else { return }
        guard store.create(draft) != nil else {
            await reportNoList()
            return
        }
        core.showMessage("Reminder created")
    }

    // MARK: - Row actions

    /// ↵ on a row. The palette stays up behind the dialog, so the list shows the edit landing.
    func edit(_ reminder: ReminderItem) {
        Task {
            guard
                let draft = await core.editReminder(ReminderDraft(editing: reminder), isNew: false),
                draft != ReminderDraft(editing: reminder)
            else { return }
            guard store.update(reminder, with: draft) else {
                await reportGone(reminder)
                return
            }
            core.showMessage("Reminder saved")
        }
    }

    func complete(_ reminder: ReminderItem) {
        guard store.complete(reminder) else {
            Task { await reportGone(reminder) }
            return
        }
        core.showMessage("Completed “\(reminder.title)”")
    }

    /// Always asked: a deleted reminder is gone from every device the list syncs to.
    func delete(_ reminder: ReminderItem) async {
        guard
            await core.confirm(
                title: "Delete “\(reminder.title)”?",
                message: "It is removed from \(reminder.listName) on every device.",
                symbol: "checklist", confirmTitle: "Delete")
        else { return }
        guard store.delete(reminder) else {
            await reportGone(reminder)
            return
        }
        core.showMessage("Reminder deleted")
    }

    func openInReminders(_ reminder: ReminderItem) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        open(reminder.id)
    }

    private func open(_ id: ReminderItem.ID) {
        if !ReminderLauncher.show(id) { report("Reminders isn't available on this Mac") }
    }

    // MARK: - Chat tools

    /// What a chat model may call now: nothing unless this feature and its AI setting allow it.
    func chatTools(now: Date) -> [AITool] {
        let access = core.aiSettings.remindersAccess
        guard settings.remindersEnabled, access.canRead else { return [] }
        return ReminderToolCatalog.tools(canWrite: access.canWrite, now: now, calendar: .current)
    }

    /// Re-checked per call, since Settings can change mid-reply; Read & Write is the consent.
    func runTool(_ call: AIToolCall) async -> AIToolResult {
        let access = core.aiSettings.remindersAccess
        guard settings.remindersEnabled, access.canRead else {
            return .failure(call.id, "Chat access to Reminders is turned off in Blitz's settings.")
        }
        store.refreshAccess()
        guard store.access == .granted else {
            return .failure(call.id, "macOS has not given Blitz access to Reminders.")
        }
        let request: ReminderToolCatalog.Request
        do throws(AIToolArguments.Invalid) {
            request = try ReminderToolCatalog.request(
                name: call.name, arguments: call.arguments, calendar: .current)
        } catch {
            return .failure(call.id, error.message)
        }
        switch request {
        case .list(let query):
            let answer = ReminderToolCatalog.render(
                await store.loadedReminders(), query: query, now: Date(), calendar: .current)
            return AIToolResult(callID: call.id, content: answer, isError: false)
        case .create(let draft) where access.canWrite:
            return createForChat(draft, callID: call.id)
        case .update(let id, let edit) where access.canWrite:
            return updateForChat(id: id, edit: edit, callID: call.id)
        case .complete(let id) where access.canWrite:
            return await completeForChat(id: id, callID: call.id)
        case .create, .update, .complete:
            return .failure(call.id, "Chat may read reminders but not change them.")
        }
    }

    /// Written straight away: the reader asked in the chat, and the transcript shows the call.
    private func createForChat(_ draft: ReminderDraft, callID: String) -> AIToolResult {
        guard let id = store.create(draft) else {
            return .failure(callID, "No Reminders list on this Mac accepts new reminders.")
        }
        return AIToolResult(
            callID: callID, content: ReminderToolCatalog.saved(draft, id: id), isError: false)
    }

    private func updateForChat(
        id: ReminderItem.ID, edit: ReminderToolCatalog.Edit, callID: String
    ) -> AIToolResult {
        guard let reminder = store.openReminder(id: id) else {
            return .failure(callID, "No open reminder has that id. List them again.")
        }
        let draft = edit.applied(to: ReminderDraft(editing: reminder))
        guard store.update(reminder, with: draft) else {
            return .failure(callID, "It may have been changed or deleted somewhere else.")
        }
        return AIToolResult(
            callID: callID, content: ReminderToolCatalog.saved(draft, id: reminder.id),
            isError: false)
    }

    private func completeForChat(id: ReminderItem.ID, callID: String) async -> AIToolResult {
        guard let reminder = store.openReminder(id: id) else {
            return .failure(callID, "No open reminder has that id. List them again.")
        }
        guard
            await core.confirm(
                title: "Complete \u{201C}\(reminder.title)\u{201D}?",
                message: "It is checked off in \(reminder.listName) on every device.",
                symbol: "checklist", confirmTitle: "Complete", tone: .neutral,
                confirmRole: .standard)
        else { return .failure(callID, "The user declined to complete this reminder.") }
        guard store.complete(reminder) else {
            return .failure(callID, "It may have been changed or deleted somewhere else.")
        }
        return AIToolResult(
            callID: callID, content: "Completed \u{201C}\(reminder.title)\u{201D}.",
            isError: false)
    }

    // MARK: - Reports

    /// Both the switch and the grant are needed; a miss says which one is missing.
    private func isReady() -> Bool {
        guard settings.remindersEnabled else {
            report("Turn Reminders on in Settings first")
            return false
        }
        store.refreshAccess()
        switch store.access {
        case .granted:
            return true
        case .notDetermined:
            paletteCoordinator.hidePalette(restoreFocus: false)
            // System Settings lists no app TCC has no record of, so only asking again can grant it.
            setRemindersEnabled(true)
        case .denied:
            paletteCoordinator.hidePalette(restoreFocus: false)
            Task { await reportAccessDenied() }
        }
        return false
    }

    private func isAIReady() -> Bool {
        guard settings.aiEnabled else {
            report("Turn AI on in Settings first")
            return false
        }
        return true
    }

    /// Only System Settings can undo a denial, so unlike a switch left off this offers the way.
    private func reportAccessDenied() async {
        let openSettings = await core.reportFailure(
            title: "Blitz Needs Reminders Access",
            message: "macOS has not given Blitz access to your reminders.",
            symbol: "checklist", recovery: "Open Settings")
        if openSettings { Permissions.openRemindersSettings() }
    }

    private func reportNoList() async {
        _ = await core.reportFailure(
            title: "Couldn't create the reminder",
            message: "No Reminders list on this Mac accepts new reminders.",
            symbol: "checklist", recovery: nil)
    }

    private func reportGone(_ reminder: ReminderItem) async {
        _ = await core.reportFailure(
            title: "Couldn't change “\(reminder.title)”",
            message: "It may have been changed or deleted somewhere else.",
            symbol: "checklist", recovery: nil)
    }

    /// A miss is transient, so it reports through the HUD rather than a dialog needing dismissal.
    private func report(_ message: String) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.showMessage(message, tone: .neutral)
    }
}
