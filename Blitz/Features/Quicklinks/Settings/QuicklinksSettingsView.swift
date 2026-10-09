import AppKit
import SwiftUI

/// The quicklink library plus the behaviour that applies to all of them; a row opens its own page.
struct QuicklinksSettingsView: View {
    @Environment(QuicklinkStore.self) private var store
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(SettingsNavigationState.self) private var navigation
    @State private var editor: QuicklinkEditRequest?

    var body: some View {
        let shown = navigation.page.flatMap(store.quicklink(entryID:))
        SettingsPagedPane(showsPage: shown != nil) {
            if let shown {
                QuicklinkDetailForm(
                    quicklink: shown,
                    onEdit: { editor = QuicklinkEditRequest(quicklink: shown) },
                    onDelete: { delete(shown) })
            }
        } library: {
            libraryForm
        }
        .settingsEditorPanel(item: $editor) { request in
            QuicklinkEditorPanel(
                quicklink: request.quicklink, browserTab: request.browserTab, draftName: request.name)
        }
        .onChange(of: core.pendingQuicklinkEdit?.id, initial: true) { _, _ in
            guard let request = core.pendingQuicklinkEdit else { return }
            editor = request
            core.pendingQuicklinkEdit = nil
        }
    }

    private func delete(_ quicklink: Quicklink) {
        Task {
            guard
                await core.confirm(
                    title: "Delete “\(quicklink.name)”?",
                    message: "Its global shortcut and launcher references will also be removed.",
                    symbol: quicklink.symbol, artwork: store.faviconPaths[quicklink.id],
                    confirmTitle: "Delete")
            else { return }
            await core.quicklinkCoordinator.deleteQuicklink(id: quicklink.id, confirming: false)
        }
    }

    private var libraryForm: some View {
        @Bindable var settings = settings
        return Form {
            FeatureSwitchSection(
                anchor: .quicklinksQuicklinks,
                enableTitle: "Enable quicklinks",
                enableSubtitle: "Open saved links and searches from the launcher.",
                isEnabled: $settings.quicklinksEnabled,
                showsInLauncher: $settings.quicklinksShowInLauncher,
                showsIcon: true,
                showsHeader: false)

            Group {
                if !store.isAvailable { storageNotice }
                FeatureCommandsSection(owner: .quicklinks, anchor: .quicklinksCommands)
                QuicklinkLibrarySection(editor: $editor)
                behaviour
                QuicklinkTransferSection()
            }
            .settingsEnabled(settings.quicklinksEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.quicklinks)
    }

    // MARK: - Sections

    private var storageNotice: some View {
        Section {
            Label(
                "Changes can't be saved: the database couldn't be opened. Its file is untouched.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    private var behaviour: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.quicklinkOpensNewWindow) {
                SettingsRowTitle(.quicklinksBehaviour, "Open in a new window")
                Text("Where the app supports it.")
            }
            Toggle(isOn: $settings.quicklinkPrefersExistingTabs) {
                SettingsRowTitle(.quicklinksBehaviour, "Focus an open tab")
                Text("Switch to a tab already showing the link. Safari and Chromium browsers.")
            }
            Picker(selection: $settings.quicklinkSelectionFallback) {
                ForEach(QuicklinkSelectionFallback.allCases) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                SettingsRowTitle(.quicklinksBehaviour, "When there's no selected text")
                Text("For links that use {selection}.")
            }
            Toggle(isOn: $settings.quicklinkConfirmsBeforeDelete) {
                SettingsRowTitle(.quicklinksBehaviour, "Confirm before deleting")
                Text("From the launcher's Actions menu.")
            }
        } header: {
            SettingsSectionHeader(.quicklinksBehaviour)
        }
    }
}

/// Its own view, so a keystroke in the filter re-renders this section rather than the whole pane.
private struct QuicklinkLibrarySection: View {
    @Environment(QuicklinkStore.self) private var store
    @Binding var editor: QuicklinkEditRequest?
    @State private var query = ""

    /// A title over a `.caption` link, as a native grouped `Form` row lays it out.
    private static let rowHeight: CGFloat = 52

