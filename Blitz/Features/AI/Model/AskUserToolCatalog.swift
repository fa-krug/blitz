import Foundation

/// How a chat model asks the reader a question, and how the reader's answer is spelled back to it.
enum AskUserToolCatalog {
    static let origin = "Agent"
    static let askUserName = "ask_user"
    static let optionCount = 2...6
    /// A chip, not a paragraph: anything longer belongs in the question.
    static let optionLimit = 80

    private typealias Invalid = AIToolArguments.Invalid

    /// A call, already checked; `options` are trimmed, non-empty and distinct.
    struct Question: Equatable, Identifiable, Sendable {
        let id: UUID
        let question: String
        let options: [String]
        let multiSelect: Bool
    }

    /// The chips picked, by index into the options, and anything the reader typed instead.
    struct Answer: Equatable, Sendable {
        var selected: [Int] = []
        var text: String?

        /// What Stop, or leaving the chat, answers for a question still pending.
        static let none = Answer()
    }

    static func handles(_ name: String) -> Bool {
        name == askUserName
    }

    static func tools() -> [AITool] {
        let ask = AITool(
            name: askUserName,
            description: "Ask the user a question and wait for the answer. Ask only when the "
                + "answer changes what you do next; otherwise make a sensible choice and say "
                + "which. Offer \(optionCount.lowerBound) to \(optionCount.upperBound) short "
                + "options, each under \(optionLimit) characters, that the user can pick with "
                + "one click. The user may also answer in their own words instead.",
            parameters: AIToolJSON.object(
                properties: [
                    "question": AIToolJSON.string("The question, in one or two sentences."),
                    "options": AIToolJSON.strings(
                        "The answers to offer, each a few words.", count: optionCount),
                    "multiSelect": AIToolJSON.boolean(
                        "Whether the user may pick more than one option. Default: false.")
                ],
                required: ["question", "options"]),
            origin: origin, title: "Ask a Question")
        return [ask]
    }

    static func question(
        arguments: String, id: UUID = UUID()
    ) throws(AIToolArguments.Invalid) -> Question {
        let arguments = try AIToolArguments(arguments)
        let question = try arguments.requiredString("question")
        guard let options = arguments.strings("options") else {
            throw Invalid(
                "\u{201C}options\u{201D} must be a list of \(optionCount.lowerBound) to "
                    + "\(optionCount.upperBound) short answers.")
        }
        try check(options)
        return Question(
            id: id, question: question, options: options,
            multiSelect: arguments.bool("multiSelect") ?? false)
    }

    private static func check(_ options: [String]) throws(AIToolArguments.Invalid) {
        guard options.count >= optionCount.lowerBound else {
            throw Invalid("Offer at least \(optionCount.lowerBound) options.")
        }
        guard options.count <= optionCount.upperBound else {
            throw Invalid("Offer at most \(optionCount.upperBound) options.")
        }
        guard !options.contains(where: \.isEmpty) else {
            throw Invalid("Every option needs some text.")
        }
        if let long = options.first(where: { $0.count > optionLimit }) {
            throw Invalid(
                "Keep each option under \(optionLimit) characters; \u{201C}\(long)\u{201D} is "
                    + "longer. Put the detail in the question.")
        }
        var seen: Set<String> = []
        for option in options {
            guard seen.insert(option.lowercased()).inserted else {
                throw Invalid("Each option must differ; \u{201C}\(option)\u{201D} appears twice.")
            }
        }
    }

    static func result(_ answer: Answer, to question: Question, callID: String) -> AIToolResult {
        AIToolResult(callID: callID, content: self.answer(answer, to: question), isError: false)
    }

    /// Chips in the question's order, whatever order they were picked in.
    static func answer(_ answer: Answer, to question: Question) -> String {
        let chosen = question.options.indices.filter(answer.selected.contains)
            .map { question.options[$0] }
        let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let typed = text.isEmpty ? nil : text
        switch (chosen.count, typed) {
        case (0, nil): return "The user did not answer."
        case (0, let typed?): return "The user answered: \(typed)"
        default:
            let choice =
                chosen.count == 1
                ? "The user chose: \(chosen[0])"
                : "The user chose:\n" + chosen.map { "- \($0)" }.joined(separator: "\n")
            return typed.map { choice + "\nThe user added: \($0)" } ?? choice
        }
    }
}
