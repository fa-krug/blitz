import SwiftUI

/// Both flavours in one pane: the built-ins, then the user's own shell commands.
struct CommandsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @State private var editor: EditorTarget?
    @State private var pendingDeletion: CustomCommand?

    var body: some View {
        @Bindable var settings = settings
        return Form {
            LauncherCategorySwitchSection(kind: .command, anchor: .commandsCommands)

            LauncherItemsSection(
                kind: .command,
                anchor: .commandsCommands,
                searchPrompt: "Search commands…")

            FeatureSwitchSection(
                anchor: .commandsCustomCommands,
                enableTitle: "Enable custom commands",
                enableSubtitle: "Run as you in /bin/zsh. Use full executable paths.",
                isEnabled: $settings.customCommandsEnabled,
                showsInLauncher: $settings.customCommandsShowInLauncher)

            CustomCommandsSection(editor: $editor, pendingDeletion: $pendingDeletion)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.commands)
        .releasesFocusOnOutsideClick()
        .settingsEditorPanel(item: $editor) { target in
            CustomCommandEditorPanel(command: target.command)
        }
        .alert(item: $pendingDeletion) { command in
            Alert(
                title: Text("Delete “\(command.name)”?"),
                message: Text("Its global shortcut and launcher references will also be removed."),
                primaryButton: .destructive(Text("Delete")) {
                    core.customCommandCoordinator.deleteCustomCommand(id: command.id)
                },
                secondaryButton: .cancel())
        }
    }
}

/// Its own view, so a keystroke in the filter re-renders this section rather than the whole pane.
private struct CustomCommandsSection: View {
    @Environment(CustomCommandStore.self) private var store
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(AliasStore.self) private var aliases
    @Environment(HotKeyManager.self) private var hotKeys
    @Binding var editor: EditorTarget?
    @Binding var pendingDeletion: CustomCommand?
    @State private var query = ""

    /// A title over a `.caption` command line, as a native grouped `Form` row lays it out.
    private static let rowHeight: CGFloat = 52

    var body: some View {
        // Once per render: each access would filter and sort the whole list again.
        let results = matches
        Section {
            if !store.commands.isEmpty {
                SettingsFilterField(prompt: "Search custom commands…", query: $query)
            }
            if results.isEmpty {
                Text(
                    store.commands.isEmpty
                        ? "No custom commands yet."
                        : "No custom command matches “\(query)”."
                )
                .foregroundStyle(.secondary)
            } else if !SettingsRowsTablePolicy.hosts(rowCount: store.commands.count) {
                ForEach(results) { command in row(for: command, anchor: .commandsCustomCommands) }
            } else {
                // One row holding the table: a `Form` realizes every row it is handed.
                SettingsRowsTable(
                    items: results, rowHeight: Self.rowHeight,
                    isEnabled: settings.customCommandsEnabled
                ) { command in
                    row(for: command, anchor: nil)
                        .environment(settings)
                        .environment(aliases)
                        .environment(hotKeys)
                }
            }
            Button {
                editor = EditorTarget(command: nil)
            } label: {
                SettingsRowTitle(.commandsCustomCommands, "Add Custom Command")
            }
            Button {
                Task { await core.customCommandCoordinator.importScriptDirectory() }
            } label: {
                SettingsRowTitle(.commandsCustomCommands, "Import Raycast Scripts")
            }
        } footer: {
            Text("Import reads a folder of Raycast script commands.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .settingsEnabled(settings.customCommandsEnabled)
        // A table row has no id to scroll to, so a jump to one narrows the list onto it instead.
        .settingsFilterSeed(.commandsCustomCommands, query: $query) { title in
            store.commands.contains { $0.name == title }
        }
    }

    private func row(
        for command: CustomCommand, anchor: SettingsAnchor?
    ) -> CustomCommandSettingsRow {
        CustomCommandSettingsRow(
            command: command, anchor: anchor,
            isEnabled: Binding(
                get: { command.isEnabled },
                set: { core.customCommandCoordinator.setCustomCommandEnabled($0, id: command.id) }),
            onEdit: { editor = EditorTarget(command: command) },
            onDelete: { pendingDeletion = command })
    }

    private var matches: [CustomCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let listed =
            trimmed.isEmpty
            ? store.commands
            : store.commands.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.command.localizedCaseInsensitiveContains(trimmed)
            }
        return listed.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

private struct EditorTarget: Identifiable {
    let id = UUID()
    let command: CustomCommand?
}

private struct CustomCommandSettingsRow: View {
    @Environment(AppSettings.self) private var settings
    let command: CustomCommand
    /// Only a native `Form` row can carry the reveal pulse.
    let anchor: SettingsAnchor?
    @Binding var isEnabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SettingsRow(title: command.name, subtitle: command.command, anchor: anchor) {
            Image(systemName: command.symbol)
        } trailing: {
            // An alias only reaches the ranker through the launcher slice, so it dims with it.
            AliasField(key: command.entryID, name: command.name)
                .settingsEnabled(command.isEnabled && settings.customCommandsShowInLauncher)

            // A disabled command's shortcut fires into the funnel's refusal, so it dims too.
            ShortcutRecorder(action: .customCommand(id: command.id))
                .settingsEnabled(command.isEnabled)

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit Command")
            .accessibilityLabel("Edit \(command.name)")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete Command")
            .accessibilityLabel("Delete \(command.name)")

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Enabled")
                .accessibilityLabel("Enable \(command.name)")
        }
    }
}
