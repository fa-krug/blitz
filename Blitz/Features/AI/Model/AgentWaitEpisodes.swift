import Foundation

/// Where each chat's waits begin and end, so a wait posts one notification and withdraws it once.
enum AgentWaitEpisodes {
    struct Changes: Equatable {
        var started: [UUID: AgentWait] = [:]
        var ended: Set<UUID> = []
    }

    /// A wait that changes kind ends and starts again, since its notification says the old kind.
    static func changes(from old: [UUID: AgentWait], to new: [UUID: AgentWait]) -> Changes {
        var changes = Changes()
        for (id, wait) in old where new[id] != wait {
            changes.ended.insert(id)
        }
        for (id, wait) in new where old[id] != wait {
            changes.started[id] = wait
        }
        return changes
    }
}
