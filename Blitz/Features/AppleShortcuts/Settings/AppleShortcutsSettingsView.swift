import SwiftUI

/// The shortcuts found in the Shortcuts app, each opening the page any launcher item has.
struct AppleShortcutsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(AppIndex.self) private var appIndex
    @State private var query = ""

    /// The index's copy of the library, since only it carries the search profile a match reads.
    private var entries: [AppEntry] {
        appIndex.entries(matching: query) { $0.kind == .appleShortcut }
    }

    var body: some View {
        @Bindable var settings = settings
        return LauncherItemsPane(lists: { $0.kind == .appleShortcut }) {
            Form {
                Section {
                    Toggle(isOn: $settings.appleShortcutsEnabled) {
                        SettingsFeatureToggleLabel(
                            anchor: .appleShortcutsAppleShortcuts,
                            title: "Enable Apple Shortcuts",
                            subtitle: "Run your shortcuts from the launcher.")
                    }
                }
                .settingsAnchor(.appleShortcutsAppleShortcuts)

                if settings.appleShortcutsEnabled {
                    library
                }
            }
            .formStyle(.grouped)
            .settingsScrollTarget(.appleShortcuts)
            .releasesFocusOnOutsideClick()
        }
        // Shortcuts can change while Settings sits closed, so the pane reads them fresh.
        .task(id: settings.appleShortcutsEnabled) { core.appleShortcutCoordinator.refresh() }
    }

    private var library: some View {
        Section {
            SettingsFilterField(prompt: "Search shortcuts…", query: $query)
            LauncherItemsList(entries: entries, query: query, anchor: .appleShortcutsShortcuts)
            Button("Open Shortcuts") { core.appleShortcutCoordinator.openShortcutsApp() }
        } header: {
            SettingsSectionHeader(.appleShortcutsShortcuts)
        }
        .settingsFilterSeed(.appleShortcutsShortcuts, query: $query) { title in
            core.appleShortcutCoordinator.entries.contains { $0.name == title }
        }
    }
}
