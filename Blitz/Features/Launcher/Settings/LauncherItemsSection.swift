import SwiftUI

/// A category's master switch stays available while its list is disabled.
struct LauncherCategorySwitchSection: View {
    let kind: AppEntry.Kind
    let anchor: SettingsAnchor

    @Environment(VisibilityStore.self) private var visibility

    var body: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { visibility.isKindEnabled(kind) },
                    set: { visibility.setKindEnabled($0, for: kind) }
                )
            ) {
                SettingsFeatureToggleLabel(
                    anchor: anchor, title: "Enable \(anchor.title)",
                    subtitle: "Off hides all of them and stops their shortcuts.")
            }
        }
    }
}

/// One category's Settings list; never filters by visibility, so hidden rows stay listed.
struct LauncherItemsSection: View {
    let kind: AppEntry.Kind
    let anchor: SettingsAnchor
    let searchPrompt: String

    @Environment(AppIndex.self) private var appIndex
    @Environment(VisibilityStore.self) private var visibility
    @State private var query = ""

    private var entries: [AppEntry] {
        appIndex.entries(matching: query) { $0.kind == kind && $0.settingsOwner == nil }
    }

    var body: some View {
        Section {
            SettingsFilterField(prompt: searchPrompt, query: $query)
            LauncherItemsList(
                entries: entries, query: query, isEnabled: visibility.isKindEnabled(kind),
                anchor: anchor)
        } header: {
            SettingsSectionHeader(anchor)
        }
        .settingsEnabled(visibility.isKindEnabled(kind))
        .settingsFilterSeed(anchor, query: $query) { title in
            appIndex.apps.contains { $0.kind == kind && $0.settingsOwner == nil && $0.name == title }
        }
    }
}

/// The rows under a filter field, or what to say when there are none; shared by item panes.
struct LauncherItemsList: View {
    let entries: [AppEntry]
    let query: String
    let isEnabled: Bool
    /// Lets a `Form` row carry the reveal pulse; a hosted table cell has no window session to read.
    var anchor: SettingsAnchor?

    @Environment(VisibilityStore.self) private var visibility
    @Environment(AliasStore.self) private var aliases
    @Environment(HotKeyManager.self) private var hotKeys

    /// One line of text over 24 pt controls, as a native grouped `Form` row lays it out.
    private static let tableRowHeight: CGFloat = 45

    var body: some View {
        if entries.isEmpty {
            Text(query.isEmpty ? "Nothing here yet." : "No matches for “\(query)”.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if entries.first?.kind != .application && entries.first?.kind != .appleShortcut {
            ForEach(entries) { entry in LauncherItemRow(entry: entry, anchor: anchor) }
        } else {
            // One row holding the table: a `Form` realizes every row it is handed.
            SettingsRowsTable(
                items: entries, rowHeight: Self.tableRowHeight, isEnabled: isEnabled
            ) { entry in
                LauncherItemRow(entry: entry)
                    .environment(visibility)
                    .environment(aliases)
                    .environment(hotKeys)
            }
        }
    }
}

/// One launcher item's row; a table cell hosts it and hands it new entries as the list scrolls.
struct LauncherItemRow: View {
    let entry: AppEntry
    var anchor: SettingsAnchor?
    @Environment(VisibilityStore.self) private var visibility

    var body: some View {
        SettingsRow(
            title: entry.name,
            labelOpacity: visibility.isItemVisible(entry) ? 1 : 0.45,
            anchor: anchor
        ) {
            // Keyed so a reused cell seeds the new entry's icon on its first frame.
            AppIconView(app: entry)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
                .id(entry.iconKey)
        } trailing: {
            AliasField(entry: entry)
            if let action = entry.hotKeyAction {
                ShortcutRecorder(action: action)
            }
            Toggle("", isOn: itemBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .launcherVisibilityHelp()
                .accessibilityLabel("Show \(entry.name) in launcher")
        }
    }

    private var itemBinding: Binding<Bool> {
        Binding(
            get: { visibility.isItemVisible(entry) },
            set: { visibility.setItemVisible($0, for: entry) }
        )
    }
}
