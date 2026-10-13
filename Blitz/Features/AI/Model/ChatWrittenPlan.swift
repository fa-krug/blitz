import Foundation

/// A plan a reply wrote with `write_plan`, pinned where it was written like a question or a call.
struct ChatWrittenPlan: Hashable, Sendable {
    /// As the reader last saved it, which may no longer be what the model wrote.
    var plan: ChatPlan
    /// Characters of reply text that had arrived when the plan was written.
    let textOffset: Int
    let sequence: Int
}
