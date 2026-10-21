import SwiftUI

struct FileSearchSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle(isOn: $settings.fileSearchEnabled) {
                    SettingsFeatureToggleLabel(
                        anchor: .fileSearchFileSearch, title: "Enable File Search",
                        subtitle: "Uses the Spotlight index, only when you search.")
                }
            }
            .settingsAnchor(.fileSearchFileSearch)

            FeatureCommandsSection(
                owner: .fileSearch, anchor: .fileSearchCommands, excluding: [.searchScreenshots]
            )
            .settingsEnabled(settings.fileSearchEnabled)
            FileSearchScopesSection()
                .settingsEnabled(settings.fileSearchEnabled)
            FileSearchIgnoreSection()
                .settingsEnabled(settings.fileSearchEnabled)
            ScreenshotSettingsSection()
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.fileSearch)
    }
}

private struct FileSearchScopesSection: View {
    @Environment(AppSettings.self) private var settings
    /// Recomputed only on change: a `fileExists` per row is too much per body render.
    @State private var missing: Set<String> = []

    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var isDefault: Bool { settings.fileSearchScopes == FileSearchScope.defaultScopes }

    var body: some View {
        Section {
            ForEach(settings.fileSearchScopes, id: \.self) { scope in
                SettingsScopeRow(
                    scope: scope,
                    path: FileSearchScope.expand(scope, homeDirectory: home).path,
                    isMissing: missing.contains(scope)
                ) {
                    settings.fileSearchScopes.removeAll { $0 == scope }
                }
            }

            HStack(spacing: Theme.Spacing.lg) {
                Button("Add…", action: addScopes)
                    .help("Add a folder to search.")
                if !isDefault {
                    Button("Restore Defaults") {
                        settings.fileSearchScopes = FileSearchScope.defaultScopes
                    }
                }
            }
        } header: {
            SettingsSectionHeader(.fileSearchSearchScopes)
        } footer: {
            Text("Home covers its visible folders and cloud drives, never Library.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refreshMissing)
        .onChange(of: settings.fileSearchScopes) { _, _ in refreshMissing() }
    }

    private func refreshMissing() {
        let fm = FileManager.default
        missing = Set(
            settings.fileSearchScopes.filter { scope in
                !fm.fileExists(atPath: FileSearchScope.expand(scope, homeDirectory: home).path)
            })
    }

    private func addScopes() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to include when searching for files."
        // Blitz is an accessory app, so the panel opens behind the frontmost app without this.
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        settings.fileSearchScopes = FileSearchScope.normalize(
            settings.fileSearchScopes + panel.urls.map(\.path), homeDirectory: home)
    }
}

private struct FileSearchIgnoreSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var draft = ""

    private var patterns: [String] { settings.fileSearchEffectiveIgnorePatterns }

    var body: some View {
        Section {
            ForEach(patterns, id: \.self) { pattern in
                PatternRow(pattern: pattern) { remove(pattern) }
            }

            TextField("Add pattern…", text: $draft)
                .onSubmit(addPattern)
            if patterns != FileSearchIgnoreList.defaults {
                Button("Restore Defaults", action: restoreDefaults)
            }
        } header: {
            SettingsSectionHeader(.fileSearchIgnorePatterns)
        } footer: {
            Text("No slash matches a name, like *.tmp. A slash matches the path, like **/[Cc]ache/**.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addPattern() {
        let pattern = draft.trimmingCharacters(in: .whitespaces)
        draft = ""
        guard !pattern.isEmpty, !patterns.contains(pattern) else { return }
        if FileSearchIgnoreList.defaults.contains(pattern) {
            settings.fileSearchRemovedDefaultPatterns.removeAll { $0 == pattern }
        } else {
            settings.fileSearchIgnorePatterns.append(pattern)
        }
    }

    private func remove(_ pattern: String) {
        if FileSearchIgnoreList.defaults.contains(pattern) {
            settings.fileSearchRemovedDefaultPatterns.append(pattern)
        } else {
            settings.fileSearchIgnorePatterns.removeAll { $0 == pattern }
        }
    }

    private func restoreDefaults() {
        settings.fileSearchIgnorePatterns = []
        settings.fileSearchRemovedDefaultPatterns = []
    }
}

private struct PatternRow: View {
    let pattern: String
    let onRemove: () -> Void

    var body: some View {
        LabeledContent {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(pattern)")
        } label: {
            Text(pattern)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
