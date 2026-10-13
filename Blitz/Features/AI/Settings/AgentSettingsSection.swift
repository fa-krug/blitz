import SwiftUI

/// Settings → AI → Agent: Allow, Ask or Deny per tool, with each MCP server read from its trust.
struct AgentSettingsSection: View {
    @Environment(AISettingsStore.self) private var settings
    @Environment(AppSettings.self) private var appSettings
    @Environment(MCPCoordinator.self) private var mcpCoordinator
    @Environment(MCPSettingsStore.self) private var mcpStore

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach(AgentTool.builtIn, id: \.self) { tool in
                AgentDecisionPicker(
                    title: tool.title, subtitle: subtitle(for: tool),
                    choices: AgentDecisionPicker.choices(canAsk: tool.canAsk),
                    selection: decision(for: tool)
                )
                .settingsEnabled(isAvailable(tool))
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
                SettingsRowTitle(.aiAgent, "Tool call rounds")
                Text(
                    "A reply stops after this many; Unlimited runs until Stop. "
                        + "API connections, Codex and Claude.")
            }
        } header: {
            SettingsSectionHeader(.aiAgent)
        } footer: {
            Text(
                "Ask confirms each call, and Deny never offers the tool. What a tool reads goes "
                    + "to the model's provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The feature switch is where macOS was asked for access, so the table cannot reach past it.
    private func isAvailable(_ tool: AgentTool) -> Bool {
        switch tool {
        case .calendarRead, .calendarWrite: appSettings.calendarEnabled
        case .remindersRead, .remindersWrite: appSettings.remindersEnabled
        case .shell, .webSearch, .mcp: true
        }
    }

    private func subtitle(for tool: AgentTool) -> String? {
        switch tool {
        case .shell:
            return "Runs in your login shell, as you."
        case .calendarRead, .calendarWrite:
            guard appSettings.calendarEnabled else { return "Turn on Calendar first." }
            return tool == .calendarRead ? "The calendars switched on in Calendar." : nil
        case .remindersRead, .remindersWrite:
            guard appSettings.remindersEnabled else { return "Turn on Reminders first." }
            return tool == .remindersRead ? "The lists switched on in Reminders." : nil
        case .webSearch:
            return "The provider runs the search, so Blitz cannot stop it to ask."
        case .mcp:
            return nil
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
