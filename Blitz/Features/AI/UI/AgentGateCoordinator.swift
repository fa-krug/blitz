import Foundation

/// The one gate every tool call passes: the rule table as the features and the chat narrow it.
@MainActor
final class AgentGateCoordinator {
    private unowned let core: AppCore
    /// Shared by every chat on screen: there is one dialog, and a second call must wait for it.
    private let consent = AIConsentQueue()
    /// The one definition of on screen, `AIChatCoordinator.isOnScreen`; an Ask asks nowhere else.
    private let isOnScreen: @MainActor (AIChatState) -> Bool

    private enum Turn: Sendable {
        case answered(AgentRefusal?)
        /// The chat left the screen while an earlier dialog was up, so this one waits again.
        case offScreen
    }

    init(core: AppCore, isOnScreen: @escaping @MainActor (AIChatState) -> Bool) {
        self.core = core
        self.isOnScreen = isOnScreen
    }

    /// The table under each feature's own switch, which is where macOS was asked for access.
    var rules: AgentRules {
        let ceiling = AgentFeatureCeiling(
            settings: core.settings, visibility: core.visibility,
            isAccessibilityTrusted: Permissions.isAccessibilityTrusted)
        return core.aiSettings.agentRules.restricted { ceiling.isAvailable($0) }
    }

    func decision(for call: AgentCall, in chat: AIChatState) -> AgentDecision {
        decision(for: call, scope: chat.agentScope)
    }

    func isOffered(_ tool: AgentTool, in chat: AIChatState) -> Bool {
        isOffered(AgentCall(tool: tool), in: chat)
    }

    func isOffered(_ call: AgentCall, in chat: AIChatState) -> Bool {
        decision(for: call, in: chat) != .deny
    }

    /// What the tools menu lists: the table's own reach, before this chat switches anything off.
    func listed(_ tools: [AgentTool]) -> [AgentTool] {
        AgentPolicy.offered(tools, rules: rules, mcpTrust: mcpTrust, scope: AgentSessionScope())
    }

    func decisions(for calls: [AgentCall], in chat: AIChatState) -> [AgentPolicy.ToolDecision] {
        AgentPolicy.decisions(for: calls, rules: rules, mcpTrust: mcpTrust, scope: chat.agentScope)
    }

    /// Bound to one call, for a runner to put its dialog to once it has read the arguments.
    func authorization(for call: AgentCall, in chat: AIChatState) -> AgentAuthorization {
        { [weak self, weak chat] prompt in
            guard let self, let chat else { return AgentRefusal.declined.message(for: call.tool) }
            return await authorize(call, prompt: prompt, in: chat)?.message(for: call.tool)
        }
    }

    /// An MCP call from either route, weighed by its own read-only hint, which only Plan reads.
    func authorize(_ call: AIToolServerCall, in chat: AIChatState) async -> AgentRefusal? {
        let mcp = core.mcpCoordinator
        guard let server = mcp.server(slug: call.handle) else { return .denied }
        return await authorize(
            .mcp(call, listed: mcp.listedTools(slug: call.handle)),
            prompt: .mcp(serverTitle: server.title, tool: call.tool), in: chat)
    }

    /// Nil runs the call. An Ask waits until its chat is on screen, then joins the dialog line.
    func authorize(
        _ call: AgentCall, prompt: AgentPrompt, in chat: AIChatState
    ) async -> AgentRefusal? {
        let session = chat.session.id
        switch decision(for: call, scope: chat.agentScope) {
        case .allow: return nil
        case .deny: return .denied
        case .ask: break
        }
        let approval = chat.beginApproval()
        defer { chat.endApproval(approval) }
        while await isShown(chat, approval: approval) {
            let declined = Turn.answered(.declined)
            let turn = await consent.ask(cancelled: declined) { @MainActor [weak self, weak chat] in
                guard let self, let chat, chat.isApprovalPending(approval) else { return declined }
                guard isOnScreen(chat) else { return .offScreen }
                return .answered(await ask(call, prompt: prompt, in: chat, session: session))
            }
            if case .answered(let refusal) = turn { return refusal }
        }
        return .declined
    }

    /// False once the request ended first: Stop, a delete or a clear declines what still waits.
    private func isShown(_ chat: AIChatState, approval: UUID) async -> Bool {
        guard chat.isApprovalPending(approval) else { return false }
        if isOnScreen(chat) { return true }
        return await chat.holdApproval(approval)
    }

    /// Read again at its turn, since an earlier dialog may have answered it, and once it closes.
    private func ask(
        _ call: AgentCall, prompt: AgentPrompt, in chat: AIChatState, session: UUID
    ) async -> AgentRefusal? {
        switch decision(for: call, scope: chat.agentScope) {
        case .allow: return nil
        case .deny: return .denied
        case .ask: break
        }
        let choice = await ask(prompt)
        guard choice.allows else { return .declined }
        apply(choice, for: call, in: chat, session: session)
        return decision(for: call, scope: chat.agentScope) == .deny ? .denied : nil
    }

    private func decision(for call: AgentCall, scope: AgentSessionScope) -> AgentDecision {
        AgentPolicy.decision(for: call, rules: rules, mcpTrust: mcpTrust, scope: scope)
    }

    /// Off, gone or withheld is Deny, so a server the reader cannot see is never offered.
    private func mcpTrust(_ slug: String) -> AgentDecision {
        core.mcpCoordinator.server(slug: slug)?.trust.decision ?? .deny
    }

    /// Escape is the last choice, a refusal; only Settings can withhold a tool for good.
    private func ask(_ prompt: AgentPrompt) async -> AgentPrompt.Choice {
        let index = await core.choose(
            title: prompt.title, message: prompt.message, symbol: prompt.symbol,
            options: prompt.choices.map {
                DialogAction(title: $0.title, role: $0.allows ? .standard : .cancel)
            },
            defaultIndex: prompt.defaultIndex)
        return prompt.choices.indices.contains(index) ? prompt.choices[index] : .refuse("")
    }

    /// A grant lands only on the chat that asked; one switched away from has a fresh scope.
    private func apply(
        _ choice: AgentPrompt.Choice, for call: AgentCall, in chat: AIChatState, session: UUID
    ) {
        switch choice {
        case .alwaysAllowCommands(let pattern):
            core.aiSettings.allowShellPattern(pattern, for: call.command ?? "")
        case .alwaysAllowPaths(let pattern):
            core.aiSettings.allowPathPattern(pattern, for: call)
        case .alwaysAllowServer:
            guard case .mcp(let slug) = call.tool,
                let server = core.mcpCoordinator.server(slug: slug)
            else { return }
            core.mcpCoordinator.setTrust(.always, for: server.id)
        case .allowThisChat:
            guard chat.session.id == session else { return }
            chat.agentScope.grant(call.tool)
        case .allowOnce, .refuse:
            break
        }
    }
}
