import SwiftUI

struct RemindersSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(RemindersStore.self) private var store

    var body: some View {
        Form {
            Section {
                Toggle(isOn: enabledBinding) {
                    SettingsFeatureToggleLabel(
                        anchor: .remindersReminders, title: "Manage reminders from Blitz",
                        subtitle: "List, edit and create reminders from the palette.")
                }
            }
            .settingsAnchor(.remindersReminders)

            if settings.remindersEnabled, store.access == .notDetermined {
                Section {
                    SettingsRow(
                        title: "Reminders access is needed",
                        subtitle: "Needed to read and change your reminders."
                    ) {
                        Button("Allow Reminders Access…") {
                            core.remindersCoordinator.setRemindersEnabled(true)
                        }
                    }
                }
            } else if store.access == .denied {
                Section {
                    SettingsRow(
                        title: "Reminders access is off",
                        subtitle: "Allow it in Privacy & Security ▸ Reminders."
                    ) {
                        Button("Open System Settings…") { Permissions.openRemindersSettings() }
                    }
                }
            }

            FeatureCommandsSection(owner: .reminders, anchor: .remindersCommands)
                .settingsEnabled(settings.remindersEnabled)

            if !settings.aiEnabled {
                Section {
                    SettingsRow(
                        title: "Smart Reminder needs AI",
                        subtitle: "Turn AI on to create reminders from a sentence."
                    ) {
                        Button("Open AI Settings…") { core.settingsCoordinator.showSettings(tab: .ai) }
                    }
                }
                .settingsEnabled(settings.remindersEnabled)
            }

            ReminderListsSection()
                .settingsEnabled(settings.remindersEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.reminders)
        .releasesFocusOnOutsideClick()
        // Nothing announces a grant made in System Settings, so the pane reads the lists itself.
        .onAppear {
            store.refreshAccess()
            if !store.hasLoaded { store.reload() }
        }
    }

    /// Routed through the coordinator so enabling, which is also consent, confirms first.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.remindersEnabled },
            set: { core.remindersCoordinator.setRemindersEnabled($0) }
        )
    }
}

/// Machine-local by nature, so these live on the store and never travel in a backup.
private struct ReminderListsSection: View {
    @Environment(RemindersStore.self) private var store
    @State private var query = ""

    private var lists: [ReminderList] {
        guard !query.isEmpty else { return store.lists }
        return store.lists.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.accountName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Section {
            SettingsFilterField(prompt: "Search lists…", query: $query)

            if lists.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(lists) { list in
                    ReminderListRow(list: list)
                }
            }
        } header: {
            SettingsSectionHeader(.remindersLists)
        }
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "No matches for “\(query)”." }
        return store.access == .granted ? "No Reminders lists on this Mac." : "Nothing to show yet."
    }
}

private struct ReminderListRow: View {
    let list: ReminderList
    @Environment(RemindersStore.self) private var store

    var body: some View {
        SettingsRow(title: list.title, subtitle: list.accountName) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Include \(list.title) in My Reminders")
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { store.isEnabled(list) },
            set: { store.setEnabled($0, for: list) }
        )
    }
}
