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

/// A launcher-item pane: its list, or the page of the entry the pane's current page names.
struct LauncherItemsPane<Library: View>: View {
    /// Which entries this pane lists, so a page string can only open one of its own.
    let lists: (AppEntry) -> Bool
    @ViewBuilder let library: () -> Library

    @Environment(SettingsNavigationState.self) private var navigation
    @Environment(AppIndex.self) private var appIndex

    var body: some View {
        let shown = LauncherItemPage.entry(named: navigation.page, in: appIndex, where: lists)
        SettingsPagedPane(showsPage: shown != nil) {
            if let shown { LauncherItemPage(entry: shown) }
        } library: {
            library()
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
        appIndex.entries(matching: query, where: Self.lists(kind))
    }

    /// The entries a category's pane lists, and so the only ones its pages may open.
    static func lists(_ kind: AppEntry.Kind) -> (AppEntry) -> Bool {
        { $0.kind == kind && $0.settingsOwner == nil }
    }

    var body: some View {
        Section {
            SettingsFilterField(prompt: searchPrompt, query: $query)
            LauncherItemsList(entries: entries, query: query, anchor: anchor)
        } header: {
            SettingsSectionHeader(anchor)
        }
        .settingsEnabled(visibility.isKindEnabled(kind))
        .settingsFilterSeed(anchor, query: $query) { title in
            appIndex.apps.contains { Self.lists(kind)($0) && $0.name == title }
        }
    }
}

/// The rows under a filter field, or what to say when there are none; shared by item panes.
struct LauncherItemsList: View {
    let entries: [AppEntry]
    let query: String
    let anchor: SettingsAnchor

    /// One line beside a row icon, as a native grouped `Form` row lays it out.
    private static let rowHeight: CGFloat = 45

    var body: some View {
        if entries.isEmpty {
            Text(query.isEmpty ? "Nothing here yet." : "No matches for “\(query)”.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            SettingsPageRows(
                items: entries, rowHeight: Self.rowHeight, page: \.id, accessibilityName: \.name
            ) { entry in
                LauncherItemRow(entry: entry, anchor: anchor)
            }
        }
    }
}

/// One launcher item's row: read-only, with badges for what its page sets.
private struct LauncherItemRow: View {
    let entry: AppEntry
    let anchor: SettingsAnchor
    @Environment(VisibilityStore.self) private var visibility

    var body: some View {
        let isVisible = visibility.isItemVisible(entry)
        SettingsRow(title: entry.name, labelOpacity: isVisible ? 1 : 0.45, anchor: anchor) {
            AppIconView(app: entry)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
        } trailing: {
            if !isVisible { SettingsHiddenBadge(help: "Hidden from the launcher") }
            SettingsEntryBadges(aliasKey: entry.preferenceKey, action: entry.hotKeyAction)
        }
    }
}

/// One launcher item's own page: what it is, then the controls that act on it at once.
struct LauncherItemPage: View {
    let entry: AppEntry
    @Environment(VisibilityStore.self) private var visibility

    /// Nil on the list, and for a page whose entry is gone: Back may still reach one.
    static func entry(
        named page: String?, in appIndex: AppIndex, where lists: (AppEntry) -> Bool
    ) -> AppEntry? {
        guard let page else { return nil }
        return appIndex.apps.first { $0.id == page && lists($0) }
    }

    var body: some View {
        Form {
            // The window's Back chevron leaves the page, as on an extension's.
            Section {
                SettingsRow(title: entry.name) {
                    AppIconView(app: entry)
                        .frame(
                            width: SettingsListMetrics.iconSize,
                            height: SettingsListMetrics.iconSize)
                }
            }

            Section {
                Toggle(isOn: isVisible) {
                    Text("Show in launcher")
                    Text("Its shortcut works either way.")
                }
                LabeledContent {
                    AliasField(entry: entry)
                } label: {
                    Text("Alias")
                    Text("Type it in the launcher to put this item first.")
                }
                if let action = entry.hotKeyAction {
                    LabeledContent {
                        ShortcutRecorder(action: action)
                    } label: {
                        Text("Shortcut")
                        Text("Opens it from anywhere.")
                    }
                }
            }
            .settingsEnabled(visibility.isKindEnabled(entry.kind))
        }
        .formStyle(.grouped)
        .releasesFocusOnOutsideClick()
    }

    private var isVisible: Binding<Bool> {
        Binding(
            get: { visibility.isItemVisible(entry) },
            set: { visibility.setItemVisible($0, for: entry) })
    }
}
