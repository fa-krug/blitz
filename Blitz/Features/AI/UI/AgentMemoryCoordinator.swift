import Foundation

/// The agent's memory: what each turn carries, its two tools, and Settings → AI → Memory.
@MainActor
final class AgentMemoryCoordinator {
    private let store: AgentMemoryStore
    private let settings: AppSettings
    /// Dialogs and the HUD, so both stay owned by `AppCore`.
    private unowned let core: AppCore

    init(store: AgentMemoryStore, settings: AppSettings, core: AppCore) {
        self.store = store
        self.settings = settings
        self.core = core
    }

    /// Oldest first; read through the store, so a view that lists them follows every change.
    var memories: [AgentMemory] { store.memories }
    var isLoaded: Bool { store.isLoaded }

    /// Only with AI on: off means nothing of the feature is read.
    func load() {
        guard settings.aiEnabled else { return }
        store.load()
    }

    /// What the context card counts; it never loads, since a view's body asks it.
    func carried(canForget: Bool, budget: Int?) -> [AgentMemory] {
        AgentMemoryInstructions.carried(store.memories, canForget: canForget, budget: budget)
    }

    func instructions(canForget: Bool, budget: Int?) -> String? {
        load()
        return AgentMemoryInstructions.block(store.memories, canForget: canForget, budget: budget)
    }

    // MARK: - The tools

    /// The row's Deny is the caller's to check first; this reads, settles, asks, then acts.
    func runTool(
        _ call: AIToolCall, conversation: UUID, authorize: AgentAuthorization
    ) async -> AIToolResult {
        let request: MemoryToolCatalog.Request
        do throws(AIToolArguments.Invalid) {
            request = try MemoryToolCatalog.request(name: call.name, arguments: call.arguments)
        } catch {
            return .failure(call.id, error.message)
        }
        load()
        guard store.isAvailable else { return .failure(call.id, MemoryToolCatalog.notSaved) }
        if let settled = MemoryToolCatalog.settled(request, memories: store.memories) {
            return AIToolResult(callID: call.id, content: settled.message, isError: settled.isError)
        }
        guard let prompt = MemoryToolCatalog.prompt(for: request, memories: store.memories) else {
            return .failure(call.id, MemoryToolCatalog.notSaved)
        }
        let shown: AgentMemory? =
            switch request {
            case .remember: nil
            case .forget(let target): MemoryToolCatalog.memory(for: target, in: store.memories)
            }
        if let refusal = await authorize(prompt) { return .failure(call.id, refusal) }
        // Again after the dialog: Settings may have added, edited or forgotten one meanwhile.
        if let settled = MemoryToolCatalog.settled(request, memories: store.memories) {
            return AIToolResult(callID: call.id, content: settled.message, isError: settled.isError)
        }
        switch request {
        case .remember(let text):
            guard let memory = store.add(text, from: conversation) else {
                return .failure(call.id, MemoryToolCatalog.notSaved)
            }
            return AIToolResult(
                callID: call.id, content: MemoryToolCatalog.remembered(memory), isError: false)
        case .forget(let target):
            guard let memory = MemoryToolCatalog.memory(for: target, in: store.memories),
                let shown
            else { return .failure(call.id, MemoryToolCatalog.notSaved) }
            guard memory == shown else {
                return .failure(call.id, MemoryToolCatalog.changed(shown))
            }
            guard store.remove(id: memory.id) else {
                return .failure(call.id, MemoryToolCatalog.notSaved)
            }
            return AIToolResult(
                callID: call.id, content: MemoryToolCatalog.forgot(memory), isError: false)
        }
    }

    // MARK: - Settings

    /// False leaves the reader's text in the field: a refusal says why on the HUD.
    @discardableResult
    func add(_ text: String) -> Bool {
        load()
        let admission = store.admission(of: text)
        if admission == .empty { return false }
        if let refusal = refusal(for: admission) {
            core.showMessage(refusal, tone: .neutral)
            return false
        }
        guard store.add(text, from: nil) != nil else {
            core.showMessage(Self.notSaved, tone: .danger)
            return false
        }
        return true
    }

    /// A blank edit changes nothing: forgetting is the row's own button.
    @discardableResult
    func update(id: Int, text: String) -> Bool {
        let admission = store.admission(of: text, replacing: id)
        if admission == .empty { return true }
        if let refusal = refusal(for: admission) {
            core.showMessage(refusal, tone: .neutral)
            return false
        }
        guard store.update(id: id, text: text) else {
            core.showMessage(Self.notSaved, tone: .danger)
            return false
        }
        return true
    }

    func remove(id: Int) {
        if !store.remove(id: id) { core.showMessage(Self.notSaved, tone: .danger) }
    }

    func forgetAll() async {
        let count = store.memories.count
        guard count > 0,
            await core.confirm(
                title: "Forget everything?",
                message: "The agent forgets all \(count == 1 ? "1 memory" : "\(count) memories"). "
                    + "This can't be undone.",
                symbol: AgentTool.memoryRead.symbolName, confirmTitle: "Forget All")
        else { return }
        if !store.removeAll() { core.showMessage(Self.notSaved, tone: .danger) }
    }

    private static let notSaved = "Memory could not be saved."

    private func refusal(for admission: AgentMemory.Admission) -> String? {
        switch admission {
        case .accepted, .empty: nil
        case .duplicate(let twin): "That is already remembered as \(twin.handle)."
        case .full: "Memory is full. Forget something first."
        case .tooLong: "A memory holds at most \(AgentMemory.textLimit) characters."
        }
    }
}
