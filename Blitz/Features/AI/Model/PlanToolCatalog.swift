import Foundation

/// How a Plan turn hands its finished plan to the chat, and what the model is told afterwards.
enum PlanToolCatalog {
    static let origin = "Agent"
    static let writePlanName = "write_plan"
    static let titleLimit = 120
    /// UTF-8 bytes: the plan is stored with the chat and sent back whole when it is carried out.
    static let markdownLimit = 32 * 1024
    static let resultText =
        "The plan is shown to the user. Stop here; do not start carrying it out."
    static let notOffered = "Writing a plan is only available in Plan mode."
    static let turnEnded = "The turn had already ended, so the plan was not shown."

    private typealias Invalid = AIToolArguments.Invalid

    static func handles(_ name: String) -> Bool {
        name == writePlanName
    }

    static func tools() -> [AITool] {
        let write = AITool(
            name: writePlanName,
            description: "Show the user your plan once it is complete. Calling it again replaces "
                + "the plan. The user reads it and decides whether to carry it out, so write "
                + "every step needed to do so, in Markdown, under \(markdownLimit / 1024) KB.",
            parameters: AIToolJSON.object(
                properties: [
                    "title": AIToolJSON.string("A short name for the plan."),
                    "markdown": AIToolJSON.string("The plan itself, in Markdown.")
                ],
                required: ["title", "markdown"]),
            origin: origin, title: "Write Plan", showsCallRow: false)
        return [write]
    }

    static func plan(arguments: String, now: Date) throws(AIToolArguments.Invalid) -> ChatPlan {
        let arguments = try AIToolArguments(arguments)
        let title = try arguments.requiredString("title")
        let markdown = try arguments.requiredString("markdown")
        guard title.count <= titleLimit else {
            throw Invalid("Keep the title under \(titleLimit) characters.")
        }
        let size = markdown.utf8.count
        guard size <= markdownLimit else {
            throw Invalid(
                "Keep the plan under \(markdownLimit / 1024) KB; this one is "
                    + "\((size + 1023) / 1024) KB. Shorten it and call \(writePlanName) again.")
        }
        return ChatPlan(title: title, markdown: markdown, updatedAt: now)
    }

    static func result(callID: String) -> AIToolResult {
        AIToolResult(callID: callID, content: resultText, isError: false)
    }

    /// How later turns read the plan, set into the reply's text where it was written.
    static func record(_ plan: ChatPlan) -> String {
        "\(writePlanName): \(plan.title)\n\(plan.markdown)"
    }
}
