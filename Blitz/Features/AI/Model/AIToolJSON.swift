import Foundation

/// The JSON Blitz's own tools speak: the schemas a model is offered and the results it reads back.
enum AIToolJSON {
    static func object(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string))
        ])
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static func strings(_ description: String, count: ClosedRange<Int>) -> JSONValue {
        .object([
            "type": .string("array"), "description": .string(description),
            "items": .object(["type": .string("string")]),
            "minItems": .number(Double(count.lowerBound)),
            "maxItems": .number(Double(count.upperBound))
        ])
    }

    /// Sorted keys, so the same answer is the same text and a harness can pin it.
    static func text(_ value: JSONValue) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value.jsonObject, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Cut to a length a tool result can afford, marked so the model knows there was more.
    static func clipped(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        return String(text.prefix(length)) + "\u{2026}"
    }

    /// The longest start of `text` within `bytes` of UTF-8, cut between characters.
    static func prefix(_ text: String, utf8Bytes bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var used = 0
        var end = text.startIndex
        for character in text {
            used += character.utf8.count
            guard used <= bytes else { break }
            end = text.index(after: end)
        }
        return String(text[..<end])
    }
}
