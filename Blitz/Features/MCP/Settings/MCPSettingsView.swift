import SwiftUI

/// Settings › AI › MCP Servers: the switch, the servers, and what each one is doing right now.
struct MCPSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(MCPCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(MCPSettingsStore.self) private var store
    @State private var editor: MCPServerEditorTarget?

    var body: some View {
        Form {
            section
                // Chat is MCP's only consumer, so with AI off the servers have nothing to serve.
                .settingsEnabled(appSettings.aiEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.mcpServers)
        .settingsEditorPanel(item: $editor) { target in
            MCPServerEditor(target: target, onSave: save, onCancel: { editor = nil })
        }
    }

    private var section: some View {
        @Bindable var appSettings = appSettings
        return Section {
            Toggle(isOn: $appSettings.mcpEnabled) {
                SettingsRowTitle(.mcpServersMCPServers, "Enable MCP servers")
                if !appSettings.aiEnabled { Text("Turn on AI first.") }
            }
            Group {
                if store.servers.isEmpty {
                    Text("No MCP servers yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.servers) { server in
                        MCPServerRow(
                            server: server, status: coordinator.status(of: server.id),
                            onEdit: { editor = MCPServerEditorTarget(server: server, isNew: false) },
                            onRemove: { remove(server) })
                    }
                }
                Button {
                    editor = MCPServerEditorTarget(server: MCPServer(), isNew: true)
                } label: {
                    Label {
                        SettingsRowTitle(.mcpServersMCPServers, "Add MCP Server")
                    } icon: {
                        Image(systemName: "plus")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .settingsEnabled(appSettings.mcpEnabled)
        } header: {
            SettingsSectionHeader(.mcpServersMCPServers)
        } footer: {
            Text("Type @slug to address one server. A chat asks before its first tool call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A returned message is shown in the panel; nil closes it.
    private func save(_ server: MCPServer, _ secrets: MCPSecretStore.Secrets) -> String? {
        do {
            try coordinator.save(server, secrets: secrets)
        } catch {
            return "The credentials could not be saved to your login Keychain."
        }
        editor = nil
        return nil
    }

    private func remove(_ server: MCPServer) {
        Task {
            guard
                await core.confirm(
                    title: "Remove \(server.title)?",
                    message: "Its tools stop being offered, and its stored credentials are deleted.",
                    symbol: "wrench.and.screwdriver", confirmTitle: "Remove")
            else { return }
            do {
                try coordinator.remove(server.id)
            } catch {
                _ = await core.reportFailure(
                    title: "Couldn’t Remove \(server.title)",
                    message: "The server was kept: its credentials could not be removed from your "
                        + "login Keychain.",
                    symbol: "wrench.and.screwdriver", recovery: nil)
            }
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServer
    let status: MCPServerStatus
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        SettingsRow(title: server.title, subtitle: subtitle) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.primary)
        } trailing: {
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.plain)
                .help("Edit \(server.title)")
                .accessibilityLabel("Edit \(server.title)")
            Button(action: onRemove) {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove \(server.title)")
            .accessibilityLabel("Remove \(server.title)")
        }
    }

    /// The slug leads, because it is the half a reader has to type into the composer.
    private var subtitle: String {
        let state = server.isEnabled ? status.label : "Disabled"
        return "@\(server.slug) · \(state) · \(server.transport.summary)"
    }
}
