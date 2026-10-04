import Foundation

/// A call's arguments, read field by field; a model that sends `"30"` for `30` is still understood.
struct AIToolArguments: Sendable {
    /// What the model is told when a call cannot be read, so it can correct the call and retry.
    struct Invalid: Error, Equatable, Sendable {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    private let fields: [String: JSONValue]

    /// An empty string is an empty object: some routes send nothing for a tool with no arguments.
    init(_ text: String) throws(Invalid) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fields = [:]
            return
        }
        guard let fields = JSONValue(data: Data(text.utf8))?.objectValue else {
            throw Invalid("The arguments must be one JSON object.")
        }
        self.fields = fields
    }

    /// Trimmed, and nil when blank, so an empty optional field reads as absent.
    func string(_ key: String) -> String? {
        guard let value = fields[key]?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func requiredString(_ key: String) throws(Invalid) -> String {
        guard let value = string(key) else { throw Invalid("\u{201C}\(key)\u{201D} is required.") }
        return value
    }

    func int(_ key: String) -> Int? {
        fields[key]?.intValue ?? string(key).flatMap { Int($0) }
    }

    func date(_ key: String, calendar: Calendar) throws(Invalid) -> AIToolDate? {
        guard let text = string(key) else { return nil }
        guard let date = AIToolDate(parsing: text, calendar: calendar) else {
            throw Invalid(
                "\u{201C}\(key)\u{201D} must be a real date as YYYY-MM-DD or YYYY-MM-DDTHH:MM.")
        }
        return date
    }
}
