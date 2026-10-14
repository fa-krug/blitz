import SwiftUI

/// One Providers entry: the on-device model, an installed command, or an API connection.
enum AIProviderRoute: Hashable {
    case appleIntelligence
    case installed(InstalledAIKind)
    case api(UUID)

    /// Nil for a string no route writes, so a stale page falls back to the list.
    init?(page: String) {
        if page == Self.appleIntelligence.page {
            self = .appleIntelligence
            return
        }
        let parts = page.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "installed":
            guard let kind = InstalledAIKind(rawValue: parts[1]) else { return nil }
            self = .installed(kind)
        case "api":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .api(id)
        default:
            return nil
        }
    }

    /// The pane's page string, also the list row's id so Back can scroll to it.
    var page: String {
        switch self {
        case .appleIntelligence: return "apple-intelligence"
        case .installed(let kind): return "installed:\(kind.rawValue)"
        case .api(let id): return "api:\(id.uuidString)"
        }
    }

    var source: AIModelSource {
        switch self {
        case .appleIntelligence: return .appleIntelligence
        case .installed(let kind): return kind.source
        case .api(let id): return .api(id)
        }
    }

    @MainActor func title(in settings: AISettingsStore) -> String {
        switch self {
        case .appleIntelligence: return AppleIntelligence.title
        case .installed(let kind): return kind.title
        case .api(let id): return settings.connection(id: id)?.title ?? "API Connection"
        }
    }

    @MainActor func icon(in settings: AISettingsStore) -> PopoverMenuIcon {
        switch self {
        case .appleIntelligence: return AIModelOption.appleIntelligenceIcon
        case .installed(.codex): return .asset(AIBrand.openAI.assetName)
        case .installed(.claude): return .asset(AIBrand.claude.assetName)
        case .installed(.grok): return .asset(AIBrand.grok.assetName)
        case .installed(.openCode): return .asset(AIBrand.openCode.assetName)
        case .installed(.cursor): return AIModelOption.cursorIcon
        case .api(let id):
            guard let connection = settings.connection(id: id) else { return .symbol("sparkles") }
            // OpenRouter is its own brand; by model, it would show whichever vendor came first.
            if connection.provider == .openRouter { return .asset(AIBrand.openRouter.assetName) }
            return AIModelOption.icon(
                AIBrand.resolve(provider: connection.provider, model: connection.models.first ?? ""))
        }
    }

    static func modelCount(_ count: Int) -> String {
        count == 1 ? "1 model" : "\(count) models"
    }
}

/// One page of a provider's detail; a route lists only the pages it has something to put on.
enum AIProviderTab: String, CaseIterable, Identifiable {
    case overview
    case models
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .models: return "Models"
        case .advanced: return "Advanced"
        }
    }

    static func tabs(for route: AIProviderRoute) -> [AIProviderTab] {
        switch route {
        case .appleIntelligence: return [.overview]
        case .installed: return [.overview, .models, .advanced]
        case .api: return [.overview, .models]
        }
    }
}

extension AIConnection {
    /// A loopback endpoint needs no key, so only a remote one without a stored key is missing it.
    func isMissingKey(hasStoredKey: Bool) -> Bool {
        !hasStoredKey && !AIEndpointPolicy.isLoopback(baseURL)
    }
}

