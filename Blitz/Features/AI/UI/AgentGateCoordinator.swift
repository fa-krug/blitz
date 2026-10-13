import Foundation

/// The one gate every tool call passes: the rule table as the features and the chat narrow it.
@MainActor
final class AgentGateCoordinator {
    private unowned let core: AppCore
    /// Shared by every chat: there is one dialog, and a second call must wait for it.
    private let consent = AIConsentQueue()

    init(core: AppCore) {
        self.core = core
    }

    /// The table under each feature's own switch, which is where macOS was asked for access.
    var rules: AgentRules {
        let settings = core.settings
        return core.aiSettings.agentRules.restricted { tool in
            switch tool {
            case .calendarRead, .calendarWrite: settings.calendarEnabled
            case .remindersRead, .remindersWrite: settings.remindersEnabled
            case .shell, .webSearch, .mcp: true
            }
        }
    }

    func decision(for call: AgentCall, in chat: AIChatState) -> AgentDecision {
        decision(for: call, scope: chat.agentScope)
    }

    func isOffered(_ tool: AgentTool, in chat: AIChatState) -> Bool {
        decision(for: AgentCall(tool: tool), in: chat) != .deny
    }

    /// What the tools menu lists: the table's own reach, before this chat switches anything off.
    func listed(_ tools: [AgentTool]) -> [AgentTool] {
        AgentPolicy.offered(tools, rules: rules, mcpTrust: mcpTrust, scope: AgentSessionScope())
    }

    func decisions(for tools: [AgentTool], in chat: AIChatState) -> [AgentPolicy.ToolDecision] {
        AgentPolicy.decisions(
            for: tools.map { AgentCall(tool: $0) }, rules: rules, mcpTrust: mcpTrust,
            scope: chat.agentScope)
    }

    /// Bound to one call, for a runner to put its dialog to once it has read the arguments.
    func authorization(for call: AgentCall, in chat: AIChatState) -> AgentAuthorization {
        { [weak self, weak chat] prompt in
            guard let self, let chat else { return AgentRefusal.declined.message(for: call.tool) }
            return await authorize(call, prompt: prompt, in: chat)?.message(for: call.tool)
        }
    }

    /// An MCP call from either route; the dialog is the server's own three-way question.
    func authorize(_ call: AIToolServerCall, in chat: AIChatState) async -> AgentRefusal? {
        guard let server = core.mcpCoordinator.server(slug: call.handle) else { return .denied }
        return await authorize(
            AgentCall(tool: .mcp(call.handle)),
            prompt: .mcp(serverTitle: server.title, tool: call.tool), in: chat)
    }

    /// Nil runs the call; read again when a queued call's turn comes, and once its dialog closes.
    func authorize(
        _ call: AgentCall, prompt: AgentPrompt, in chat: AIChatState
    ) async -> AgentRefusal? {
        let session = chat.session.id
        switch decision(for: call, scope: chat.agentScope) {
        case .allow: return nil
        case .deny: return .denied
        case .ask: break
        }
        return await consent.ask(cancelled: .declined) { @MainActor [weak self, weak chat] in
            guard let self, let chat else { return .declined }
            switch decision(for: call, scope: chat.agentScope) {
            case .allow: return nil
            case .deny: return .denied
            case .ask: break
            }
            let choice = await ask(prompt)
            guard choice.allows else { return .declined }
            apply(choice, for: call, in: chat, session: session)
            let after = decision(for: call, scope: chat.agentScope)
            return after == .deny ? .denied : nil
        }
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
