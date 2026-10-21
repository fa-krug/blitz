import AppKit
import SwiftUI

/// Chat actions for both surfaces, plus the AI Chat window's own; views route every mutation here.
@MainActor
@Observable
final class AIChatCoordinator {
    let chats: AIChatSurfacesState
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private unowned let core: AppCore
    private let window: AppWindowController
    /// Chats with a title request in flight, so a quick second reply never asks twice.
    @ObservationIgnored private var naming: [UUID: Task<Void, Never>] = [:]
    /// Every tool call on either surface is decided, and asked about, here.
    @ObservationIgnored private lazy var gate = AgentGateCoordinator(
        core: core, isOnScreen: { [unowned self] chat in isOnScreen(chat) })
    /// What can bring a chat on screen without anything in the chats changing.
    @ObservationIgnored private var presenceObservers: [NotificationToken] = []

    init(
        chats: AIChatSurfacesState, settings: AppSettings, appIndex: AppIndex,
        paletteCoordinator: PaletteCoordinator, settingsCoordinator: SettingsCoordinator,
        core: AppCore
    ) {
        self.chats = chats
        self.settings = settings
        self.appIndex = appIndex
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.core = core
        window = AppWindowController(
            title: "AI Agent", contentSize: Theme.Size.aiChatWindow,
            minimumSize: Theme.Size.aiChatWindowMinimum, resizable: true,
            autosaveName: "AIChatWindow", activation: core.activationPolicy, closesOnEscape: true)
        chats.onReplyFinished = { [weak self] chat in self?.nameIfNeeded(chat) }
    }

    func applyEnabled() {
        appIndex.setCommandsVisible([.aiChat, .quickAI], settings.aiEnabled)
        guard settings.aiEnabled else {
            for request in naming.values { request.cancel() }
            naming = [:]
            // Before the handle closes: cancelling an open reply saves the conversation it ends.
            chats.reset()
            window.close()
            core.applyInstalledAILifecycle()
            core.chatHistory.close()
            core.quickAICoordinator.leave()
            return
        }
        core.applyInstalledAILifecycle()
        watchWaits()
        // Deferred off the launch path like the clipboard's own read; history fills in behind it.
        Task {
            core.chatHistory.load()
            core.agentMemoryCoordinator.load()
            // Inside the enabled branch only: off means the file is untouched, however old it gets.
            applyRetention()
        }
    }

    func applyRetention() {
        guard settings.aiEnabled,
            let cutoff = core.aiSettings.retention.cutoff(from: Date())
        else { return }
        core.chatHistory.prune(before: cutoff)
    }

    // MARK: - The window

    /// Reopens on whatever it last showed unless asked to apply "Opens to", as a summon is.
    func showWindow(applyingOpenPolicy: Bool = false) {
        guard settings.aiEnabled else { return }
        prepareForChat()
        guard !window.focus() else { return }
        if applyingOpenPolicy {
            chats.applyWindowOpenPolicy(
                opensTo: core.aiSettings.opensTo, newAfter: core.aiSettings.newChatAfter)
        }
        // One find per window: the chrome's search field writes it, the transcript reads it.
        let find = ChatFindState()
        window.show(chrome: AIChatWindowChrome(coordinator: self, chats: chats, find: find)) {
            AIChatSplitViewController(
                sidebar: AIChatSidebarView().environment(self),
                detail: AIChatDetailView().environment(self).environment(find))
        }
    }

    /// Key, not visible: a chat open behind another app comes forward rather than closing.
    func toggleWindow() {
        guard !closeWindowIfKey() else { return }
        showWindow(applyingOpenPolicy: true)
    }

    /// The window's views read these through the coordinator, never through `AppCore`.
    var history: ChatHistoryStore { core.chatHistory }
    var aiSettings: AISettingsStore { core.aiSettings }

    func focusExisting() -> Bool {
        window.focus()
    }

    /// ⌘Q's target while the window is key; false leaves the chord to Settings.
    func closeWindowIfKey() -> Bool {
        guard NSApp.keyWindow?.identifier == AIChatWindowChrome.windowIdentifier else {
            return false
        }
        window.close()
        return true
    }

    func newChat() {
        chats.newWindowChat()
    }

    func openChat(id: UUID) {
        guard chats.openInWindow(id: id) else {
            core.showMessage("That chat could not be opened.", tone: .danger)
            return
        }
    }

    /// The sidebar's filter is the view's own state, so ⌃⇥ walks every saved chat.
    func openAdjacentChat(step: Int) {
        guard
            let target = history.conversations.pinnedFirst.adjacent(
                to: chats.window.session.id, step: step)
        else { return }
        openChat(id: target.id)
    }

    /// Quick AI's ⌘J: the conversation, its staged files and the half-typed line all move over.
    func continueInWindow(draft: String) {
        chats.continueQuickAIInWindow(draft: draft)
        showWindow()
    }

    /// A fresh window chat seeded from elsewhere, leaving whatever Quick AI holds where it is.
    func startChat(draft: String = "", attaching files: [URL] = []) {
        guard settings.aiEnabled else { return }
        chats.newWindowChat()
        showWindow()
        let chat = chats.window
        if !draft.isEmpty { chat.draft = chat.draft.isEmpty ? draft : chat.draft + "\n" + draft }
        if !files.isEmpty { attach(files: files, to: chat) }
    }

    /// A chat with no message yet is unsaved, so it has nothing to pin, copy or delete.
    func isSaved(_ chat: AIChatState) -> Bool {
        core.chatHistory.conversation(id: chat.session.id) != nil
    }

    func isPinned(_ chat: AIChatState) -> Bool {
        core.chatHistory.conversation(id: chat.session.id)?.isPinned == true
    }

    func togglePin(id: UUID) {
        guard let conversation = core.chatHistory.conversation(id: id) else { return }
        core.chatHistory.setPinned(!conversation.isPinned, id: id)
    }

    /// A pinned chat stays in view and a reply still arriving stays live, so neither is archived.
    func canArchive(id: UUID) -> Bool {
        guard let conversation = core.chatHistory.conversation(id: id) else { return false }
        return !conversation.isPinned && !conversation.isArchived
            && !chats.answeringIDs.contains(id)
    }

    /// The open chat makes way for a new one, as a delete does; nothing of it is lost.
    func archiveChat(id: UUID) {
        guard canArchive(id: id), chats.archive(id: id) else {
            core.showMessage("That chat could not be archived.", tone: .danger)
            return
        }
    }

    func unarchiveChat(id: UUID) {
        core.chatHistory.unarchive(id)
    }

    /// Opening an archived chat brings it back: it is a chat in use again.
    func openArchivedChat(id: UUID) {
        unarchiveChat(id: id)
        openChat(id: id)
    }

    func rename(id: UUID, to title: String) {
        core.chatHistory.rename(id: id, to: title)
    }

    /// The title the window and the sidebar show, a rename included.
    func title(of chat: AIChatState) -> String {
        core.chatHistory.conversation(id: chat.session.id)?.displayTitle ?? chat.session.title
    }

    func copyChat(id: UUID) {
        guard let markdown = markdownTranscript(of: id) else { return }
        Paster.copyPlainText(markdown.text)
        core.showMessage("Chat copied")
    }

