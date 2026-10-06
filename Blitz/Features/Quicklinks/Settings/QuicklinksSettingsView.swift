import AppKit
import SwiftUI

/// The quicklink library plus the behaviour that applies to all of them; a row opens its own page.
struct QuicklinksSettingsView: View {
    @Environment(QuicklinkStore.self) private var store
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(SettingsNavigationState.self) private var navigation
    @State private var editor: QuicklinkEditRequest?
    @State private var pendingDeletion: Quicklink?
    /// The row the library scrolls back to once a page closes, so a long list keeps its place.
    @State private var returning: Quicklink.ID?

    var body: some View {
        Group {
            if let shown {
                QuicklinkDetailForm(
                    quicklink: shown,
                    onEdit: { editor = QuicklinkEditRequest(quicklink: shown) },
                    onDelete: { pendingDeletion = shown })
            } else {
                libraryForm
            }
        }
        .settingsScrollTarget(.quicklinks)
        .settingsEditorPanel(item: $editor) { request in
            QuicklinkEditorPanel(quicklink: request.quicklink, browserTab: request.browserTab)
        }
        .onChange(of: core.pendingQuicklinkEdit?.id, initial: true) { _, _ in
            guard let request = core.pendingQuicklinkEdit else { return }
            editor = request
            core.pendingQuicklinkEdit = nil
        }
        .onChange(of: navigation.page) { previous, page in
            if page == nil { returning = previous.flatMap(UUID.init(uuidString:)) }
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

    /// Nil on the library, and for a page whose quicklink is gone: Back may still reach one.
    private var shown: Quicklink? {
        guard navigation.tab == .quicklinks, let page = navigation.page,
            let id = UUID(uuidString: page)
        else { return nil }
        return store.quicklink(id: id)
    }

    private var libraryForm: some View {
        @Bindable var settings = settings
        return ScrollViewReader { proxy in
            Form {
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
            // Keyed: Back can close a page before or after the library mounts again.
            .task(id: returning) {
                guard let returning else { return }
                // The Form has just mounted, so let it lay the row out before scrolling to it.
                await Task.yield()
                proxy.scrollTo(returning, anchor: .center)
                self.returning = nil
            }
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
    @Environment(SettingsNavigationState.self) private var navigation
    @Binding var editor: QuicklinkEditRequest?
    @State private var query = ""

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
                // One row holding a lazy stack: a `Form` realizes every row it is handed.
                LazyVStack(spacing: 0) {
                    ForEach(results) { quicklink in
                        QuicklinkLibraryRow(
                            quicklink: quicklink, showsDivider: quicklink.id != results.first?.id
                        ) {
                            navigation.select(.quicklinks, page: quicklink.id.uuidString)
                        }
                        .id(quicklink.id)
                    }
                }
                // Into the Form row's own padding, so the rows sit where native ones would.
                .padding(.top, -QuicklinkLibraryRow.overhang - 1)
                .padding(.bottom, -QuicklinkLibraryRow.overhang)
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
    @Environment(AliasStore.self) private var aliases
    @Environment(HotKeyManager.self) private var hotKeys
    let quicklink: Quicklink
    let showsDivider: Bool
    let onOpen: () -> Void

    /// A title over a `.caption` link, as a native grouped `Form` row lays it out.
    private static let height: CGFloat = 52
    /// How far a `Form` row pads its content above and below.
    static let overhang: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(showsDivider ? 1 : 0)
            Button(action: onOpen) {
                SettingsRow(
                    title: quicklink.name, subtitle: quicklink.link,
                    labelOpacity: quicklink.isEnabled ? 1 : 0.45, anchor: .quicklinksQuicklinks
                ) {
                    QuicklinkSettingsIcon(quicklink: quicklink)
                } trailing: {
                    badges
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Configure \(quicklink.name)")
        }
        .frame(height: Self.height)
    }

    @ViewBuilder
    private var badges: some View {
        if quicklink.isPinned {
            Image(systemName: "pin.fill")
                .foregroundStyle(.secondary)
                .help("Pinned to the top")
                .accessibilityLabel("Pinned")
        }
        if !quicklink.showsInRootSearch {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
                .help("Hidden from root search")
                .accessibilityLabel("Hidden from root search")
        }
        if let alias = aliases.alias(for: quicklink.entryID) {
            Text(alias)
                .font(Theme.Typography.keyCap)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xxs)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .accessibilityLabel("Alias \(alias)")
        }
        if let keycaps = hotKeys.binding(for: .quicklink(id: quicklink.id))?.keycaps {
            HStack(spacing: Theme.Spacing.xxs) {
                ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                    KeyCapChip(text: cap, style: .outline, scale: .compact)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Shortcut")
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