/// Settings › AI › Providers: every route as a row, each opening a page of its own.
struct AIProvidersSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AISettingsStore.self) private var settings
    @Environment(CodexSubscriptionManager.self) private var subscription
    @Environment(InstalledAIManager.self) private var installedAI
    @Environment(SettingsNavigationState.self) private var navigation

    @State private var keyStatuses: [UUID: Bool] = [:]
    @State private var keyError = false
    @State private var editor: AIConnectionEditorTarget?
    /// Kept across providers, as Mail keeps its tab across accounts; one without it shows Overview.
    @State private var tab = AIProviderTab.overview

    private let keyStore = KeychainSecretStore.aiAPIKeys

    var body: some View {
        let shown = shownRoute
        SettingsPagedPane(showsPage: shown != nil) {
            if let shown {
                AIProviderPage(
                    route: shown, tab: $tab, keyStatuses: keyStatuses, keyError: keyError,
                    onEdit: edit, onRemove: confirmRemoval)
                    // Fresh per route, so the models filter never carries over to another.
                    .id(shown)
            }
        } library: {
            library
        }
        .settingsEditorPanel(item: $editor) { target in
            AIConnectionEditorPanel(
                target: target,
                onSave: saveConnection,
                onCancel: { editor = nil })
        }
        .onAppear {
            loadKeyStatuses()
            core.applyInstalledAILifecycle()
        }
        .onChange(of: settings.enabledInstalledProviders) {
            core.applyInstalledAILifecycle()
            reconcile()
        }
        .onChange(of: subscription.models) { reconcile() }
        .onChange(of: subscription.phase) { reconcile() }
        .onChange(of: installedAI.statuses) { reconcile() }
    }

    /// Nil on the list, and for a connection that is gone: Back may still reach its page.
    private var shownRoute: AIProviderRoute? {
        guard let route = navigation.page.flatMap(AIProviderRoute.init(page:)) else { return nil }
        if case .api(let id) = route, settings.connection(id: id) == nil { return nil }
        return route
    }

    private var library: some View {
        Form {
            Section {
                AIProviderRow(route: .appleIntelligence, isMissingKey: false)
            } header: {
                SettingsSectionHeader(.aiProvidersOnThisMac)
            }

            Section {
                ForEach(InstalledAIKind.allCases) { kind in
                    AIProviderRow(route: .installed(kind), isMissingKey: false)
                }
            } header: {
                SettingsSectionHeader(.aiProvidersInstalled)
            }

            Section {
                if settings.connections.isEmpty {
                    Text("None yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.connections) { connection in
                    AIProviderRow(
                        route: .api(connection.id),
                        isMissingKey: connection.isMissingKey(
                            hasStoredKey: keyStatuses[connection.id] == true))
                }
                LabeledContent {
                    Menu("Add…") {
                        ForEach(AIProviderKind.allCases) { provider in
                            Button(provider.title) { add(provider) }
                        }
                    }
                    .fixedSize()
                } label: {
                    SettingsRowTitle(.aiProvidersAPIConnections, "Add API Connection")
                    Text("A hosted provider, or any OpenAI-compatible endpoint.")
                }
            } header: {
                SettingsSectionHeader(.aiProvidersAPIConnections)
            } footer: {
                Text("Keys stay in your login Keychain, tied to the endpoint they were saved for.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.aiProviders)
    }

    // MARK: - Actions

    private func reconcile() {
        settings.reconcile(subscription: subscription, installedAI: installedAI)
    }

    private func add(_ provider: AIProviderKind) {
        editor = AIConnectionEditorTarget(
            connection: AIConnection(provider: provider), hasStoredKey: false, isNew: true)
    }

    private func edit(_ connection: AIConnection) {
        editor = AIConnectionEditorTarget(
            connection: connection,
            hasStoredKey: keyStatuses[connection.id] == true,
            isNew: false)
    }

    private func saveConnection(
        _ connection: AIConnection, key: String, isNew: Bool
    ) -> String? {
        let outcome = AIConnectionKeyPolicy.resolve(
            enteredKey: key, connection: connection, saved: settings.connection(id: connection.id),
            hasStoredKey: keyStatuses[connection.id] == true)
        do {
            switch outcome {
            case .store(let key): try keyStore.setSecret(key, for: connection.id)
            case .removeStored: try keyStore.removeSecret(for: connection.id)
            case .keep: break
            case .reject(let message): return message
            }
            settings.save(connection)
            editor = nil
            if isNew { navigation.select(navigation.tab, page: AIProviderRoute.api(connection.id).page) }
            loadKeyStatuses()
            reconcile()
            return nil
        } catch {
            keyError = true
            return isNew
                ? "The key could not be saved to Keychain."
                : "The saved key could not be updated in Keychain."
        }
    }

    private func confirmRemoval(of connection: AIConnection) {
        Task {
            guard
                await core.confirm(
                    title: "Remove “\(connection.title)”?",
                    message: "Its saved API key will also be deleted from Keychain.",
                    symbol: PaletteMode.ai.systemImage, confirmTitle: "Remove Connection")
            else { return }
            removeConnection(connection)
        }
    }

    private func removeConnection(_ connection: AIConnection) {
        do {
            try keyStore.removeSecret(for: connection.id)
            settings.removeConnection(id: connection.id)
            loadKeyStatuses()
        } catch {
            keyError = true
        }
    }

    private func loadKeyStatuses() {
        var statuses: [UUID: Bool] = [:]
        do {
            for connection in settings.connections {
                statuses[connection.id] = try keyStore.hasSecret(for: connection.id)
            }
            keyStatuses = statuses
            keyError = false
        } catch {
            keyStatuses = statuses
            keyError = true
        }
    }
}

/// Read-only, so it holds no AppKit control: the route's switch and status live on its page.
private struct AIProviderRow: View {
    @Environment(AISettingsStore.self) private var settings
    @Environment(CodexSubscriptionManager.self) private var subscription
    @Environment(InstalledAIManager.self) private var installedAI
    @Environment(SettingsNavigationState.self) private var navigation

    let route: AIProviderRoute
    let isMissingKey: Bool

    var body: some View {
        let title = route.title(in: settings)
        Button {
            navigation.select(navigation.tab, page: route.page)
        } label: {
            SettingsRow(
                title: title, subtitle: caption,
                labelOpacity: settings.isRouteEnabled(route.source) ? 1 : 0.45
            ) {
                AIProviderTile(icon: route.icon(in: settings))
            } trailing: {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Configure \(title)")
        .id(route.page)
    }

    /// The one line a reader scans the list for: is it usable, and if not, why.
    private var caption: String {
        guard settings.isRouteEnabled(route.source) else { return "Off" }
        switch route {
        case .appleIntelligence:
            return settings.isAppleIntelligenceAvailable() ? "Ready · Runs on this Mac" : "Unavailable"
        case .installed(let kind):
            return kind == .codex ? codexCaption : installedCaption(kind)
        case .api(let id):
            guard let connection = settings.connection(id: id) else { return "" }
            if isMissingKey { return "Key missing" }
            let count = AIProviderRoute.modelCount(connection.models.count)
            return connection.name.isEmpty ? count : "\(connection.provider.title) · \(count)"
        }
    }

    private var codexCaption: String {
        switch subscription.phase {
        case .idle, .starting: return "Checking…"
        case .signedOut: return "Sign in required"
        case .unavailable: return "Not installed"
        case .failed: return "Check failed"
        case .connected:
            let count = AIProviderRoute.modelCount(subscription.models.count)
            guard let account = subscription.account else { return "Ready · " + count }
            let plan = account.planTitle == "API key" ? "API key" : "ChatGPT \(account.planTitle)"
            return "\(plan) · \(count)"
        }
    }

    private func installedCaption(_ kind: InstalledAIKind) -> String {
        let status = installedAI.status(for: kind)
        switch status.phase {
        case .idle, .checking: return "Checking…"
        case .ready: return "Ready · " + AIProviderRoute.modelCount(status.models.count)
        case .signInRequired: return "Sign in required"
        case .notInstalled: return "Not installed"
        case .failed: return "Check failed"
        }
    }
}

/// The row and page glyph: a brand mark or symbol on the tile `SettingsTabIcon` draws.
struct AIProviderTile: View {
    let icon: PopoverMenuIcon
    var size = Theme.Size.settingsSidebarGlyph + Theme.Spacing.xs * 2

    var body: some View {
        let scale = size / (Theme.Size.settingsSidebarGlyph + Theme.Spacing.xs * 2)
        glyph
            .frame(
                width: Theme.Size.settingsSidebarGlyph * scale,
                height: Theme.Size.settingsSidebarGlyph * scale
            )
            .foregroundStyle(.primary)
            .padding(Theme.Spacing.xs * scale)
            .background(
                Theme.Colors.controlSurface,
                in: RoundedRectangle(
                    cornerRadius: Theme.Radius.thumbnail * scale, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .asset(let name):
            Image(name).resizable().renderingMode(.template).scaledToFit()
        case .symbol(let name):
            Image(systemName: name).resizable().scaledToFit()
        case .file, .thumbnail, .blank, .glyph:
            Image(systemName: "sparkles").resizable().scaledToFit()
        }
    }
}

extension AISettingsStore {
    /// Moves the default model off any route that just went away, or onto its current catalogue.
    func reconcile(subscription: CodexSubscriptionManager, installedAI: InstalledAIManager) {
        let enabled = enabledInstalledProviders
        reconcile(
            codexModels: enabled.contains(.codex) ? subscription.models : [],
            isUnavailable: !enabled.contains(.codex) || subscription.phase == .signedOut
                || subscription.phase.isUnavailable)
        for kind in InstalledAIKind.managedCLIKinds {
            let status = installedAI.status(for: kind)
            reconcile(
                installed: kind,
                models: enabled.contains(kind) ? status.models : [],
                isUnavailable: !enabled.contains(kind) || status.phase == .signInRequired
                    || status.phase == .notInstalled)
        }
    }
}
