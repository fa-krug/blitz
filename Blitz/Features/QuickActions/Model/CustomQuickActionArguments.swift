import Foundation

/// Placeholders live apart from the record, so a harness that only names actions skips the engine.
extension CustomQuickAction {
    /// The `{argument}`s the instructions declare, asked for before a run; `default=` answers itself.
    var arguments: [SnippetTemplateEngine.MissingArgument] {
        SnippetTemplateEngine.declaredArguments(in: instructions)
    }

    func isMissingArguments(_ values: [String: String]) -> Bool {
        arguments.contains { values[$0.name, default: ""].isEmpty }
    }

    /// The record a run carries: its placeholders filled once, so a retry asks the same question.
    func filled(with values: [String: String], now: Date = Date()) -> CustomQuickAction {
        let context = SnippetTemplateEngine.ExpansionContext(
            clipboardHistory: [], selection: "", now: now, calendar: .current,
            locale: .current, timeZone: .current)
        var filled = self
        filled.instructions =
            SnippetTemplateEngine.expand(
                text: instructions, context: context, userArguments: values
            ).text
        return filled
    }
}
