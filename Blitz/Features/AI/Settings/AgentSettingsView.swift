import SwiftUI

/// Settings › AI › Agent: what each tool may do, apart from the rule lists and the memory.
struct AgentSettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(SettingsNavigationState.self) private var navigation

    /// Each group's pickers are AppKit pop-ups, so one more group per frame keeps every frame short.
    @State private var mountedGroups = 3

    var body: some View {
        Form {
            AITurnedOffNotice()
            AgentSettingsSection(groupCount: groupCount)
                .settingsEnabled(appSettings.aiEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.agent)
        // Keyed, so each step starts only once the frame holding the previous one has committed.
        .task(id: mountedGroups) {
            guard mountedGroups < AgentTool.Group.allCases.count else { return }
            await Task.yield()
            mountedGroups += 1
        }
    }

    /// A search result revealing a lower row mounts every group at once, so it has a row to reach.
    private var groupCount: Int {
        navigation.scrollRequest?.target.tab == .agent ? .max : mountedGroups
    }
}

/// Atop each agent pane while AI is off, since every row beneath it is dimmed until then.
struct AITurnedOffNotice: View {
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        if !appSettings.aiEnabled {
            Section {
                Text("Turn on AI first.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
