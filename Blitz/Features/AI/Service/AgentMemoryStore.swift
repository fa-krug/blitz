import Foundation
import Observation

/// The agent's memories, oldest first, in one small JSON file no backup or settings file carries.
@MainActor
@Observable
final class AgentMemoryStore {
    private(set) var memories: [AgentMemory] = []
    private(set) var isLoaded = false
    /// False once the file would not decode: it holds the user's words, so it is never replaced.
    private(set) var isAvailable = true

    @ObservationIgnored private let fileURL: URL
    /// Only ever grows, so an id the model saw once never names a later memory.
    @ObservationIgnored private var nextID = 1

    private struct Stored: Codable {
        var nextID: Int
        var memories: [AgentMemory]
    }

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("agent-memory.json")
    }

    /// Once; a missing file is an empty memory, and nothing is written until something is kept.
    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            isAvailable = false
            return
        }
        memories = stored.memories.sorted { $0.id < $1.id }
        nextID = max(stored.nextID, (memories.map(\.id).max() ?? 0) + 1)
    }

    func memory(id: Int) -> AgentMemory? {
        memories.first { $0.id == id }
    }

    func admission(of text: String, replacing id: Int? = nil) -> AgentMemory.Admission {
        AgentMemory.admission(of: text, into: memories, replacing: id)
    }

    /// Nil when the text is not admitted or the file could not be written.
    @discardableResult
    func add(_ text: String, from conversation: UUID?, at now: Date = Date()) -> AgentMemory? {
        guard case .accepted(let cleaned) = admission(of: text) else { return nil }
        let memory = AgentMemory(
            id: nextID, text: cleaned, createdAt: now, sourceConversation: conversation)
        return commit(memories + [memory], nextID: nextID + 1) ? memory : nil
    }

    /// Keeps the memory's id and date, so the model's earlier mention of it still names it.
    @discardableResult
    func update(id: Int, text: String) -> Bool {
        guard let index = memories.firstIndex(where: { $0.id == id }),
            case .accepted(let cleaned) = admission(of: text, replacing: id)
        else { return false }
        var updated = memories
        updated[index].text = cleaned
        return commit(updated, nextID: nextID)
    }

    @discardableResult
    func remove(id: Int) -> Bool {
        guard memory(id: id) != nil else { return false }
        return commit(memories.filter { $0.id != id }, nextID: nextID)
    }

    @discardableResult
    func removeAll() -> Bool {
        commit([], nextID: nextID)
    }

    private func commit(_ updated: [AgentMemory], nextID: Int) -> Bool {
        guard isLoaded, isAvailable else { return false }
        do {
            let data = try JSONEncoder().encode(Stored(nextID: nextID, memories: updated))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return false
        }
        memories = updated
        self.nextID = nextID
        return true
    }
}
