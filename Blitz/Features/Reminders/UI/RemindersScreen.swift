import SwiftUI

/// My Reminders: every open reminder, bucketed by when it is due and filtered by the query.
struct RemindersScreen: PaletteScreen {
    let store: RemindersStore
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    /// Grouped first, so `rows` and the drawn list walk the reminders in the same order.
    private var groups: [ReminderGroup] {
        ReminderAgenda.grouping(
            ReminderAgenda.matching(store.reminders, query: vm.query), now: Date(),
            calendar: .current)
    }

    var rows: [ReminderItem] { groups.flatMap(\.reminders) }

    var primaryActionTitle: String { "Edit Reminder" }

    private func reminder(at selection: Int) -> ReminderItem? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let reminder = reminder(at: selection) else { return nil }
        return ReminderActionsMenu.content(reminder: reminder, core: core)
    }

    func activate(at selection: Int) {
        guard let reminder = reminder(at: selection) else { return }
        core.remindersCoordinator.edit(reminder)
    }

    /// ⌘↵ — tick it off, the other thing a to-do is for.
    func secondary(at selection: Int) -> Bool {
        guard let reminder = reminder(at: selection) else { return false }
        core.remindersCoordinator.complete(reminder)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        if shortcut == .newItem {
            core.remindersCoordinator.createReminder()
            return true
        }
        guard let reminder = reminder(at: selection) else { return false }
        switch shortcut {
        case .commandDelete:
            Task { await core.remindersCoordinator.delete(reminder) }
        case .openInApp:
            core.remindersCoordinator.openInReminders(reminder)
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
        let groups = groups
        let rows = groups.flatMap(\.reminders)
        if rows.isEmpty {
            emptyState
        } else {
            RemindersList(
                groups: groups,
                selectedID: rows.indices.contains(selection) ? rows[selection].id : nil,
                now: Date(),
                scroll: scroll,
                onActivate: { core.remindersCoordinator.edit($0) },
                onComplete: { core.remindersCoordinator.complete($0) },
                onActions: { reminder in
                    if let index = rows.firstIndex(of: reminder) { vm.selection = index }
                    openActions()
                }
            )
        }
    }

    /// Names why the list is empty: no access reads very differently from a clear to-do list.
    private var emptyState: EmptyResults {
        switch store.access {
        case .denied:
            return EmptyResults(
                text: "Blitz has no access to your reminders", symbol: "checklist",
                hint: "Allow Blitz under Privacy & Security in System Settings",
                action: .init(title: "Open Privacy Settings") {
                    core.paletteCoordinator.hidePalette(restoreFocus: false)
                    Permissions.openRemindersSettings()
                })
        // Settings lists no app TCC has no record of, so only asking again gets Blitz there.
        case .notDetermined:
            return EmptyResults(
                text: "Blitz hasn't been given access to your reminders", symbol: "checklist",
                hint: "macOS asks once before Blitz can read them",
                action: .init(title: "Allow Access") {
                    core.paletteCoordinator.hidePalette(restoreFocus: false)
                    core.remindersCoordinator.setRemindersEnabled(true)
                })
        case .granted:
            break
        }
        if !store.hasLoaded { return EmptyResults(text: "Loading reminders…", symbol: "checklist") }
        if !vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return EmptyResults(text: "No matching reminders")
        }
        return EmptyResults(
            text: "No open reminders", symbol: "checkmark.circle", hint: "Press ⌘N to create one")
    }
}

/// The ⌘K menu for a reminder row.
@MainActor
enum ReminderActionsMenu {
    static func content(reminder: ReminderItem, core: AppCore) -> PopoverMenuContent {
        let coordinator = core.remindersCoordinator
        var items: [PopoverMenuItem] = [
            PopoverMenuItem(title: "Edit Reminder", systemImage: "pencil", shortcut: "↵") {
                coordinator.edit(reminder)
            },
            PopoverMenuItem(
                title: "Complete Reminder", systemImage: "checkmark.circle", shortcut: "⌘↵"
            ) {
                coordinator.complete(reminder)
            },
            PopoverMenuItem(
                title: "Open in Reminders", systemImage: "checklist", startsSection: true,
                shortcut: "⌘O"
            ) {
                coordinator.openInReminders(reminder)
            },
            PopoverMenuItem(
                title: "New Reminder", systemImage: "plus.circle", startsSection: true,
                shortcut: "⌘N"
            ) {
                coordinator.createReminder()
            }
        ]
        if core.settings.aiEnabled {
            items.append(
                PopoverMenuItem(title: "Smart Reminder", systemImage: "wand.and.stars") {
                    coordinator.createSmartReminder()
                })
        }
        items.append(
            PopoverMenuItem(
                title: "Delete Reminder", systemImage: "trash", startsSection: true,
                shortcut: "⌘⌫", isDestructive: true
            ) {
                Task { await coordinator.delete(reminder) }
            })
        return PopoverMenuContent(header: reminder.title, items: items)
    }
}
