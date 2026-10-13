import Foundation
import Observation

/// MCP's action surface: what is running, what the model may call, and who is asked first.
@MainActor
@Observable
final class MCPCoordinator {
    private let settings: AppSettings
    private let store: MCPSettingsStore
    private let manager: MCPServerManager
    private unowned let core: AppCore

    init(
        settings: AppSettings, store: MCPSettingsStore, manager: MCPServerManager, core: AppCore
    ) {
        self.settings = settings
        self.store = store
        self.manager = manager
        self.core = core
    }

    var isActive: Bool { settings.aiEnabled && settings.mcpEnabled }

    /// Off means off: no connection, no resident process, and nothing offered to a model.
    func applyEnabled() {
        defer { dropWithdrawnServers() }
        guard isActive else {
            core.mcpOAuth.stop()
            manager.stop()
            return
        }
        manager.reconcile(ownServers)
    }

    /// The Codex helper keeps what it was launched with, so a server taken away is taken from it.
    private func dropWithdrawnServers(besides withdrawn: UUID? = nil) {
        let offered = store.enabledServers.filter { $0.trust != .never && $0.id != withdrawn }
        core.codexSubscription.dropWithdrawnServers(
            keeping: isActive ? Set(offered.map(\.slug)) : [])
    }

    /// Connecting on the way into chat, so the first send does not wait on every handshake.
    func warmUp() {
        guard isActive else { return }
        manager.reconcile(ownServers)
    }

    /// What Blitz runs itself; Codex and Claude start their own copy of every local server.
    private var ownServers: [MCPServer] {
        let cliRoute = core.aiChatCoordinator.everyChatRunsItsOwnTools
        return store.enabledServers.filter { $0.runsInBlitz(whileCLIRouteSelected: cliRoute) }
    }

    var slugs: Set<String> {
        guard isActive else { return [] }
        return Set(store.enabledServers.map(\.slug))
    }

    /// What a chat's tools menu lists; empty while MCP is off.
    var servers: [MCPServer] {
        guard isActive else { return [] }
        return store.enabledServers
    }

    func server(slug: String) -> MCPServer? {
        guard isActive else { return nil }
        return store.enabledServers.first { $0.slug == slug }
    }

    /// Every enabled server's tools, or one server's when `@slug` named it; the agent gate narrows.
    func tools(scopedTo slug: String?) -> [AITool] {
        guard isActive else { return [] }
        return manager.tools.filter { slug == nil || $0.serverSlug == slug }.map(\.aiTool)
    }

    /// The same list for a CLI route; it starts its own copies, so Blitz's need not be ready.
    func toolServers(
        scopedTo slug: String?, offering isOffered: (String) -> Bool
    ) async -> [AIToolServer] {
        guard isActive else { return [] }
        let secrets = MCPSecretStore()
        var result: [AIToolServer] = []
        for server in store.enabledServers
        where (slug == nil || server.slug == slug) && isOffered(server.slug) {
            let stored = secrets.secrets(for: server.id)
            var bearer: String?
            if server.oauth == true { bearer = try? await core.mcpOAuth.lentToken(for: server) }
            guard
                let toolServer = server.toolServer(
                    headerValue: stored.headerValue, environment: stored.environment,
                    bearerToken: bearer)
            else { continue }
            result.append(toolServer)
        }
        return result
    }

    /// Runs a call the agent gate has already let through.
    func invoke(_ call: AIToolCall) async -> AIToolResult {
        guard let route = MCPToolName.parse(call.name), server(slug: route.slug) != nil,
            let connection = manager.connection(slug: route.slug)
        else {
            return .failure(call.id, "That tool is no longer connected.")
        }
        manager.markUsed()
        do {
            let (content, isError) = try await connection.call(
                route.tool, arguments: JSONValue(data: Data(call.arguments.utf8)) ?? .object([:]))
            return AIToolResult(callID: call.id, content: content, isError: isError)
        } catch {
            return .failure(call.id, error.localizedDescription)
        }
    }

    func signIn(_ server: MCPServer, credentials: MCPOAuth.Credentials) async throws {
        guard isActive else { throw MCPOAuth.Failure.signInRequired }
        manager.disconnect(server.id)
        try await core.mcpOAuth.signIn(server: server, credentials: credentials)
    }

    func signOut(_ id: UUID) throws {
        manager.disconnect(id)
        try core.mcpOAuth.signOut(id)
        dropWithdrawnServers(besides: id)
    }

    func cancelSignIn(_ id: UUID) { core.mcpOAuth.cancelSignIn(id) }

    func status(of id: UUID) -> MCPServerStatus { manager.status(of: id) }

    func save(_ server: MCPServer, secrets: MCPSecretStore.Secrets) throws {
        try MCPSecretStore().save(secrets, for: server.id)
        core.mcpOAuth.cancelSignIn(server.id)
        manager.disconnect(server.id)
        store.save(server)
        applyEnabled()
    }

    func setTrust(_ trust: MCPTrust, for id: UUID) {
        store.setTrust(trust, for: id)
        dropWithdrawnServers()
    }

    func remove(_ id: UUID) throws {
        core.mcpOAuth.cancelSignIn(id)
        try MCPSecretStore().remove(for: id)
        store.remove(id: id)
        applyEnabled()
    }

    func discardUnsaved(_ id: UUID) {
        cancelSignIn(id)
        if store.server(id: id) == nil { try? MCPSecretStore().remove(for: id) }
    }

    func authenticationStatus(
        _ server: MCPServer, stored: MCPOAuth.Credentials?
    ) -> MCPOAuthManager.Status {
        core.mcpOAuth.status(for: server, stored: stored)
    }

    func test(_ server: MCPServer, secrets: MCPSecretStore.Secrets) async -> MCPServerStatus {
        if server.oauth == true {
            let stored = MCPSecretStore().secrets(for: server.id).oauth
            guard stored?.clientID == secrets.oauth?.clientID,
                stored?.clientSecret == secrets.oauth?.clientSecret
            else { return .signInRequired }
        }
        let connection = MCPServerConnection(server: server, secrets: secrets, oauth: core.mcpOAuth)
        defer { connection.stop() }
        await connection.start()
        return connection.status
    }
}
