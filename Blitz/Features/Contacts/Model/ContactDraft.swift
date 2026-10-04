import Foundation

/// What the contact prompt collects, before anything touches the address book.
struct ContactDraft: Sendable, Equatable {
    /// One phone or email row; `id` is nil for a value the prompt added.
    struct Field: Sendable, Equatable {
        var id: String?
        var label: String?
        var value: String

        var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var givenName = ""
    var familyName = ""
    var organization = ""
    var phones: [Field] = []
    var emails: [Field] = []

    var trimmedGivenName: String { Self.trimmed(givenName) }
    var trimmedFamilyName: String { Self.trimmed(familyName) }
    var trimmedOrganization: String { Self.trimmed(organization) }

    /// A cleared row is a removed value, so blanks never reach the card.
    var trimmedPhones: [Field] { Self.kept(phones) }
    var trimmedEmails: [Field] { Self.kept(emails) }

    /// A card with nothing left to show would be an unnamed, unreachable row.
    var isValid: Bool {
        !(trimmedGivenName + trimmedFamilyName + trimmedOrganization).isEmpty
            || !trimmedPhones.isEmpty || !trimmedEmails.isEmpty
    }

    /// Unchanged lists are left alone, so a typo fix never rewrites a value synced elsewhere.
    func changesPhones(of contact: ContactItem) -> Bool {
        Self.changes(trimmedPhones, from: contact.phones)
    }

    func changesEmails(of contact: ContactItem) -> Bool {
        Self.changes(trimmedEmails, from: contact.emails)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func kept(_ fields: [Field]) -> [Field] {
        fields.compactMap { field in
            let value = field.trimmedValue
            guard !value.isEmpty else { return nil }
            return Field(id: field.id, label: field.label, value: value)
        }
    }

    private static func changes(_ fields: [Field], from stored: [ContactField]) -> Bool {
        guard fields.count == stored.count else { return true }
        return zip(fields, stored).contains { $0.id != $1.id || $0.value != $1.value }
    }
}

extension ContactDraft {
    init(editing contact: ContactItem) {
        let field = { (stored: ContactField) in
            Field(id: stored.id, label: stored.label, value: stored.value)
        }
        self.init(
            givenName: contact.givenName, familyName: contact.familyName,
            organization: contact.organization, phones: contact.phones.map(field),
            emails: contact.emails.map(field))
    }
}
