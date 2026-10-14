import SwiftUI

/// Settings › AI › Agent: Allow, Ask or Deny per tool, with each MCP server read from its trust.
struct AgentSettingsSection: View {
    /// How many tool groups are built; the pane raises it a frame at a time.
    let groupCount: Int

    @Environment(AISettingsStore.self) private var settings
    @Environment(AppSettings.self) private var appSettings
    @Environment(MCPCoordinator.self) private var mcpCoordinator
    @Environment(MCPSettingsStore.self) private var mcpStore
    @Environment(VisibilityStore.self) private var visibility

    /// Polled like the Permissions pane: the grant lands in System Settings, which sends nothing.
    @State private var isTrusted = Permissions.isAccessibilityTrusted()

    var body: some View {
        @Bindable var settings = settings
        let ceiling = AgentFeatureCeiling(
            settings: appSettings, visibility: visibility, isAccessibilityTrusted: { isTrusted })
        Section {
            ForEach(shownGroups, id: \.self) { group in
                AgentToolGroupHeader(title: group.title)
                ForEach(group.tools, id: \.self) { tool in
                    AgentDecisionPicker(
                        title: tool.title,
                        subtitle: ceiling.unavailableReason(for: tool) ?? subtitle(for: tool),
                        choices: AgentDecisionPicker.choices(canAsk: tool.canAsk),
                        selection: decision(for: tool)
                    )
                    .settingsEnabled(ceiling.isAvailable(tool))
                }
            }
            if groupCount >= AgentTool.Group.allCases.count {
                if !mcpStore.servers.isEmpty {
                    AgentToolGroupHeader(title: "MCP Servers")
                }
                ForEach(mcpStore.servers) { server in
                    AgentDecisionPicker(
                        title: server.title, subtitle: subtitle(for: server),
                        choices: AgentDecisionPicker.choices(canAsk: true),
                        selection: trust(of: server)
                    )
                    .settingsEnabled(appSettings.mcpEnabled && server.isEnabled)
                }
                Picker(selection: $settings.toolRounds) {
                    ForEach(AIToolRounds.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsRowTitle(.agentAgent, "Tool call rounds")
                    Text(
                        "A reply stops after this many; Unlimited runs until Stop. "
                            + "API connections, Codex and Claude.")
                }
                Toggle(isOn: $settings.notifiesWhenWaiting) {
                    SettingsRowTitle(.agentAgent, "Notify when the agent is waiting")
                    Text("When a chat you left needs an approval or an answer.")
                }
            }
        } header: {
            SettingsSectionHeader(.agentAgent)
        } footer: {
            Text(
                "Ask confirms each call, and Deny never offers the tool. What a tool reads goes "
                    + "to the model's provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                isTrusted = Permissions.isAccessibilityTrusted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var shownGroups: [AgentTool.Group] {
        Array(AgentTool.Group.allCases.prefix(groupCount))
    }

    /// Shown only while the row's feature is on; a row held below its ceiling says why instead.
    private func subtitle(for tool: AgentTool) -> String? {
        switch tool {
        case .shell: "Runs in your login shell, as you."
        case .filesRead, .filesWrite: "Within the path rules under Rules."
        case .webSearch: "The provider runs the search, so Blitz cannot stop it to ask."
        case .calendarRead: "The calendars switched on in Calendar."
        case .remindersRead: "The lists switched on in Reminders."
        case .selectedText: "In the app in front, through Accessibility."
        case .memoryRead: "Sent with every turn, on every model."
        case .memoryWrite: "Remembering and forgetting, listed under Memory."
        default: nil
        }
    }

    private func subtitle(for server: MCPServer) -> String {
        guard appSettings.mcpEnabled else { return "Turn on MCP servers first." }
        guard server.isEnabled else { return "Turn on this server first." }
        return "MCP server @\(server.slug)"
    }

    private func decision(for tool: AgentTool) -> Binding<AgentDecision> {
        Binding(
            get: { settings.agentRules.decision(for: tool) ?? .deny },
            set: { settings.agentRules.set($0, for: tool) })
    }

    /// Written to the server itself, never copied into the table, so the two cannot disagree.
    private func trust(of server: MCPServer) -> Binding<AgentDecision> {
        Binding(
            get: { server.trust.decision },
            set: { mcpCoordinator.setTrust(MCPTrust($0), for: server.id) })
    }
}

/// A small label over a group's rows, quieter than the section's own header.
private struct AgentToolGroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.Typography.sectionHeader)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct AgentDecisionPicker: View {
    let title: String
    let subtitle: String?
    let choices: [AgentDecision]
    @Binding var selection: AgentDecision

    /// Widest first, the order a reader weighs them in.
    static func choices(canAsk: Bool) -> [AgentDecision] {
        canAsk ? [.allow, .ask, .deny] : [.allow, .deny]
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(choices) { Text($0.title).tag($0) }
        } label: {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
    }
}
