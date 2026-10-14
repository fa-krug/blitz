import SwiftUI

/// One provider's own page: its header and switch, then whichever of its tabs is chosen.
struct AIProviderPage: View {
    @Environment(AISettingsStore.self) private var settings
    @Environment(CodexSubscriptionManager.self) private var subscription
    @Environment(InstalledAIManager.self) private var installedAI

    let route: AIProviderRoute
    @Binding var tab: AIProviderTab
    let keyStatuses: [UUID: Bool]
    let keyError: Bool
    let onEdit: (AIConnection) -> Void
    let onRemove: (AIConnection) -> Void

    @State private var modelQuery = ""

    var body: some View {
        let tabs = AIProviderTab.tabs(for: route)
        let shown = tabs.contains(tab) ? tab : .overview
        Form {
            // The window's Back chevron leaves the page, as on an extension's.
            Section {
                header
            } footer: {
                if tabs.count > 1 {
                    Picker("Page", selection: $tab) {
                        ForEach(tabs) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Spacing.md)
                }
            }

            switch route {
            case .appleIntelligence:
                appleIntelligenceSections
            case .installed(let kind):
                installedSections(kind, tab: shown)
            case .api(let id):
                if let connection = settings.connection(id: id) {
                    connectionSections(connection, tab: shown)
                }
            }
        }
        .formStyle(.grouped)
        .releasesFocusOnOutsideClick()
    }

    private var title: String { route.title(in: settings) }

