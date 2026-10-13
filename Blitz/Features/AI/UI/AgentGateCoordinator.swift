import Foundation

/// The one gate every tool call passes: the rule table as the features and the chat narrow it.
@MainActor
final class AgentGateCoordinator {
    private unowned let core: AppCore
    /// Shared by every chat: there is one dialog, and a second call must wait for it.
    private let consent = AIConsentQueue()
    /// "Allow This Chat" answers, by conversation, since a dialog may outlive a chat switch.
    private var grants: [UUID: Set<AgentTool>] = [:]

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
        decision(for: call, scope: chat.agentScope, session: chat.session.id)
    }

    func isOffered(_ tool: AgentTool, in chat: AIChatState) -> Bool {
        decision(for: AgentCall(tool: tool), in: chat) != .deny
    }

    /// What the tools menu lists: the table's own reach, before this chat switches anything off.
    func listed(_ tools: [AgentTool]) -> [AgentTool] {
        AgentPolicy.offered(
            tools, rules: rules, mcpTrust: { self.mcpTrust($0, granted: []) },
            scope: AgentSessionScope())
    }

    func decisions(for tools: [AgentTool], in chat: AIChatState) -> [AgentPolicy.ToolDecision] {
        let granted = grants[chat.session.id] ?? []
        return AgentPolicy.decisions(
            for: tools, rules: rules.granting(granted),
            mcpTrust: { self.mcpTrust($0, granted: granted) }, scope: chat.agentScope)
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
        switch decision(for: call, scope: chat.agentScope, session: session) {
        case .allow: return nil
        case .deny: return .denied
        case .ask: break
        }
        return await consent.ask(cancelled: .declined) { @MainActor [weak self, weak chat] in
            guard let self, let chat else { return .declined }
            switch decision(for: call, scope: chat.agentScope, session: session) {
            case .allow: return nil
            case .deny: return .denied
            case .ask: break
            }
            let choice = await ask(prompt)
            guard choice.allows else { return .declined }
            apply(choice, for: call, session: session)
            let after = decision(for: call, scope: chat.agentScope, session: session)
            return after == .deny ? .denied : nil
        }
    }

    private func decision(
        for call: AgentCall, scope: AgentSessionScope, session: UUID
    ) -> AgentDecision {
        let granted = grants[session] ?? []
        return AgentPolicy.decision(
            for: call, rules: rules.granting(granted),
            mcpTrust: { mcpTrust($0, granted: granted) }, scope: scope)
    }

    /// Off, gone or withheld is Deny, so a server the reader cannot see is never offered.
    private func mcpTrust(_ slug: String, granted: Set<AgentTool>) -> AgentDecision {
        guard let server = core.mcpCoordinator.server(slug: slug) else { return .deny }
        return MCPTrustPolicy.decide(
            trust: server.trust, isGrantedForChat: granted.contains(.mcp(slug)))
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

    private func apply(_ choice: AgentPrompt.Choice, for call: AgentCall, session: UUID) {
        switch choice {
        case .alwaysAllowCommands(let pattern):
            core.aiSettings.addShellRule(ShellRule(pattern: pattern, decision: .allow))
        case .alwaysAllowServer:
            guard case .mcp(let slug) = call.tool,
                let server = core.mcpCoordinator.server(slug: slug)
            else { return }
            core.mcpCoordinator.setTrust(.always, for: server.id)
        case .allowThisChat:
            grants[session, default: []].insert(call.tool)
        case .allowOnce, .refuse:
            break
        }
    }
}
