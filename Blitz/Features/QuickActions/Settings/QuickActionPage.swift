import SwiftUI

/// One action as Settings lists it: the shipped four and the reader's own share a row and a page.
struct QuickActionSettingsItem: Identifiable {
    let action: QuickAction
    let entry: AppEntry

    /// The launcher entry's id, which is also the pane's page string for this action.
    var id: String { entry.id }

    var shortcut: HotKeyAction {
        switch action {
        case .builtIn(let builtIn): return .command(CommandID(builtIn))
        case .custom(let custom): return .quickAction(id: custom.id)
        }
    }

    static func all(custom: [CustomQuickAction]) -> [Self] {
        let builtIns = BuiltInQuickAction.allCases.compactMap { action in
            CommandCatalog.entry(for: CommandID(action)).map {
                Self(action: .builtIn(action), entry: $0)
            }
        }
        return builtIns + custom.map { Self(action: .custom($0), entry: AppEntry($0)) }
    }
}

/// Read-only, so it holds no AppKit control: every edit happens on the action's own page.
struct QuickActionRow: View {
    let item: QuickActionSettingsItem
    let subtitle: String?

    @Environment(QuickActionSettingsStore.self) private var store
    @Environment(VisibilityStore.self) private var visibility

    var body: some View {
        let isVisible = visibility.isItemVisible(item.entry)
        SettingsRow(
            title: item.action.title, subtitle: subtitle, labelOpacity: isVisible ? 1 : 0.45,
            anchor: .quickActionsActions
        ) {
            QuickActionSettingsIcon(action: item.action)
        } trailing: {
            if store.settings.previewsResult(item.action) {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Shows the result in a panel first")
            }
            if !isVisible { SettingsHiddenBadge(help: "Hidden from the launcher") }
            SettingsEntryBadges(aliasKey: item.entry.preferenceKey, action: item.shortcut)
        }
    }
}

/// One action's own page: what it is, then the controls that act on it at once.
struct QuickActionPage: View {
    let item: QuickActionSettingsItem
    let subtitle: String?
    /// Opens the action's editor: its instructions for a shipped one, the whole record otherwise.
    let onEdit: () -> Void

    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var appSettings
    @Environment(QuickActionSettingsStore.self) private var store
    @Environment(VisibilityStore.self) private var visibility

    var body: some View {
        Form {
            // The window's Back chevron leaves the page, as on an extension's.
            Section {
                SettingsRow(title: item.action.title, subtitle: subtitle) {
                    QuickActionSettingsIcon(action: item.action)
                } trailing: {
                    switch item.action {
                    case .builtIn(let action):
                        // No model handles translation, so there are no instructions to customize.
                        if !action.usesTranslationFramework {
                            Button("Customize…", action: onEdit)
                        }
                    case .custom(let action):
                        Button("Edit…", action: onEdit)
                        Button("Delete…", role: .destructive) { delete(action) }
                    }
                }
            }

            Section {
                Toggle(isOn: isVisible) {
                    Text("Show in launcher")
                    Text("Its shortcut works either way.")
                }
                LabeledContent {
                    AliasField(entry: item.entry)
                } label: {
                    Text("Alias")
                    Text("Type it in the launcher to put this action first.")
                }
                LabeledContent {
                    ShortcutRecorder(action: item.shortcut)
                } label: {
                    Text("Shortcut")
                    Text("Acts on the selected text in any app.")
                }
                Picker(selection: previews) {
                    Text("Replace").tag(false)
                    Text("Preview").tag(true)
                } label: {
                    Text("Result")
                    Text(
                        "Replace writes into your document, and undo restores it. "
                            + "Preview shows a panel first.")
                }
                .disabled(item.action.alwaysPreviews)
            }
            .settingsEnabled(appSettings.quickActionsEnabled)
        }
        .formStyle(.grouped)
        .releasesFocusOnOutsideClick()
    }

    /// The coordinator asks first, and the pane falls back to its list once the record is gone.
    private func delete(_ action: CustomQuickAction) {
        Task { await core.quickActionCoordinator.deleteCustomQuickAction(id: action.id) }
    }

    private var isVisible: Binding<Bool> {
        Binding(
            get: { visibility.isItemVisible(item.entry) },
            set: { visibility.setItemVisible($0, for: item.entry) })
    }

    private var previews: Binding<Bool> {
        switch item.action {
        case .builtIn(let action):
            return Binding(
                get: { store.settings.previewsResult(action) },
                set: { store.settings.setPreviewsResult($0, for: action) })
        case .custom(let action):
            return Binding(
                get: { action.previewsResult },
                set: { core.quickActionCoordinator.setPreviewsResult($0, id: action.id) })
        }
    }
}

private struct QuickActionSettingsIcon: View {
    let action: QuickAction

    var body: some View {
        Group {
            switch action {
            case .builtIn(let builtIn): Image(systemName: builtIn.symbol)
            case .custom(let custom):
                SymbolImage(name: custom.symbol, size: Theme.Size.quickActionHeaderIcon)
            }
        }
        .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
    }
}
