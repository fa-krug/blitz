import SwiftUI

struct FeatureCommandsSection: View {
    let owner: SettingsTab
    let anchor: SettingsAnchor
    /// Drawn elsewhere; excluded here, not listed there, so a new owned command shows up unasked.
    var excluding: Set<CommandID> = []

    var body: some View {
        Section {
            ForEach(CommandCatalog.entries(ownedBy: owner)) { entry in
                if !excluding.contains(where: { $0.rawValue == entry.id }) {
                    FeatureCommandRow(entry: entry, anchor: anchor)
                }
            }
        } header: {
            SettingsSectionHeader(anchor)
        }
    }
}

/// One command's controls — alias, shortcut, launcher visibility — wherever its pane seats them.
struct FeatureCommandRow: View {
    let entry: AppEntry
    /// The section Configure Command reveals this row in: `AppEntry.settingsTarget` names it too.
    let anchor: SettingsAnchor
    @Environment(VisibilityStore.self) private var visibility

    var body: some View {
        SettingsRow(
            title: entry.name,
            labelOpacity: visibility.isItemVisible(entry) ? 1 : 0.45,
            anchor: anchor
        ) {
            AppIconView(app: entry)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
        } trailing: {
            AliasField(entry: entry)
            if let action = entry.hotKeyAction {
                ShortcutRecorder(action: action)
            }
            Toggle("", isOn: visibilityBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .launcherVisibilityHelp()
                .accessibilityLabel("Show \(entry.name) in launcher")
        }
    }

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { visibility.isItemVisible(entry) },
            set: { visibility.setItemVisible($0, for: entry) })
    }
}
