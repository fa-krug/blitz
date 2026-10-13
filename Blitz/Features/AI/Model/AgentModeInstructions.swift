import Foundation

/// What a mode adds to a turn's instructions, and the message that carries a plan out.
enum AgentModeInstructions {
    static let plan =
        "You are in Plan mode. Investigate without changing anything: read, search and run only "
        + "commands that look, never ones that change files, settings or anything else. Where "
        + "the user's answer would change the plan, ask with \(AskUserToolCatalog.askUserName). "
        + "When the plan is complete, call \(PlanToolCatalog.writePlanName) with a short title "
        + "and the plan in Markdown, then stop. Never start carrying the plan out: the user "
        + "decides whether to run it."

    /// Nil where a mode adds nothing to the turn.
    static func instruction(for mode: AgentMode) -> String? {
        switch mode {
        case .manual, .auto: nil
        case .plan: plan
        }
    }

    /// The plan's current text, which the reader may have edited since the model wrote it.
    static func execute(_ plan: ChatPlan) -> String {
        "Carry out this plan: \(plan.title)\n\n\(plan.markdown)"
    }
}
