import Foundation

/// The plan a Plan turn wrote for its chat; a later `write_plan` replaces it whole.
struct ChatPlan: Hashable, Sendable {
    var title: String
    var markdown: String
    var updatedAt: Date
}
