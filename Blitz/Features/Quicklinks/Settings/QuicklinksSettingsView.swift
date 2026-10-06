import AppKit
import SwiftUI

/// The quicklink library plus the behaviour that applies to all of them.
struct QuicklinksSettingsView: View {
    @Environment(QuicklinkStore.self) private var store
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @State private var editor: QuicklinkEditRequest?
    @State private var pendingDeletion: Quicklink?

    var body: some View {
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
                QuicklinkLibrarySection(editor: $editor, pendingDeletion: $pendingDeletion)
                behaviour
                QuicklinkTransferSection()
            }
            .settingsEnabled(settings.quicklinksEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.quicklinks)
        .settingsEditorPanel(item: $editor) { request in
            QuicklinkEditorPanel(quicklink: request.quicklink, browserTab: request.browserTab)
        }
        .onChange(of: core.pendingQuicklinkEdit?.id, initial: true) { _, _ in
            guard let request = core.pendingQuicklinkEdit else { return }
            editor = request
            core.pendingQuicklinkEdit = nil
        }
        .alert(item: $pendingDeletion) { quicklink in
            Alert(
                title: Text("Delete “\(quicklink.name)”?"),
                message: Text("Its global shortcut and launcher references will also be removed."),
                primaryButton: .destructive(Text("Delete")) {
                    Task {
                        await core.quicklinkCoordinator.deleteQuicklink(id: quicklink.id, confirming: false)
                    }
                },
                secondaryButton: .cancel())
        }
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
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(AliasStore.self) private var aliases
    @Environment(HotKeyManager.self) private var hotKeys
    @Environment(SettingsNavigationState.self) private var navigation
    @Binding var editor: QuicklinkEditRequest?
    @Binding var pendingDeletion: Quicklink?
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
                // One row holding the table: a `Form` realizes every row it is handed.
                SettingsRowsTable(
                    items: results, rowHeight: Self.rowHeight,
                    isEnabled: settings.quicklinksEnabled
                ) { quicklink in
                    QuicklinkSettingsRow(
                        quicklink: quicklink,
                        isEnabled: Binding(
                            get: { quicklink.isEnabled },
                            set: {
                                core.quicklinkCoordinator.setQuicklinkEnabled($0, id: quicklink.id)
                            }),
                        onEdit: { editor = QuicklinkEditRequest(quicklink: quicklink) },
                        onDelete: { pendingDeletion = quicklink }
                    )
                    .environment(store)
                    .environment(aliases)
                    .environment(hotKeys)
                    .environment(navigation)
                }
            }
            Button {
                editor = QuicklinkEditRequest(quicklink: nil)
            } label: {
                SettingsRowTitle(.quicklinksQuicklinks, "Add Quicklink")
            }
        }
        // A table row has no id to scroll to, so a jump to one narrows the list onto it instead.
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

private struct QuicklinkSettingsRow: View {
    @Environment(QuicklinkStore.self) private var store
    let quicklink: Quicklink
    @Binding var isEnabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SettingsRow(title: quicklink.name, subtitle: quicklink.link, anchor: .quicklinksQuicklinks) {
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
        } trailing: {
            if quicklink.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .help("Pinned to the top")
            }
            if !quicklink.showsInRootSearch {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .help("Hidden from root search")
            }

            // An alias only reaches the ranker through the root-search slice, so it dims with it.
            AliasField(key: quicklink.entryID, name: quicklink.name)
                .settingsEnabled(quicklink.isEnabled && quicklink.showsInRootSearch)

            // A disabled quicklink's shortcut fires into the funnel's refusal, so it dims too.
            ShortcutRecorder(action: .quicklink(id: quicklink.id))
                .settingsEnabled(quicklink.isEnabled)

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit Quicklink")
            .accessibilityLabel("Edit \(quicklink.name)")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete Quicklink")
            .accessibilityLabel("Delete \(quicklink.name)")

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Enabled")
                .accessibilityLabel("Enable \(quicklink.name)")
        }
    }
}
