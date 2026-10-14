import Foundation

/// How a chat model searches the user's contacts, and what it is told of each card.
enum ContactToolCatalog {
    static let origin = "Contacts"
    static let searchName = "contacts_search"
    static let defaultLimit = 10
    static let limitCap = 25
    /// `CNContact` keys a search reads besides the name: never the note, nor any image.
    static let fetchedKeys = [
        "organizationName", "phoneNumbers", "emailAddresses", "postalAddresses", "birthday"
    ]

    private typealias Invalid = AIToolArguments.Invalid

    struct Request: Equatable, Sendable {
        let query: String
        let limit: Int
    }

    /// One card as the model reads it, flattened out of Contacts by the store.
    struct Card: Equatable, Sendable {
        struct Field: Equatable, Sendable {
            let label: String?
            let value: String
        }

        /// A birthday kept without its year says only the day.
        struct Birthday: Equatable, Sendable {
            let year: Int?
            let month: Int
            let day: Int
        }

        let name: String
        let organization: String
        let emails: [Field]
        let phones: [Field]
        /// Each one formatted onto a single line.
        let addresses: [Field]
        let birthday: Birthday?
    }

    static func handles(_ name: String) -> Bool { name == searchName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: searchName,
                description: "Search the user's contacts by name, email address, phone number or "
                    + "company. Each match comes back with its name, company, email addresses, "
                    + "phone numbers, postal addresses and birthday. The user may be asked to "
                    + "confirm, and may decline.",
                parameters: AIToolJSON.object(
                    properties: [
                        "query": AIToolJSON.string(
                            "Words every match must contain in a name, email address or company, "
                                + "or a phone number to find."),
                        "limit": AIToolJSON.integer(
                            "Most contacts to return: \(defaultLimit) unless given, at most "
                                + "\(limitCap).")
                    ],
                    required: ["query"]),
                origin: origin, title: "Search Contacts")
        ]
    }

    static func request(arguments: String) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        let query = try arguments.requiredString("query")
        guard arguments.contains("limit") else { return Request(query: query, limit: defaultLimit) }
        guard let limit = arguments.int("limit"), limit >= 1 else {
            throw Invalid("\u{201C}limit\u{201D} must be a whole number from 1.")
        }
        return Request(query: query, limit: min(limit, limitCap))
    }

    /// JSON in the address book's order; `matches` counts every card the query found.
    static func answer(_ cards: [Card], query: String, matches: Int) -> String {
        guard !cards.isEmpty else { return "No contact matches \u{201C}\(query)\u{201D}." }
        return AIToolJSON.text(
            .object([
                "query": .string(query),
                "matches": .number(Double(matches)),
                "shown": .number(Double(cards.count)),
                "contacts": .array(cards.map(json))
            ]))
    }

    private static func json(_ card: Card) -> JSONValue {
        var fields: [String: JSONValue] = ["name": .string(card.name)]
        if !card.organization.isEmpty { fields["organization"] = .string(card.organization) }
        if !card.emails.isEmpty { fields["emails"] = .array(card.emails.map(json)) }
        if !card.phones.isEmpty { fields["phones"] = .array(card.phones.map(json)) }
        if !card.addresses.isEmpty { fields["addresses"] = .array(card.addresses.map(json)) }
        if let birthday = card.birthday { fields["birthday"] = .string(text(of: birthday)) }
        return .object(fields)
    }

    private static func json(_ field: Card.Field) -> JSONValue {
        guard let label = field.label else { return .object(["value": .string(field.value)]) }
        return .object(["label": .string(label), "value": .string(field.value)])
    }

    /// `YYYY-MM-DD`, or ISO 8601's `--MM-DD` for a birthday kept without its year.
    static func text(of birthday: Card.Birthday) -> String {
        let day = String(format: "%02d-%02d", birthday.month, birthday.day)
        guard let year = birthday.year else { return "--" + day }
        return String(format: "%04d-", year) + day
    }

    static let noAccess = "macOS has not given Blitz access to Contacts."
    static let loading = "Blitz is still reading the address book. Try again in a moment."
}
