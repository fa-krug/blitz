import SwiftUI

/// Seated in the File Search pane, with its own switch: it searches captures, not the scopes.
struct ScreenshotSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.screenshotSearchEnabled) {
                SettingsRowTitle(.fileSearchScreenshots, "Enable Screenshot Search")
                Text("Finds captures through Spotlight, newest first.")
            }
            Group {
                if let entry = CommandCatalog.entry(for: .searchScreenshots) {
                    FeatureCommandRow(entry: entry, anchor: .fileSearchScreenshots)
                }
                Toggle(isOn: $settings.screenshotTextSearchEnabled) {
                    SettingsRowTitle(.fileSearchScreenshots, "Search text in screenshots")
                    Text("Recognized on this Mac while idle.")
                }
            }
            .settingsEnabled(settings.screenshotSearchEnabled)
        } header: {
            SettingsSectionHeader(.fileSearchScreenshots)
        }
    }
}
