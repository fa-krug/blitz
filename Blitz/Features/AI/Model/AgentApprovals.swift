import Foundation

/// A chat's open Ask requests, and those held until the chat is on screen; each ends once.
struct AgentApprovals<Waiter> {
    private var pending: [UUID] = []
    private var held: [(id: UUID, waiter: Waiter)] = []

    var count: Int { pending.count }
    var hasHeld: Bool { !held.isEmpty }

    mutating func begin() -> UUID {
        let id = UUID()
        pending.append(id)
        return id
    }

    func isPending(_ id: UUID) -> Bool {
        pending.contains(id)
    }

    /// False refuses a request already ended or already held; its waiter is told no at once.
    mutating func hold(_ id: UUID, _ waiter: Waiter) -> Bool {
        guard isPending(id), !held.contains(where: { $0.id == id }) else { return false }
        held.append((id, waiter))
        return true
    }

    /// The chat came on screen: every held waiter goes on, oldest first.
    mutating func release() -> [Waiter] {
        defer { held = [] }
        return held.map(\.waiter)
    }

    /// One held waiter taken back, as when the task waiting on it is cancelled.
    mutating func unhold(_ id: UUID) -> Waiter? {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return nil }
        return held.remove(at: index).waiter
    }

    /// The request is over; a waiter still held comes back to be told no.
    mutating func end(_ id: UUID) -> Waiter? {
        pending.removeAll { $0 == id }
        return unhold(id)
    }

    /// Stop, delete or clear: every request ends, and every held waiter comes back to be told no.
    mutating func endAll() -> [Waiter] {
        pending = []
        return release()
    }
}
