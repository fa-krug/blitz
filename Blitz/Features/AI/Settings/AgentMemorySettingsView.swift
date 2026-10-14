import SwiftUI

/// Settings › AI › Memory: what the agent was asked to remember.
struct AgentMemorySettingsView: View {
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        Form {
            AITurnedOffNotice()
            AgentMemorySection()
                .settingsEnabled(appSettings.aiEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.agentMemory)
    }
}