    private var header: some View {
        HStack(spacing: Theme.Spacing.lg) {
            AIProviderTile(icon: route.icon(in: settings), size: Theme.Size.settingsRowIcon * 1.5)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(kindCaption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.lg)
            switch route {
            case .installed(let kind):
                if let version = installedAI.status(for: kind).version,
                    settings.enabledInstalledProviders.contains(kind)
                {
                    Text("v" + version)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            case .api(let id):
                if let connection = settings.connection(id: id) {
                    Button("Edit…") { onEdit(connection) }
                    Button("Remove…", role: .destructive) { onRemove(connection) }
                }
            case .appleIntelligence:
                EmptyView()
            }
            Toggle(
                "Enable \(title)",
                isOn: Binding(
                    get: { settings.isRouteEnabled(route.source) },
                    set: { settings.setRoute(route.source, enabled: $0) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var kindCaption: String {
        switch route {
        case .appleIntelligence: return "On this Mac · No account needed"
        case .installed(let kind): return "Installed command · \(kind.command)"
        case .api(let id):
            return "API connection · " + (settings.connection(id: id)?.provider.title ?? "")
        }
    }

    // MARK: - On this Mac

    @ViewBuilder
    private var appleIntelligenceSections: some View {
        let available = settings.isAppleIntelligenceAvailable()
        if !settings.isRouteEnabled(.appleIntelligence) { turnedOffSection() }
        Section {
            LabeledContent {
                Text(available ? "Ready" : "Unavailable")
                    .foregroundStyle(.secondary)
            } label: {
                Text(AppleIntelligence.title)
                Text(
                    available
                        ? "Runs on this Mac. Nothing leaves it."
                        : AppleIntelligenceProvider.status().message ?? "Not available on this Mac.")
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Choose the default model on the AI pane.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Installed commands

    @ViewBuilder
    private func installedSections(_ kind: InstalledAIKind, tab: AIProviderTab) -> some View {
        let isOn = settings.enabledInstalledProviders.contains(kind)
        switch tab {
        case .advanced:
            AIProviderAdvancedSection(kind: kind, detected: isOn ? executable(for: kind) : nil)
        case .overview, .models:
            if !isOn {
                turnedOffSection(footer: installedFooter(kind))
            } else if tab == .models {
                modelsSection(models: installedModels(kind))
            } else {
                Section {
                    AIInstalledStatusRows(kind: kind)
                } header: {
                    Text("Status")
                } footer: {
                    Text(installedFooter(kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func turnedOffSection(footer: String? = nil) -> some View {
        Section {
            LabeledContent {
                EmptyView()
            } label: {
                Label("Turned off", systemImage: "pause.circle")
                Text("Blitz leaves it alone, and its models stay out of every model picker.")
            }
        } footer: {
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func executable(for kind: InstalledAIKind) -> URL? {
        kind == .codex ? subscription.executable : installedAI.status(for: kind).executable
    }

    private func installedFooter(_ kind: InstalledAIKind) -> String {
        kind.isolationCaveat(hasManagedMCPPolicy: InstalledAIManager.hasManagedMCPPolicy)
            ?? "Uses the \(kind.command) command signed in on this Mac. Its keys are never stored."
    }

    private func installedModels(_ kind: InstalledAIKind) -> [ProviderModel] {
        if kind == .codex {
            guard subscription.isConnected else { return [] }
            return subscription.models.map { ProviderModel(id: $0.id, name: $0.name) }
        }
        let status = installedAI.status(for: kind)
        guard status.isReady else { return [] }
        return status.models.map { ProviderModel(id: $0.id, name: $0.name) }
    }

    // MARK: - API connections

    @ViewBuilder
    private func connectionSections(
        _ connection: AIConnection, tab: AIProviderTab
    ) -> some View {
        if !settings.isRouteEnabled(.api(connection.id)) { turnedOffSection() }
        if tab == .models {
            modelsSection(models: connection.models.map { ProviderModel(id: $0, name: $0) })
        } else {
            connectionSection(connection)
        }
    }

    private func connectionSection(_ connection: AIConnection) -> some View {
        let hasStoredKey = keyStatuses[connection.id] == true
        return Section {
            LabeledContent("Provider", value: connection.provider.title)
            LabeledContent("Base URL") {
                Text(connection.baseURL)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LabeledContent("API key") {
                Text(keyStatus(connection, hasStoredKey: hasStoredKey))
                    .foregroundStyle(
                        connection.isMissingKey(hasStoredKey: hasStoredKey)
                            ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if keyError {
                Label("The login Keychain could not be accessed.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Keys stay in your login Keychain, tied to the endpoint they were saved for.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func keyStatus(_ connection: AIConnection, hasStoredKey: Bool) -> String {
        if hasStoredKey { return "Stored in Keychain" }
        return AIEndpointPolicy.isLoopback(connection.baseURL) ? "None needed locally" : "Missing"
    }

    // MARK: - Models

    @ViewBuilder
    private func modelsSection(models: [ProviderModel]) -> some View {
        if models.isEmpty {
            Section {
                Text("Models are listed here once \(title) is ready.")
                    .foregroundStyle(.secondary)
            }
        } else {
            let source = route.source
            let shownSet = settings.shownModels[source.storageKey].map(Set.init)
            let shownCount = shownSet.map { set in models.count { set.contains($0.id) } } ?? models.count
            let matches = filtered(models)
            Section {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.sm) {
                        Button("Show All") { settings.showAllModels(in: source) }
                            .disabled(shownCount == models.count)
                        Button("Hide All") { settings.hideAllModels(in: source) }
                    }
                    .fixedSize()
                } label: {
                    Text(
                        "\(shownCount) of \(AIProviderRoute.modelCount(models.count)) "
                            + "in the model picker")
                }
                if models.count > Self.filterThreshold {
                    SettingsFilterField(prompt: "Filter models", query: $modelQuery)
                }
                if matches.isEmpty {
                    Text("No model matches “\(modelQuery)”.")
                        .foregroundStyle(.secondary)
                }
                if !matches.isEmpty {
                    AIModelChecklist(
                        items: matches.map { model in
                            AIModelChecklist.Item(
                                id: model.id, title: model.name,
                                isOn: shownSet?.contains(model.id) ?? true,
                                isLocked: isDefault(model.id))
                        },
                        onToggle: { id, isOn in
                            settings.setModel(
                                id, shown: isOn, in: source, available: models.map(\.id))
                        })
                }
            } footer: {
                Text(
                    "Ticked models appear in the model picker. The default model always does; "
                        + "choose it on the AI pane."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Past a screenful, OpenCode alone lists hundreds, so the list gets the Settings filter row.
    private static let filterThreshold = 8

    private func filtered(_ models: [ProviderModel]) -> [ProviderModel] {
        let query = modelQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private func isDefault(_ model: String) -> Bool {
        guard let selection = settings.defaultModel else { return false }
        return selection.source == route.source && selection.model == model
    }
}

/// A model row's content, whichever of the three catalogue shapes it came from.
private struct ProviderModel: Identifiable {
    let id: String
    let name: String
}
