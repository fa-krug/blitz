import SwiftUI

/// Both flavours in one pane: the built-ins, then the user's own shell commands.
struct CommandsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(AppIndex.self) private var appIndex
    @Environment(CustomCommandStore.self) private var store
    @Environment(SettingsNavigationState.self) private var navigation
    @State private var editor: EditorTarget?
    @State private var pendingDeletion: CustomCommand?

    var body: some View {
        let builtIn = LauncherItemPage.entry(
            named: navigation.page, in: appIndex, where: LauncherItemsSection.lists(.command))
        let custom = store.commands.first { $0.entryID == navigation.page }
        SettingsPagedPane(showsPage: builtIn != nil || custom != nil) {
            if let custom {
                CustomCommandPage(
                    command: custom,
                    onEdit: { editor = EditorTarget(command: custom) },
                    onDelete: { pendingDeletion = custom })
            } else if let builtIn {
                LauncherItemPage(entry: builtIn)
            }
        } library: {
            library
        }
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

    private var library: some View {
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

            CustomCommandsSection(editor: $editor)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.commands)
        .releasesFocusOnOutsideClick()
    }
}

/// Its own view, so a keystroke in the filter re-renders this section rather than the whole pane.
private struct CustomCommandsSection: View {
    @Environment(CustomCommandStore.self) private var store
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Binding var editor: EditorTarget?
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
            } else {
                SettingsPageRows(
                    items: results, rowHeight: Self.rowHeight, page: \.entryID,
                    accessibilityName: \.name
                ) { command in
                    CustomCommandRow(command: command)
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
        // A lazy row may not be built yet, so a jump to one narrows the list onto it instead.
        .settingsFilterSeed(.commandsCustomCommands, query: $query) { title in
            store.commands.contains { $0.name == title }
        }
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

/// Read-only, so it holds no AppKit control: every edit happens on the command's own page.
private struct CustomCommandRow: View {
    let command: CustomCommand

    var body: some View {
        SettingsRow(
            title: command.name, subtitle: command.command,
            labelOpacity: command.isEnabled ? 1 : 0.45, anchor: .commandsCustomCommands
        ) {
            CustomCommandIcon(command: command)
        } trailing: {
            SettingsEntryBadges(
                aliasKey: command.entryID, action: .customCommand(id: command.id))
        }
    }
}

/// One custom command's own page: what it runs, then the controls that act on it at once.
private struct CustomCommandPage: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    let command: CustomCommand
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            // The window's Back chevron leaves the page, as on an extension's.
            Section {
                SettingsRow(title: command.name, subtitle: command.command) {
                    CustomCommandIcon(command: command)
                } trailing: {
                    Button("Edit…", action: onEdit)
                    Button("Delete…", role: .destructive, action: onDelete)
                }
            }

            Section {
                Toggle(isOn: isEnabled) {
                    Text("Enabled")
                    Text("Off offers it nowhere and leaves its shortcut doing nothing.")
                }
                LabeledContent {
                    // It reaches the ranker only through the launcher slice, so it dims with it.
                    AliasField(key: command.entryID, name: command.name)
                        .settingsEnabled(command.isEnabled && settings.customCommandsShowInLauncher)
                } label: {
                    Text("Alias")
                    Text("Type it in the launcher to put this command first.")
                }
                LabeledContent {
                    // A disabled command's shortcut fires into the funnel's refusal, so it dims.
                    ShortcutRecorder(action: .customCommand(id: command.id))
                        .settingsEnabled(command.isEnabled)
                } label: {
                    Text("Shortcut")
                    Text("Runs it from anywhere.")
                }
            }
            .settingsEnabled(settings.customCommandsEnabled)
        }
        .formStyle(.grouped)
        .releasesFocusOnOutsideClick()
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { command.isEnabled },
            set: { core.customCommandCoordinator.setCustomCommandEnabled($0, id: command.id) })
    }
}

private struct CustomCommandIcon: View {
    let command: CustomCommand

    var body: some View {
        Image(systemName: command.symbol)
            .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
    }
}