    /// The same Markdown Copy Chat makes, written where the reader chooses.
    func exportChat(id: UUID) {
        guard let markdown = markdownTranscript(of: id) else { return }
        let panel = NSSavePanel()
        // A title may hold a slash or a colon, neither of which a file name can.
        panel.nameFieldStringValue = markdown.title.replacing(/[\/:]/, with: "-") + ".md"
        NSApp.activateOverFrontmost()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(markdown.text.utf8).write(to: url, options: .atomic)
        } catch {
            core.showMessage("The chat could not be exported.", tone: .danger)
        }
    }

    /// Live wherever a surface holds the chat, so an answer still arriving is included.
    private func markdownTranscript(of id: UUID) -> (title: String, text: String)? {
        guard let session = chats.holder(of: id)?.session ?? core.chatHistory.session(id: id)
        else { return nil }
        let title = core.chatHistory.conversation(id: id)?.displayTitle ?? session.title
        return (title, session.markdownTranscript(title: title))
    }

    func deleteChat(id: UUID) async {
        let title = core.chatHistory.conversation(id: id)?.displayTitle ?? "This chat"
        guard
            await core.confirm(
                title: "Delete chat?", message: "“\(title)” will be removed. This can't be undone.",
                symbol: "trash", confirmTitle: "Delete")
        else { return }
        removeChat(id: id)
    }

    /// Codex's retained thread goes too, so a deleted chat's research never outlives it.
    func removeChat(id: UUID) {
        core.codexSubscription.turns.discardConversation(id: id)
        chats.delete(id: id)
    }

    func deleteAllChats() async {
        guard
            await core.confirm(
                title: "Delete all chats?",
                message: "Every chat in the sidebar except pinned ones will be removed; "
                    + "archived chats are kept. This can't be undone.",
                symbol: "trash", confirmTitle: "Delete All")
        else { return }
        for conversation in core.chatHistory.conversations where !conversation.isPinned {
            core.codexSubscription.turns.discardConversation(id: conversation.id)
        }
        chats.deleteAll()
    }

    // MARK: - Waiting

    /// The one definition of on screen: the window in front on this chat, or Quick AI's screen up.
    func isOnScreen(_ chat: AIChatState) -> Bool {
        ChatPresence(
            windowVisible: window.isOnScreen, appActive: NSApp.isActive,
            paletteVisible: core.palette.isVisible, paletteOnQuickAI: core.palette.mode == .ai
        ).shows(chats.surface(of: chat))
    }

    func isOnScreen(chatID id: UUID) -> Bool {
        chats.holder(of: id).map(isOnScreen) ?? false
    }

    /// A notification's click: the window on that chat, where its dialog or question comes up.
    func openWaitingChat(id: UUID) {
        guard settings.aiEnabled else { return }
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        openChat(id: id)
        showWindow()
    }

    /// Idempotent; started with the feature and left running, since nothing waits while it is off.
    private func watchWaits() {
        guard presenceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        presenceObservers = [
            NSApplication.didBecomeActiveNotification, NSWindow.didChangeOcclusionStateNotification
        ].map { name in
            NotificationToken(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // Delivered on the main queue, which `queue: .main` guarantees.
                    MainActor.assumeIsolated { self?.releaseShownApprovals() }
                },
                center: center)
        }
        trackPresence()
        trackWaits()
    }

    /// Which chat each surface holds and whether the palette is on Quick AI; never a reply's text.
    private func trackPresence() {
        withObservationTracking {
            _ = chats.window
            _ = chats.quickAI
            _ = core.palette.isVisible
            _ = core.palette.mode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.trackPresence()
                self?.releaseShownApprovals()
            }
        }
    }

    private func releaseShownApprovals() {
        for chat in chats.live where chat.hasHeldApprovals && isOnScreen(chat) {
            chat.releaseApprovals()
        }
    }

    /// Re-read on every streaming flush, so only a wait that starts or ends reaches anything.
    private func trackWaits() {
        let current = withObservationTracking {
            liveWaits
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackWaits() }
        }
        guard current != chats.waits else { return }
        let changes = AgentWaitEpisodes.changes(from: chats.waits, to: current)
        chats.waits = current
        for id in changes.ended { core.agentNotifications.withdraw(chatID: id) }
        for (id, wait) in changes.started { notifyIfAway(id, wait) }
    }

    private var liveWaits: [UUID: AgentWait] {
        var current: [UUID: AgentWait] = [:]
        for chat in chats.live {
            if let wait = chat.awaiting { current[chat.session.id] = wait }
        }
        return current
    }

    /// Posted only for a chat off screen, so a dialog already in front is never announced too.
    private func notifyIfAway(_ id: UUID, _ wait: AgentWait) {
        guard core.aiSettings.notifiesWhenWaiting, let chat = chats.holder(of: id),
            !isOnScreen(chat)
        else { return }
        core.agentNotifications.post(
            AgentWaitNotice(
                wait: wait, chatID: id, chatTitle: title(of: chat),
                question: chat.pendingQuestion?.question.question,
                appName: Bundle.main.appDisplayName))
    }

    // MARK: - Titles

    /// Asked on the first send, again after an answer if that failed, and never over a rename.
    private func nameIfNeeded(_ chat: AIChatState) {
        let session = chat.session
        guard let conversation = core.chatHistory.conversation(id: session.id),
            conversation.customTitle == nil, conversation.generatedTitle == nil,
            let description = ChatTitle.description(of: session),
            naming[session.id] == nil
        else { return }
        let selection = model(for: chat)
        let servers = titleServers(for: chat, on: selection)
        naming[session.id] = Task {
            let title = await self.title(
                describing: description, with: selection, servers: servers)
            // Whoever cancelled already cleared the entry, which may now be a newer request's.
            guard !Task.isCancelled else { return }
            naming[session.id] = nil
            if let title { core.chatHistory.setGeneratedTitle(title, id: session.id) }
        }
    }

    /// Codex's list is fixed at launch, so a title borrows the reply's servers and may call none.
    private func titleServers(
        for chat: AIChatState, on selection: AIModelSelection?
    ) -> AIToolServerSession? {
        guard case .codex? = selection else { return nil }
        let scope = chat.session.messages.first { $0.role == .user }?.toolScope
        return toolServers(for: chat, scopedTo: scope).map { borrowed in
            AIToolServerSession(rounds: 1, servers: borrowed.servers) { _ in false }
        }
    }

    /// Claude's CLI names sessions itself; every other route is asked once, in a side request.
    private func title(
        describing description: String, with selection: AIModelSelection?,
        servers: AIToolServerSession?
    ) async -> String? {
        if case .claude? = selection, let title = await core.installedAI.claudeTitle(for: description) {
            return title
        }
        guard let selection,
            let provider = try? AIProviderFactory.make(
                selection: selection, settings: core.aiSettings,
                subscription: core.codexSubscription, installedAI: core.installedAI,
                toolServers: servers)
        else { return nil }
        let request = AIRequest(
            instructions: ChatTitle.instructions,
            messages: [AIMessage(role: .user, text: description)])
        var text = ""
        do {
            for try await event in provider.stream(request) {
                if case .text(let delta) = event { text += delta }
                if case .finished = event { break }
            }
        } catch {
            return nil
        }
        return ChatTitle.sanitize(text)
    }

    // MARK: - Either surface

    /// While the turn waits on a question, what was typed answers it rather than starting a turn.
    @discardableResult
    func send(_ input: String, in chat: AIChatState) -> Bool {
        guard settings.aiEnabled else { return false }
        if let question = chat.pendingQuestion {
            return chat.answerQuestion(question.answer(typing: input))
        }
        do {
            let address = MCPComposerAddress.parse(input, slugs: core.mcpCoordinator.slugs)
            let sent = chat.send(
                address.rest, using: try provider(for: chat, scopedTo: address.slug),
                model: model(for: chat), webSearch: webSearch(for: chat),
                instructions: instructions(for: chat), contextBudget: contextBudget(for: chat),
                toolScope: address.slug)
            // Named while the answer streams, so the sidebar has a title before the reply ends.
            if sent { nameIfNeeded(chat) }
            return sent
        } catch {
            chat.report(error.localizedDescription)
            return false
        }
    }

    /// The same question, asked of whichever model is selected now, of the server it named.
    func regenerate(in chat: AIChatState) {
        guard settings.aiEnabled else { return }
        let scope = chat.session.messages.last { $0.role == .user }?.toolScope
        do {
            chat.regenerate(
                using: try provider(for: chat, scopedTo: scope),
                model: model(for: chat), webSearch: webSearch(for: chat),
                instructions: instructions(for: chat), contextBudget: contextBudget(for: chat))
        } catch {
            chat.report(error.localizedDescription)
        }
    }

    /// The ⌘K menu's switch, offered only where the route searches and the rules allow it.
    func offersWebSearch(in chat: AIChatState) -> Bool {
        capabilities(for: chat).webSearch && gate.rules.decision(for: .webSearch) == .allow
    }

    func toggleWebSearch() {
        core.aiSettings.webSearchEnabled.toggle()
    }

    private func webSearch(for chat: AIChatState) -> Bool {
        core.aiSettings.webSearchEnabled && offersWebSearch(in: chat)
    }

    /// The system prompt switch withholds neither memory nor the mode: each has its own switch.
    private func instructions(for chat: AIChatState) -> String? {
        let prompt = AIInstructions.compose(
            preamble: preamble(for: chat), userPrompt: core.aiSettings.systemPrompt,
            isEnabled: core.aiSettings.systemPromptEnabled)
        let memory = readsMemory(in: chat)
            ? core.agentMemoryCoordinator.instructions(
                canForget: offersMemoryTools(in: chat), budget: memoryBudget(for: chat))
            : nil
        return AgentModeInstructions.appending(
            to: AgentMemoryInstructions.appending(memory, to: prompt), for: chat.agentScope.mode)
    }

    /// The agent's half rides only where the turn is offered tools, so a chat route never pays it.
    private func preamble(for chat: AIChatState) -> String {
        let model = model(for: chat)
        let turn = AIPreamble.Turn(
            isOnDevice: model?.isOnDevice == true,
            offersTools: capabilities(for: chat).tools && chat.agentScope.isEnabled,
            asksUser: model?.reachesBlitzTools == true
                && AgentPolicy.isOffered(.askUser, scope: chat.agentScope),
            offersChoices: core.aiSettings.choicesEnabled)
        let environment = AIPreamble.environment(
            now: Date(), calendar: .current, system: ProcessInfo.processInfo.operatingSystemVersion)
        return AIPreamble.text(for: turn, environment: environment)
    }

    /// Read Memory on Allow and the chat's Use Memory on; it is no tool, so every route reads it.
    private func readsMemory(in chat: AIChatState) -> Bool {
        AgentPolicy.readsMemory(rules: gate.rules, scope: chat.agentScope)
    }

    /// Whether this turn can call `memory_forget`, so the memory block mentions it only then.
    private func offersMemoryTools(in chat: AIChatState) -> Bool {
        capabilities(for: chat).tools && model(for: chat)?.reachesBlitzTools == true
            && gate.isOffered(.memoryWrite, in: chat)
    }

    private func memoryBudget(for chat: AIChatState) -> Int? {
        model(for: chat)?.isOnDevice == true ? AgentMemoryInstructions.onDeviceBudget : nil
    }

    /// A turn's route and its tools: a CLI with its own client is handed servers, others the loop.
    private func provider(for chat: AIChatState, scopedTo slug: String?) throws -> any AIProvider {
        guard model(for: chat)?.runsItsOwnTools == true else {
            return toolAware(try provider(for: chat), scopedTo: slug, in: chat)
        }
        return try provider(for: chat, toolServers: toolServers(for: chat, scopedTo: slug))
    }

    /// The same narrowing as `tools(for:scopedTo:)`, for a client that starts its own servers.
    private func toolServers(for chat: AIChatState, scopedTo slug: String?) -> AIToolServerSession? {
        guard capabilities(for: chat).tools, chat.agentScope.isEnabled else { return nil }
        let mcp = core.mcpCoordinator
        return AIToolServerSession(
            rounds: core.aiSettings.toolRounds.limit,
            hosted: slug == nil ? blitzHostedTools(for: chat) : .none,
            readsOnly: chat.agentScope.mode == .plan
        ) { @MainActor [weak self, weak chat] in
            guard let self, let chat else { return [] }
            return await mcp.toolServers(scopedTo: slug) { server in
                // A read-only call is Plan's ceiling, so a server refused even that is never listed.
                guard self.gate.isOffered(.mcp(server.slug, readOnly: true), in: chat) else {
                    return false
                }
                guard chat.agentScope.mode == .plan else { return true }
                let listed = await mcp.listTools(of: server)
                return self.gate.isOffered(.server(server.slug, listed: listed), in: chat)
            }
        } consent: { @MainActor [weak self, weak chat] call in
            guard let self, let chat else { return false }
            return await gate.authorize(call, in: chat) == nil
        }
    }

    /// Only chat wraps a route in the tool loop; a text rewrite has nothing to call.
    private func toolAware(
        _ provider: any AIProvider, scopedTo slug: String?, in chat: AIChatState
    ) -> any AIProvider {
        let tools = tools(for: chat, scopedTo: slug)
        guard capabilities(for: chat).tools, !tools.isEmpty else { return provider }
        let blitz = blitzHostedTools(for: chat).run
        // An `@server` turn sits Blitz's own tools out, and the chat's own have no gate to refuse.
        let asks = tools.contains { AskUserToolCatalog.handles($0.name) }
        let plans = tools.contains { PlanToolCatalog.handles($0.name) }
        return AIToolLoopProvider(
            base: provider, tools: tools, maxRounds: core.aiSettings.toolRounds.limit
        ) { @MainActor [weak self, weak chat] call in
            if AskUserToolCatalog.handles(call.name), !asks {
                return .failure(call.id, AskUserToolCatalog.notOffered)
            }
            if PlanToolCatalog.handles(call.name), !plans {
                return .failure(call.id, PlanToolCatalog.notOffered)
            }
            if Self.isBlitzTool(call.name) { return await blitz(call) }
            guard let self, let chat else { return .failure(call.id, "The chat was closed.") }
            return await runServerTool(call, in: chat)
        }
    }

    /// An MCP call on the loop route: the gate first, then the server Blitz holds open.
    private func runServerTool(_ call: AIToolCall, in chat: AIChatState) async -> AIToolResult {
        guard let route = MCPToolName.parse(call.name) else {
            return .failure(call.id, "That tool is no longer connected.")
        }
        let request = AIToolServerCall(handle: route.slug, tool: route.tool)
        if let refusal = await gate.authorize(request, in: chat) {
            return .failure(call.id, refusal.message(for: .mcp(route.slug)))
        }
        // A server's error is its own text too, so every answer it gives is fenced.
        return AIUntrustedText.wrap(await core.mcpCoordinator.invoke(call))
    }

    nonisolated private static func isBlitzTool(_ name: String) -> Bool {
        CalendarToolCatalog.handles(name) || ReminderToolCatalog.handles(name)
            || ShellToolCatalog.handles(name) || FileToolCatalog.handles(name)
            || WebFetchToolCatalog.handles(name) || SessionToolCatalog.handles(name)
            || OpenToolCatalog.handles(name) || ShortcutToolCatalog.handles(name)
            || SystemActionToolCatalog.handles(name) || WindowLayoutToolCatalog.handles(name)
            || ContactToolCatalog.handles(name) || NoteToolCatalog.handles(name)
            || ClipboardToolCatalog.handles(name) || SnippetToolCatalog.handles(name)
            || QuicklinkToolCatalog.handles(name) || ContextToolCatalog.handles(name)
            || MemoryToolCatalog.handles(name) || AskUserToolCatalog.handles(name)
            || PlanToolCatalog.handles(name)
    }

    /// Blitz's own tools for a client that hosts them, read again each turn it starts.
    private func blitzHostedTools(for chat: AIChatState) -> AIHostedTools {
        AIHostedTools { @MainActor [weak self, weak chat] in
            guard let self, let chat else { return [] }
            return blitzTools(for: chat)
        } run: { @MainActor [weak self, weak chat] call in
            guard let self, let chat else { return await AIHostedTools.none.run(call) }
            let result = await runHostedTool(call, in: chat)
            return AgentTool(builtInToolName: call.name)?.fenced(result) ?? result
        }
    }

    private func runHostedTool(_ call: AIToolCall, in chat: AIChatState) async -> AIToolResult {
        if AskUserToolCatalog.handles(call.name) { return await askUser(call, in: chat) }
        if PlanToolCatalog.handles(call.name) { return writePlan(call, in: chat) }
        if FileToolCatalog.handles(call.name) { return await runFileTool(call, in: chat) }
        if WebFetchToolCatalog.handles(call.name) { return await fetchWebPage(call, in: chat) }
        if SessionToolCatalog.handles(call.name) { return await runSessionTool(call, in: chat) }
        if OpenToolCatalog.handles(call.name) { return await openItem(call, in: chat) }
        if let routed = await runFeatureTool(call, in: chat) { return routed }
        guard let agentCall = AgentCall(toolCall: call) else {
            return await AIHostedTools.none.run(call)
        }
        return await runBlitzTool(call, authorize: gate.authorization(for: agentCall, in: chat))
    }

    /// Never past the gate: asking the reader is no capability, so it has no rule row to consult.
    private func askUser(_ call: AIToolCall, in chat: AIChatState) async -> AIToolResult {
        guard AgentPolicy.isOffered(.askUser, scope: chat.agentScope) else {
            return .failure(call.id, AskUserToolCatalog.notOffered)
        }
        let question: AskUserToolCatalog.Question
        do throws(AIToolArguments.Invalid) {
            question = try AskUserToolCatalog.question(arguments: call.arguments)
        } catch {
            return .failure(call.id, error.message)
        }
        guard let answer = await chat.ask(question) else {
            return .failure(call.id, AskUserToolCatalog.oneAtATime)
        }
        return AskUserToolCatalog.result(answer, to: question, callID: call.id)
    }

    /// Never past the gate either: a plan changes nothing until the reader carries it out.
    private func writePlan(_ call: AIToolCall, in chat: AIChatState) -> AIToolResult {
        guard AgentPolicy.isOffered(.writePlan, scope: chat.agentScope) else {
            return .failure(call.id, PlanToolCatalog.notOffered)
        }
        let plan: ChatPlan
        do throws(AIToolArguments.Invalid) {
            plan = try PlanToolCatalog.plan(arguments: call.arguments, now: Date())
        } catch {
            return .failure(call.id, error.message)
        }
        guard chat.writePlan(plan) else { return .failure(call.id, PlanToolCatalog.turnEnded) }
        return PlanToolCatalog.result(callID: call.id)
    }

    /// Each runner reads its call, then puts its own dialog to the gate before it acts.
    private func runBlitzTool(
        _ call: AIToolCall, authorize: AgentAuthorization
    ) async -> AIToolResult {
        if CalendarToolCatalog.handles(call.name) {
            return await core.calendarCoordinator.runTool(call, authorize: authorize)
        }
        if ReminderToolCatalog.handles(call.name) {
            return await core.remindersCoordinator.runTool(call, authorize: authorize)
        }
        if ShellToolCatalog.handles(call.name) {
            return await runShellCommand(call, authorize: authorize)
        }
        return await AIHostedTools.none.run(call)
    }

    /// `@server` narrows a turn further, but never past what the chat's tools menu switched off.
    private func tools(for chat: AIChatState, scopedTo slug: String?) -> [AITool] {
        guard chat.agentScope.isEnabled else { return [] }
        let servers = core.mcpCoordinator.tools(scopedTo: slug)
            .filter { gate.isOffered(AgentCall($0), in: chat) }
            .map(\.aiTool)
        // `@server` addresses one server, so Blitz's own tools sit that turn out.
        return slug == nil ? blitzTools(for: chat) + servers : servers
    }

    /// Exactly the rows the policy offers this chat; a denied tool is never shown to the model.
    private func blitzTools(for chat: AIChatState) -> [AITool] {
        let offered = { (tool: AgentTool) in self.gate.isOffered(tool, in: chat) }
        let now = Date()
        let mac: [AITool] =
            (offered(.openItems) ? OpenToolCatalog.tools() : [])
            + (offered(.shortcuts) ? ShortcutToolCatalog.tools() : [])
            + (offered(.systemActions) ? SystemActionToolCatalog.tools() : [])
            + (offered(.windowLayouts) ? WindowLayoutToolCatalog.tools() : [])
        let personal: [AITool] =
            (offered(.contactsRead) ? ContactToolCatalog.tools() : [])
            + NoteToolCatalog.tools(read: offered(.noteRead), append: offered(.noteWrite))
            + (offered(.clipboardRead) ? ClipboardToolCatalog.tools() : [])
            + core.snippetCoordinator.chatTools(read: offered(.snippetsRead))
            + core.quicklinkCoordinator.chatTools(read: offered(.snippetsRead))
            + ContextToolCatalog.tools(
                frontmostApp: offered(.frontmostApp), selectedText: offered(.selectedText),
                clipboard: offered(.currentClipboard))
        return core.calendarCoordinator.chatTools(
            read: offered(.calendarRead), write: offered(.calendarWrite), now: now)
            + core.remindersCoordinator.chatTools(
                read: offered(.remindersRead), write: offered(.remindersWrite), now: now)
            + (offered(.shell) ? ShellToolCatalog.tools() : [])
            + FileToolCatalog.tools(read: offered(.filesRead), write: offered(.filesWrite))
            + (offered(.webFetch) ? WebFetchToolCatalog.tools() : [])
            + mac
            + personal
            + SessionToolCatalog.tools(
                read: offered(.sessionsRead), archive: offered(.sessionsArchive))
            + (offered(.memoryWrite) ? MemoryToolCatalog.tools() : [])
            + (AgentPolicy.isOffered(.askUser, scope: chat.agentScope)
                ? AskUserToolCatalog.tools() : [])
            + (AgentPolicy.isOffered(.writePlan, scope: chat.agentScope)
                ? PlanToolCatalog.tools() : [])
    }

    private func runShellCommand(
        _ call: AIToolCall, authorize: AgentAuthorization
    ) async -> AIToolResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let request: ShellToolCatalog.Request
        do throws(AIToolArguments.Invalid) {
            request = try ShellToolCatalog.request(arguments: call.arguments, homeDirectory: home)
        } catch {
            return .failure(call.id, error.message)
        }
        let prompt = AgentPrompt.shell(
            command: request.command,
            summary: ShellToolCatalog.summary(of: request, homeDirectory: home))
        if let refusal = await authorize(prompt) { return .failure(call.id, refusal) }
        let result = ShellToolCatalog.result(await ShellToolRunner.run(request), callID: call.id)
        // A failed command still answers with its own output, which `AgentTool.fenced` passes over.
        return result.isError ? AIUntrustedText.wrap(result) : result
    }

    /// The gate weighs canonical paths, and the runner re-resolves them before it acts.
    private func runFileTool(_ call: AIToolCall, in chat: AIChatState) async -> AIToolResult {
        let (name, arguments) = (call.name, call.arguments)
        let prepared: FileToolRunner.Prepared
        switch await Task.detached(operation: {
            FileToolRunner.prepare(name: name, arguments: arguments)
        }).value {
        case .success(let ready): prepared = ready
        case .failure(let failure): return .failure(call.id, failure.message)
        }
        let tool = prepared.request.tool
        let agentCall = AgentCall.files(
            tool, paths: prepared.resolved.paths, homeDirectory: prepared.homeDirectory)
        // Before the disk is asked anything, so a denied path's existence is never told.
        guard gate.decision(for: agentCall, in: chat) != .deny else {
            return .failure(call.id, AgentRefusal.denied.message(for: tool))
        }
        if let failure = await Task.detached(operation: { FileToolRunner.preflight(prepared) })
            .value
        {
            return .failure(call.id, failure.message)
        }
        let prompt = FileToolCatalog.prompt(
            for: prepared.resolved, homeDirectory: prepared.homeDirectory)
        if let refusal = await gate.authorization(for: agentCall, in: chat)(prompt) {
            return .failure(call.id, refusal)
        }
        let denied = gate.rules.pathRules.filter { $0.decision == .deny && $0.applies(to: tool) }
        switch await Task.detached(operation: {
            FileToolRunner.run(prepared, deniedRules: denied)
        }).value {
        case .success(let answer):
            return AIToolResult(callID: call.id, content: answer, isError: false)
        case .failure(let failure): return .failure(call.id, failure.message)
        }
    }

    /// The gate weighs whether the URL is on the local network; the runner checks each redirect.
    private func fetchWebPage(_ call: AIToolCall, in chat: AIChatState) async -> AIToolResult {
        let request: WebFetchToolCatalog.Request
        do throws(AIToolArguments.Invalid) {
            request = try WebFetchToolCatalog.request(arguments: call.arguments)
        } catch {
            return .failure(call.id, error.message)
        }
        let prompt = WebFetchToolCatalog.prompt(for: request)
        if let refusal = await gate.authorization(for: request.agentCall, in: chat)(prompt) {
            return .failure(call.id, refusal)
        }
        switch await Task.detached(operation: { await WebFetchRunner.run(request) }).value {
        case .success(let answer):
            return AIToolResult(callID: call.id, content: answer, isError: false)
        case .failure(let failure): return .failure(call.id, failure.message)
        }
    }

    /// The Mac, personal, context and memory tools; a denied row refuses before anything is read.
    private func runFeatureTool(_ call: AIToolCall, in chat: AIChatState) async -> AIToolResult? {
        guard let row = AgentTool(builtInToolName: call.name),
            let run = featureRunner(for: call.name, in: chat)
        else { return nil }
        let agentCall = AgentCall(tool: row)
        guard gate.decision(for: agentCall, in: chat) != .deny else {
            return .failure(call.id, AgentRefusal.denied.message(for: row))
        }
        return await run(call, gate.authorization(for: agentCall, in: chat))
    }

    private typealias FeatureRunner =
        @MainActor (AIToolCall, AgentAuthorization) async -> AIToolResult

    /// Each runner reads its call, checks its feature's switch and puts its own dialog to the gate.
    private func featureRunner(for name: String, in chat: AIChatState) -> FeatureRunner? {
        if ShortcutToolCatalog.handles(name) { return core.appleShortcutCoordinator.runTool }
        if SystemActionToolCatalog.handles(name) { return core.systemActionCoordinator.runTool }
        if WindowLayoutToolCatalog.handles(name) { return core.windowLayoutCoordinator.runTool }
        if ContactToolCatalog.handles(name) { return core.contactsCoordinator.runTool }
        if NoteToolCatalog.handles(name) { return core.notesCoordinator.runTool }
        if ClipboardToolCatalog.handles(name) { return core.clipboardCoordinator.runTool }
        if SnippetToolCatalog.handles(name) { return core.snippetCoordinator.runTool }
        if QuicklinkToolCatalog.handles(name) { return core.quicklinkCoordinator.runTool }
        if MemoryToolCatalog.handles(name) {
            let (memory, conversation) = (core.agentMemoryCoordinator, chat.session.id)
            return { await memory.runTool($0, conversation: conversation, authorize: $1) }
        }
        guard ContextToolCatalog.handles(name) else { return nil }
        let apps = core.externalApps
        return { await ContextToolRunner.run($0, app: apps.app, authorize: $1) }
    }

    /// An app is named against the launcher's index; a path is weighed canonically, as files are.
    private func openItem(_ call: AIToolCall, in chat: AIChatState) async -> AIToolResult {
        let home = FileToolRunner.homeDirectory()
        let target: OpenToolCatalog.Target
        do throws(AIToolArguments.Invalid) {
            target = try OpenToolCatalog.target(arguments: call.arguments, homeDirectory: home)
        } catch {
            return .failure(call.id, error.message)
        }
        let bare = AgentCall(tool: .openItems)
        switch target {
        case .path(let path):
            return await openPath(path, homeDirectory: home, callID: call.id, in: chat)
        case .url(let url):
            let prompt = OpenToolCatalog.prompt(forURL: url)
            if let refusal = await gate.authorization(for: bare, in: chat)(prompt) {
                return .failure(call.id, refusal)
            }
            if let reason = await core.launcherCoordinator.openForAgent(url, isApplication: false) {
                let subject = url.absoluteString
                return .failure(call.id, OpenToolCatalog.notOpened(subject, reason: reason))
            }
            let answer = OpenToolCatalog.opened(url: url)
            return AIToolResult(callID: call.id, content: answer, isError: false)
        case .app(let name):
            // Before the index is asked, so a denied row never tells which apps are installed.
            guard gate.decision(for: bare, in: chat) != .deny else {
                return .failure(call.id, AgentRefusal.denied.message(for: .openItems))
            }
            let app: OpenToolCatalog.App
            do throws(AIToolArguments.Invalid) {
                app = try OpenToolCatalog.app(
                    named: name, in: core.launcherCoordinator.openToolApps())
            } catch {
                return .failure(call.id, error.message)
            }
            let prompt = OpenToolCatalog.prompt(forApp: app)
            if let refusal = await gate.authorization(for: bare, in: chat)(prompt) {
                return .failure(call.id, refusal)
            }
            let url = URL(fileURLWithPath: app.path)
            if let reason = await core.launcherCoordinator.openForAgent(url, isApplication: true) {
                return .failure(call.id, OpenToolCatalog.notOpened(app.name, reason: reason))
            }
            let answer = OpenToolCatalog.opened(app: app.name)
            return AIToolResult(callID: call.id, content: answer, isError: false)
        }
    }

    /// The gate weighs the path with its links resolved, and it is resolved again after asking.
    private func openPath(
        _ path: String, homeDirectory home: String, callID: String, in chat: AIChatState
    ) async -> AIToolResult {
        let resolved: String
        switch await Task.detached(operation: {
            OpenToolRunner.resolved(path, homeDirectory: home)
        }).value {
        case .success(let real): resolved = real
        case .failure(let failure): return .failure(callID, failure.message)
        }
        let agentCall = AgentCall.files(.openItems, paths: [resolved], homeDirectory: home)
        // Before the disk is asked anything else, so a denied path's existence is never told.
        guard gate.decision(for: agentCall, in: chat) != .deny else {
            return .failure(callID, AgentRefusal.denied.message(for: .openItems))
        }
        let kind: OpenToolCatalog.ItemKind
        switch await Task.detached(operation: {
            OpenToolRunner.inspect(resolved, homeDirectory: home)
        }).value {
        case .success(let found): kind = found
        case .failure(let failure): return .failure(callID, failure.message)
        }
        let prompt = OpenToolCatalog.prompt(forPath: resolved, kind: kind, homeDirectory: home)
        if let refusal = await gate.authorization(for: agentCall, in: chat)(prompt) {
            return .failure(callID, refusal)
        }
        if let failure = await Task.detached(operation: {
            OpenToolRunner.recheck(path, as: resolved, kind: kind, homeDirectory: home)
        }).value {
            return .failure(callID, failure.message)
        }
        let url = URL(fileURLWithPath: resolved)
        if let reason = await core.launcherCoordinator.openForAgent(url, isApplication: kind == .app) {
            let shown = FileToolCatalog.shown(resolved, homeDirectory: home)
            return .failure(callID, OpenToolCatalog.notOpened(shown, reason: reason))
        }
        let answer = OpenToolCatalog.opened(path: resolved, homeDirectory: home)
        return AIToolResult(callID: callID, content: answer, isError: false)
    }

    /// An id is looked up before asking, so a dialog never names a chat that is not there.
    private func runSessionTool(_ call: AIToolCall, in chat: AIChatState) async -> AIToolResult {
        let request: SessionToolCatalog.Request
        do throws(AIToolArguments.Invalid) {
            request = try SessionToolCatalog.request(name: call.name, arguments: call.arguments)
        } catch {
            return .failure(call.id, error.message)
        }
        let agentCall = AgentCall(tool: request.tool)
        // Before any id is looked up, so a denied row never tells which chats exist.
        guard gate.decision(for: agentCall, in: chat) != .deny else {
            return .failure(call.id, AgentRefusal.denied.message(for: request.tool))
        }
        let current = chat.session.id
        if let settled = settled(request, excluding: current) {
            return AIToolResult(callID: call.id, content: settled.message, isError: settled.isError)
        }
        let title = request.id.flatMap { history.conversation(id: $0)?.displayTitle }
        let prompt = SessionToolCatalog.prompt(for: request, title: title)
        if let refusal = await gate.authorization(for: agentCall, in: chat)(prompt) {
            return .failure(call.id, refusal)
        }
        // Again after the dialog: the chat may have been deleted, opened or pinned meanwhile.
        if let settled = settled(request, excluding: current) {
            return AIToolResult(callID: call.id, content: settled.message, isError: settled.isError)
        }
        return await answer(request, callID: call.id, excluding: current)
    }

    private func settled(
        _ request: SessionToolCatalog.Request, excluding current: UUID
    ) -> SessionToolEngine.Settled? {
        guard let id = request.id else { return nil }
        return SessionToolEngine.settled(
            request, conversation: history.conversation(id: id), current: current,
            isAnswering: chats.answeringIDs.contains(id), isOpen: chats.holder(of: id) != nil)
    }

    private func answer(
        _ request: SessionToolCatalog.Request, callID: String, excluding current: UUID
    ) async -> AIToolResult {
        let done = { (text: String) in AIToolResult(callID: callID, content: text, isError: false) }
        switch request {
        case .list(let scope, let query, let limit):
            let pool: [ChatConversation] =
                switch scope {
                case .recent: history.conversations
                case .archived: history.archived
                case .all: history.saved
                }
            return done(
                await Task.detached {
                    SessionToolEngine.listing(
                        pool, scope: scope, query: query, limit: limit, excluding: current)
                }.value)
        case .read(let id, let fromMessage, let limit):
            guard let conversation = history.conversation(id: id),
                let session = chats.holder(of: id)?.session ?? history.session(id: id)
            else { return .failure(callID, SessionToolCatalog.unknown(id)) }
            let (title, isArchived) = (conversation.displayTitle, conversation.isArchived)
            let transcript = await Task.detached {
                SessionToolEngine.transcript(
                    of: session, title: title, isArchived: isArchived, fromMessage: fromMessage,
                    limit: limit)
            }.value
            guard let transcript else {
                return .failure(
                    callID, SessionToolEngine.pastTheEnd(title, count: session.messages.count))
            }
            return done(transcript)
        case .archive(let id):
            let title = history.conversation(id: id)?.displayTitle ?? ""
            return chats.archive(id: id)
                ? done(SessionToolCatalog.archived(title))
                : .failure(callID, SessionToolCatalog.notSaved(title))
        case .unarchive(let id):
            let title = history.conversation(id: id)?.displayTitle ?? ""
            return history.unarchive(id)
                ? done(SessionToolCatalog.unarchived(title))
                : .failure(callID, SessionToolCatalog.notSaved(title))
        }
    }

    // MARK: - The session scope

    /// Built-in rows the composer's menu lists: only where this route carries Blitz's own tools.
    func listedBuiltInTools(for chat: AIChatState) -> [AgentTool] {
        guard model(for: chat)?.reachesBlitzTools == true else { return [] }
        return gate.listed(AgentTool.builtIn.filter(\.isHosted))
    }

    /// The servers the composer's menu lists; one the table denies is left out, like the model.
    func listedServers(for chat: AIChatState) -> [MCPServer] {
        let listed = Set(gate.listed(mcpServers.map { .mcp($0.slug) }))
        return mcpServers.filter { listed.contains(.mcp($0.slug)) }
    }

    /// Modes weigh Blitz's own tools and the plan they write, so a route without them has none.
    func offersModes(in chat: AIChatState) -> Bool {
        capabilities(for: chat).tools && model(for: chat)?.reachesBlitzTools == true
    }

    func setMode(_ mode: AgentMode, in chat: AIChatState) {
        chat.agentScope.mode = offersModes(in: chat) ? mode : .manual
    }

    func setToolsEnabled(_ enabled: Bool, in chat: AIChatState) {
        chat.agentScope.isEnabled = enabled
    }

    /// The tools menu's Use Memory, listed only while the table lets turns read memory at all.
    var offersMemorySwitch: Bool {
        gate.rules.decision(for: .memoryRead) == .allow
    }

    func setUsesMemory(_ uses: Bool, in chat: AIChatState) {
        chat.agentScope.usesMemory = uses
    }

    func toggleTool(_ tool: AgentTool, in chat: AIChatState) {
        chat.agentScope.toggle(tool)
    }

    /// Every enabled server, before the agent's rules have their say.
    private var mcpServers: [MCPServer] { core.mcpCoordinator.servers }

    func showAgentSettings() {
        settingsCoordinator.showSettings(tab: .agent)
    }

    /// The server a draft is addressed to, so the composer can show it as a chip while typing.
    func addressedServer(in draft: String) -> MCPServer? {
        MCPComposerAddress.parse(draft, slugs: core.mcpCoordinator.slugs).slug
            .flatMap { core.mcpCoordinator.server(slug: $0) }
    }

    func stopResponse(in chat: AIChatState) {
        chat.cancel()
    }

    /// A click on a waiting question's card: a single choice answers, a multi-select one toggles.
    func respond(_ input: ChatQuestionInput, in chat: AIChatState) {
        guard let question = chat.pendingQuestion else { return }
        switch input {
        case .choose(let option): chat.answerQuestion(question.answer(choosing: option))
        case .toggle(let option): chat.toggleQuestionOption(option)
        case .send: chat.answerQuestion(question.answer(typing: ""))
        }
    }

    /// The live plan's card: an edit is saved where the plan was written, and Execute leaves Plan.
    func respond(_ input: ChatPlanInput, in chat: AIChatState) {
        guard !chat.isStreaming else { return }
        switch input {
        case .save(let markdown):
            if chat.editPlan(markdown: markdown) == .unsaved {
                core.showMessage("The plan edit could not be saved.", tone: .danger)
            }
        case .execute(let mode):
            guard let live = chat.session.livePlan else { return }
            setMode(mode, in: chat)
            send(AgentModeInstructions.execute(live.written.plan), in: chat)
        }
    }

    func copyLastResponse(in chat: AIChatState) {
        guard let text = chat.lastAssistantText else { return }
        Paster.copyPlainText(text)
    }

    /// What the chat's model can take; the composer offers only what applies.
    func capabilities(for chat: AIChatState) -> AIModelCapabilities {
        switch model(for: chat) {
        case .appleIntelligence?: return .appleIntelligence
        case .codex?: return .codex
        case .claude?: return .claudeCommand
        case .openCode(let model, _)?:
            let images = core.installedAI.status(for: .openCode).models
                .contains { $0.id == model && $0.acceptsImages }
            return AIModelCapabilities(
                images: images, documents: false, webSearch: false, tools: false)
        case .grok?, .cursor?:
            return AIModelCapabilities.none
        case .api(let connection, let model, _)?:
            return core.aiSettings.connection(id: connection)?.capabilities(for: model)
                ?? AIModelCapabilities.none
        case nil: return AIModelCapabilities.none
        }
    }

    /// How much history the chat's route can hold; the on-device window is far smaller.
    func contextBudget(for chat: AIChatState) -> Int {
        model(for: chat)?.isOnDevice == true
            ? AppleIntelligence.contextBudget : ChatSession.defaultTextBudget
    }

    /// The context card's facts; the gauge redraws per flush, so it skips what only the card shows.
    func contextReport(for chat: AIChatState, detailed: Bool = true) -> ChatContextReport {
        let session = chat.session
        let budget = contextBudget(for: chat)
        return ChatContextReport(
            modelTitle: detailed ? selectedModelTitle(for: chat) : "",
            historyBytes: session.historyBytes, budget: budget,
            sentMessages: session.sentMessageCount(textBudget: budget),
            totalMessages: session.historyMessages.count,
            stagedFiles: chat.pendingAttachments.count,
            stagedBytes: chat.pendingAttachments.reduce(0) { $0 + $1.payload.byteCount },
            usage: chat.usage,
            systemPrompt: core.aiSettings.systemPromptEnabled,
            webSearch: webSearch(for: chat),
            memories: detailed ? carriedMemories(for: chat) : nil,
            mode: offersModes(in: chat) ? chat.agentScope.mode : nil,
            tools: detailed ? toolRows(for: chat) : [])
    }

    /// Nil while the turn carries no memory at all.
    private func carriedMemories(for chat: AIChatState) -> Int? {
        guard readsMemory(in: chat) else { return nil }
        return core.agentMemoryCoordinator.carried(
            canForget: offersMemoryTools(in: chat), budget: memoryBudget(for: chat)
        ).count
    }

    /// What a call to each tool the next turn is offered would do, in the menu's order.
    private func toolRows(for chat: AIChatState) -> [ChatContextReport.ToolRow] {
        guard capabilities(for: chat).tools else { return [] }
        let servers = mcpServers
        let mcp = core.mcpCoordinator
        let calls =
            listedBuiltInTools(for: chat).map { AgentCall(tool: $0) }
            + servers.map { AgentCall.server($0.slug, listed: mcp.listedTools(slug: $0.slug)) }
        return gate.decisions(for: calls, in: chat).map { row in
            guard case .mcp(let slug) = row.tool else {
                return ChatContextReport.ToolRow(title: row.tool.title, decision: row.decision)
            }
            let title = servers.first { $0.slug == slug }?.title ?? slug
            return ChatContextReport.ToolRow(title: title, decision: row.decision)
        }
    }

    // MARK: - Attachments

    /// ⌘V stages a file, read off-main; false hands the chord back to the field editor.
    func attachPastedFile(files: [URL], to chat: AIChatState) -> Bool {
        let pasteboard = NSPasteboard.general
        // Copied text often carries a TIFF too; only a board with no string is a picture.
        let pasted =
            files.isEmpty && pasteboard.string(forType: .string) == nil
            ? pasteboard.availableType(from: [.png, .tiff]).flatMap { pasteboard.data(forType: $0) }
            : nil
        guard !files.isEmpty || pasted != nil else { return false }
        if let refusal = unattachable(files, in: chat) {
            core.showMessage(refusal.message, tone: .neutral)
            return true
        }
        if pasted != nil, !capabilities(for: chat).images {
            core.showMessage(ChatAttachmentRefusal.imagesUnsupported.message, tone: .neutral)
            return true
        }
        stage(files: files, pasted: pasted, into: chat)
        return true
    }

    /// A drop or the paperclip: the same refusals as a paste, since the route is what decides.
    func attach(files: [URL], to chat: AIChatState) {
        let files = files.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let refusal = unattachable(files, in: chat) {
            core.showMessage(refusal.message, tone: .neutral)
            return
        }
        stage(files: files, pasted: nil, into: chat)
    }

    /// An accessory app must activate first, or the panel opens behind the frontmost app.
    func chooseFiles(for chat: AIChatState) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose images, PDFs or text files to send with your next message."
        NSApp.activateOverFrontmost()
        guard panel.runModal() == .OK else { return }
        attach(files: panel.urls, to: chat)
    }

    func clearAttachments(in chat: AIChatState) {
        chat.clearAttachments()
    }

    func removeAttachment(_ id: UUID, in chat: AIChatState) {
        chat.removeAttachment(id)
    }

    /// The first refusal the current route forces, so a paste explains itself rather than dropping.
    private func unattachable(_ files: [URL], in chat: AIChatState) -> ChatAttachmentRefusal? {
        let can = capabilities(for: chat)
        for file in files {
            guard let kind = AIAttachmentPolicy.kind(forFileName: file.lastPathComponent) else {
                return .unsupported(file.pathExtension.lowercased())
            }
            switch kind {
            case .image where !can.images: return .imagesUnsupported
            case .pdf where !can.documents: return .documentsUnsupported
            default: continue
            }
        }
        return nil
    }

    /// Files first, raw bytes as fallback; the chord is consumed, never pasting a path.
    private func stage(files: [URL], pasted: Data?, into chat: AIChatState) {
        let generation = chat.stagingGeneration
        Task { [weak self, weak chat] in
            let read = await Task.detached(priority: .userInitiated) {
                () -> [ChatAttachmentReader.Outcome] in
                if !files.isEmpty { return files.map(ChatAttachmentReader.read) }
                return pasted.map { [ChatAttachmentReader.image($0)] } ?? []
            }.value
            guard let self, let chat else { return }
            guard generation == chat.stagingGeneration else {
                core.showMessage(
                    "That file was still loading and did not make it into the chat.",
                    tone: .neutral)
                return
            }
            // Stops at the first refusal so a mixed paste says which file it could not take.
            for outcome in read {
                switch outcome {
                case .failed(let refusal):
                    core.showMessage(refusal.message, tone: .neutral)
                    return
                case .staged(let item):
                    let attachment = ChatAttachment(
                        payload: item.payload, name: item.name, preview: item.preview)
                    if let refusal = chat.attach(attachment) {
                        core.showMessage(refusal.message, tone: .neutral)
                        return
                    }
                }
            }
        }
    }

    // MARK: - Models

    var modelOptions: [AIModelOption] {
        modelGroups.flatMap(\.options)
    }

    var isModelCatalogLoading: Bool {
        core.aiSettings.enabledInstalledProviders.contains { kind in
            switch kind {
            case .codex: core.codexSubscription.phase == .starting
            case .claude, .grok, .openCode, .cursor:
                core.installedAI.status(for: kind).phase == .checking
            }
        }
    }

    var modelGroups: [AIModelOptionGroup] {
        AIModelOption.availableGroups(
            settings: core.aiSettings, subscription: core.codexSubscription,
            installedAI: core.installedAI)
    }

    /// The chat's own model while it is still reachable; otherwise the default a new chat takes.
    func model(for chat: AIChatState) -> AIModelSelection? {
        if let own = chat.session.model, isReachable(own) { return own }
        return core.aiSettings.defaultModel
    }

    /// A route removed in Settings falls back to the default rather than failing the chat.
    private func isReachable(_ selection: AIModelSelection) -> Bool {
        switch selection {
        case .appleIntelligence:
            return true
        case .api(let connection, let model, _):
            return core.aiSettings.connection(id: connection)?.models.contains(model) == true
        case .codex, .claude, .grok, .openCode, .cursor:
            return selection.source.installedKind.map {
                core.aiSettings.enabledInstalledProviders.contains($0)
            } ?? false
        }
    }

    private func provider(
        for chat: AIChatState, toolServers: AIToolServerSession? = nil
    ) throws -> any AIProvider {
        guard let selection = model(for: chat) else {
            throw AIProviderError.unavailable("Choose a default AI model in Settings.")
        }
        return try AIProviderFactory.make(
            selection: selection, settings: core.aiSettings,
            subscription: core.codexSubscription, installedAI: core.installedAI,
            toolServers: toolServers)
    }

    /// Blitz runs a local server itself only while some live chat's route cannot.
    var everyChatRunsItsOwnTools: Bool {
        chats.live.allSatisfy { model(for: $0)?.runsItsOwnTools == true }
    }

    func selectedModelTitle(for chat: AIChatState) -> String {
        modelTitle(of: model(for: chat), among: modelOptions)
    }

    /// Shortened here, not by layout: a flexible label would take the row from the search field.
    func modelTitle(of selected: AIModelSelection?, among options: [AIModelOption]) -> String {
        guard let selected else { return "Choose Model" }
        let title = options.first { $0.matches(selected) }?.title ?? selected.model
        guard title.count > Self.maxModelTitleLength else { return title }
        let keep = Self.maxModelTitleLength / 2
        return "\(title.prefix(keep))…\(title.suffix(keep))"
    }

    private static let maxModelTitleLength = 26

    func selectedModelIcon(for chat: AIChatState) -> PopoverMenuIcon {
        modelIcon(of: model(for: chat))
    }

    /// From the selection, not the loaded list: the list arrives after the picker first paints.
    func modelIcon(of selected: AIModelSelection?) -> PopoverMenuIcon {
        switch selected {
        case .appleIntelligence?: return AIModelOption.appleIntelligenceIcon
        case .codex?: return .asset(AIBrand.openAI.assetName)
        case .claude?: return .asset(AIBrand.claude.assetName)
        case .grok?: return .asset(AIBrand.grok.assetName)
        case .cursor?: return AIModelOption.cursorIcon
        case .openCode(let model, _)?: return AIModelOption.icon(AIBrand.resolve(model: model))
        case .api(let connection, let model, _)?:
            return AIModelOption.icon(
                core.aiSettings.connection(id: connection).flatMap {
                    AIBrand.resolve(provider: $0.provider, model: model)
                })
        case nil: return AIModelOption.icon(nil)
        }
    }

    /// What entering chat costs once: the model list resolved, and the servers connected.
    func prepareForChat() {
        warmUpModelList()
        core.mcpCoordinator.warmUp()
    }

    /// Fetches the list so the title is a name, and a default can resolve without Settings.
    func warmUpModelList() {
        guard let stored = core.aiSettings.defaultModel else {
            prepareModelSwitcher()
            core.aiSettings.resolveDefaultModel()
            return
        }
        // Only an installed route needs checking; every other one is already settled on disk.
        if stored.source.installedKind != nil { prepareModelSwitcher() }
    }

    /// The chat keeps the pick; the default follows it, so the next new chat starts there too.
    func selectModel(_ option: AIModelOption, in chat: AIChatState) {
        let selection = AIModelOption.withDefaultEffort(
            option.selection, settings: core.aiSettings,
            subscription: core.codexSubscription, installedAI: core.installedAI)
        chat.setModel(selection)
        core.aiSettings.select(selection)
        // The picker leaves with the route, and a mode nobody can see must not keep applying.
        if !offersModes(in: chat) { chat.agentScope.mode = .manual }
    }

    func reasoningEfforts(for chat: AIChatState) -> [ChatGPTSubscription.Effort] {
        AIModelOption.efforts(
            for: model(for: chat), settings: core.aiSettings,
            subscription: core.codexSubscription, installedAI: core.installedAI)
    }

    func selectedReasoningTitle(for chat: AIChatState) -> String {
        guard let selected = model(for: chat)?.effort,
            let effort = reasoningEfforts(for: chat).first(where: { $0.id == selected })
        else { return "Reasoning" }
        return effort.title
    }

    func selectReasoningEffort(_ effort: ChatGPTSubscription.Effort, in chat: AIChatState) {
        guard let selection = model(for: chat)?.withEffort(effort.id) else { return }
        chat.setModel(selection)
        core.aiSettings.select(selection)
    }

    @discardableResult
    func prepareModelSwitcher() -> Task<Void, Never> {
        core.applyInstalledAILifecycle()
    }

    func showSettings() {
        openSettings(on: .ai)
    }

    /// For an empty model list, where what is missing is a provider rather than the switch.
    func showProviderSettings() {
        openSettings(on: .aiProviders)
    }

    private func openSettings(on tab: SettingsTab) {
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        settingsCoordinator.showSettings(tab: tab)
    }

    func availability(for chat: AIChatState) -> String? {
        do {
            _ = try provider(for: chat)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// What the context card lays out; history is counted in bytes, the unit the budget is kept in.
struct ChatContextReport: Equatable {
    let modelTitle: String
    let historyBytes: Int
    let budget: Int
    let sentMessages: Int
    let totalMessages: Int
    let stagedFiles: Int
    let stagedBytes: Int
    let usage: AIUsage?
    let systemPrompt: Bool
    let webSearch: Bool
    /// How many memories the next turn carries; nil when it carries none, as with Read Memory off.
    let memories: Int?
    /// Nil where the route reaches none of Blitz's tools, so it has no mode to be in.
    let mode: AgentMode?
    /// Each tool the next turn is offered; left empty for the gauge alone.
    let tools: [ToolRow]

    struct ToolRow: Equatable {
        let title: String
        let decision: AgentDecision
    }

    /// The model's own window when the route reported one; otherwise Blitz's history budget.
    var fill: Double {
        if let tokens = usage?.contextTokens, let window = usage?.contextWindow, window > 0 {
            return Double(tokens) / Double(window)
        }
        return Double(historyBytes) / Double(max(budget, 1))
    }

    var accessibilitySummary: String {
        let percent = fill.formatted(.percent.precision(.fractionLength(0)))
        return "Context \(percent), \(sentMessages) of \(totalMessages) messages sent"
    }
}
