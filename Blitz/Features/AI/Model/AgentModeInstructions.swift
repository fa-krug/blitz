import Foundation

/// What a mode adds to a turn's instructions, and the message that carries a plan out.
enum AgentModeInstructions {
    static let plan =
        "You are in Plan mode. Investigate without changing anything: read, search and run only "
        + "commands that look, never ones that change files, settings or anything else. If the "
        + "user only asked a question, answer it; no plan is needed. Otherwise, where the user's "
        + "answer would change the plan, ask with \(AskUserToolCatalog.askUserName). When the "
        + "plan is complete, call \(PlanToolCatalog.writePlanName) with a short title and the "
        + "plan in Markdown, naming the steps, what each one changes and how to check it worked, "
        + "then stop. Never start carrying the plan out: the user decides whether to run it."

    /// Nil where a mode adds nothing to the turn.
    static func instruction(for mode: AgentMode) -> String? {
        switch mode {
        case .manual, .auto: nil
        case .plan: plan
        }
    }

    /// After whatever the turn already carries, so Plan holds with the system prompt switched off.
    static func appending(to instructions: String?, for mode: AgentMode) -> String? {
        guard let added = instruction(for: mode) else { return instructions }
        guard let instructions, !instructions.isEmpty else { return added }
        return instructions + "\n\n" + added
    }

    /// The plan's current text, which the reader may have edited since the model wrote it.
    static func execute(_ plan: ChatPlan) -> String {
        "Carry out this plan: \(plan.title)\n\n\(plan.markdown)"
    }
}
