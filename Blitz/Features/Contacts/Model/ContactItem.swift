import Foundation

/// One contact card, flattened out of the Contacts framework so nothing Contacts-shaped leaks out.
struct ContactItem: Identifiable, Hashable, Sendable {
    /// `CNContact.identifier`: stable across launches, and what Contacts.app opens.
    let id: String
    /// The Mac's own name formatting, in the order Contacts shows it; empty for a company card.
    let fullName: String
    let givenName: String
    let familyName: String
    let organization: String
    let phones: [ContactField]
    let emails: [ContactField]

    static let entryIDPrefix = "contact:"

    var entryID: String { Self.entryIDPrefix + id }

    static func id(fromEntryID entryID: String) -> String? {
        guard entryID.hasPrefix(entryIDPrefix) else { return nil }
        let id = String(entryID.dropFirst(entryIDPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// What the card is called: its name, else its company, else the first way to reach it.
    var title: String {
        let candidates = [fullName, organization] + emails.map(\.value) + phones.map(\.value)
        return candidates.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "No Name"
    }

    /// The company, unless it already is the title.
    var subtitle: String? {
        guard !organization.isEmpty, organization != title else { return nil }
        return organization
    }

    /// Up to two letters for the monogram, one per name part, as Contacts draws them.
    var initials: String {
        let parts = [givenName, familyName].filter { !$0.isEmpty }
        let source = parts.isEmpty ? [title] : parts
        return String(source.compactMap(\.first).prefix(2)).uppercased()
    }
}

/// One phone number or email address, with the label the card gives it.
struct ContactField: Identifiable, Hashable, Sendable {
    /// The labeled value's own identifier, so an edit keeps each value's label and place.
    let id: String
    /// Already localized — "mobile", "work" — or nil when the card carries none.
    let label: String?
    let value: String
}
