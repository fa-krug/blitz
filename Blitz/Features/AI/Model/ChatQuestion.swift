import Foundation

/// A question a reply asked with `ask_user`, pinned where it was asked like a search or a call.
struct ChatQuestion: Hashable, Sendable {
    typealias Answer = AskUserToolCatalog.Answer

    let question: AskUserToolCatalog.Question
    /// Nil while the turn waits on the reader; `.none` once Stop or a deleted chat ended the wait.
    var answer: Answer?
    /// Chips toggled so far on a multi-select question still waiting.
    var picked: Set<Int> = []
    /// Characters of reply text that had arrived when the question was asked.
    let textOffset: Int
    let sequence: Int

    var isPending: Bool { answer == nil }

    /// A single choice answers at once, so only a multi-select question toggles.
    mutating func toggle(_ option: Int) {
        guard isPending, question.multiSelect, question.options.indices.contains(option) else {
            return
        }
        if picked.remove(option) == nil { picked.insert(option) }
    }

    func answer(choosing option: Int) -> Answer? {
        guard isPending, question.options.indices.contains(option) else { return nil }
        return Answer(selected: [option])
    }

    /// The composer's answer: the typed text with any toggled chips, nil while both are empty.
    func answer(typing text: String) -> Answer? {
        guard isPending else { return nil }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = picked.sorted()
        guard !typed.isEmpty || !selected.isEmpty else { return nil }
        return Answer(selected: selected, text: typed.isEmpty ? nil : typed)
    }

    /// In the question's order, whatever order they were picked in.
    var chosenOptions: [String] {
        guard let answer else { return [] }
        return question.options.indices.filter(answer.selected.contains)
            .map { question.options[$0] }
    }

    var typedAnswer: String? {
        guard let text = answer?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }

    /// Answered with nothing: Stop, or the chat going away, ended the wait.
    var wentUnanswered: Bool { answer != nil && chosenOptions.isEmpty && typedAnswer == nil }
}