    var body: some View {
        // Once per render: a large library makes each pass over it cost a frame.
        let results = matches
        Section {
            if !store.quicklinks.isEmpty {
                SettingsFilterField(prompt: "Search quicklinks…", query: $query)
            }
            if results.isEmpty {
                Text(
                    store.quicklinks.isEmpty
                        ? "No quicklinks yet."
                        : "No quicklink matches “\(query)”."
                )
                .foregroundStyle(.secondary)
            } else {
                SettingsPageRows(
                    items: results, rowHeight: Self.rowHeight, page: \.entryID,
                    accessibilityName: \.name
                ) { quicklink in
                    QuicklinkLibraryRow(quicklink: quicklink)
                }
            }
            Button {
                editor = QuicklinkEditRequest(quicklink: nil)
            } label: {
                SettingsRowTitle(.quicklinksQuicklinks, "Add Quicklink")
            }
        }
        // A lazy row may not be built yet, so a jump to one narrows the list onto it instead.
        .settingsFilterSeed(.quicklinksQuicklinks, query: $query) { title in
            store.quicklinks.contains { $0.name == title }
        }
    }

    /// The store already publishes display order, so filtering keeps pins at the top.
    private var matches: [Quicklink] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.quicklinks }
        return store.quicklinks.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.link.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

/// Apart from the pane, which would otherwise re-render on every edit just to grey out Export.
private struct QuicklinkTransferSection: View {
    @Environment(QuicklinkStore.self) private var store
    @Environment(AppCore.self) private var core

    var body: some View {
        Section {
            LabeledContent {
                Button("Import…") { Task { await core.quicklinkCoordinator.importQuicklinks() } }
            } label: {
                SettingsRowTitle(.quicklinksImportExport, "Import quicklinks")
                Text("From a JSON file; duplicates are skipped.")
            }
            LabeledContent {
                Button("Export…") { Task { await core.quicklinkCoordinator.exportQuicklinks() } }
                    .disabled(store.quicklinks.isEmpty)
            } label: {
                SettingsRowTitle(.quicklinksImportExport, "Export quicklinks")
                Text("To a JSON file.")
            }
        } header: {
            SettingsSectionHeader(.quicklinksImportExport)
        }
    }
}

/// Read-only, so it holds no AppKit control: every edit happens on the quicklink's own page.
private struct QuicklinkLibraryRow: View {
    let quicklink: Quicklink

    var body: some View {
        SettingsRow(
            title: quicklink.name, subtitle: quicklink.link,
            labelOpacity: quicklink.isEnabled ? 1 : 0.45, anchor: .quicklinksQuicklinks
        ) {
            QuicklinkSettingsIcon(quicklink: quicklink)
        } trailing: {
            if quicklink.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .help("Pinned to the top")
                    .accessibilityLabel("Pinned")
            }
            if !quicklink.showsInRootSearch {
                SettingsHiddenBadge(help: "Hidden from root search")
            }
            SettingsEntryBadges(aliasKey: quicklink.entryID, action: .quicklink(id: quicklink.id))
        }
    }
}

/// One quicklink's own page: what it is, then the controls that act on it at once.
private struct QuicklinkDetailForm: View {
    @Environment(AppCore.self) private var core
    let quicklink: Quicklink
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            // The window's Back chevron leaves the page, as on an extension's.
            Section {
                SettingsRow(title: quicklink.name, subtitle: quicklink.link) {
                    QuicklinkSettingsIcon(quicklink: quicklink)
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
                    // It reaches the ranker only through the root-search slice, so it dims with it.
                    AliasField(key: quicklink.entryID, name: quicklink.name)
                        .settingsEnabled(quicklink.isEnabled && quicklink.showsInRootSearch)
                } label: {
                    Text("Alias")
                    Text("Type it in root search to put this quicklink first.")
                }
                LabeledContent {
                    // A disabled quicklink's shortcut fires into the funnel's refusal, so it dims.
                    ShortcutRecorder(action: .quicklink(id: quicklink.id))
                        .settingsEnabled(quicklink.isEnabled)
                } label: {
                    Text("Shortcut")
                    Text("Opens it from anywhere.")
                }
            }
        }
        .formStyle(.grouped)
        .releasesFocusOnOutsideClick()
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { quicklink.isEnabled },
            set: { core.quicklinkCoordinator.setQuicklinkEnabled($0, id: quicklink.id) })
    }
}

/// The favicon when there is one, else the quicklink's symbol, at the Settings row size.
private struct QuicklinkSettingsIcon: View {
    @Environment(QuicklinkStore.self) private var store
    let quicklink: Quicklink

    var body: some View {
        Group {
            if let path = store.faviconPaths[quicklink.id] {
                Image(nsImage: IconCache.artwork(atPath: path, extent: QuicklinkFavicon.extent))
                    .resizable()
            } else {
                SymbolImage(
                    name: quicklink.symbol,
                    size: Theme.Size.settingsRowIcon - Theme.Spacing.xs
                )
            }
        }
        .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
    }
}
