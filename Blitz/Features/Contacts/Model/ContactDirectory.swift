import Foundation

/// One letter's contacts: a header and the rows beneath it.
struct ContactGroup: Identifiable, Sendable {
    let letter: String
    let contacts: [ContactItem]
    /// The run's position, since a letter can head two runs when a sort key folds differently.
    let index: Int

    var id: Int { index }
}

/// The one place that orders, buckets and searches contacts, so the list and its selection agree.
enum ContactDirectory {
    /// Fewer digits than this match half the address book, so they search names instead.
    static let minimumPhoneDigits = 3

    static func sorted(_ contacts: [ContactItem]) -> [ContactItem] {
        contacts.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// Runs of one letter in the order given, so the groups walk exactly the rows they head.
    static func grouping(_ contacts: [ContactItem]) -> [ContactGroup] {
        var groups: [ContactGroup] = []
        var run: [ContactItem] = []
        var letter = ""
        for contact in contacts {
            let next = Self.letter(of: contact)
            if next != letter, !run.isEmpty {
                groups.append(ContactGroup(letter: letter, contacts: run, index: groups.count))
                run = []
            }
            letter = next
            run.append(contact)
        }
        if !run.isEmpty {
            groups.append(ContactGroup(letter: letter, contacts: run, index: groups.count))
        }
        return groups
    }

    /// The title's first letter, accent dropped; anything else files under `#`, as Contacts does.
    static func letter(of contact: ContactItem) -> String {
        guard let first = contact.title.first, first.isLetter else { return "#" }
        return String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
    }

    /// Every word must hit a name, the company or an address; a dialled number finds its card.
    static func matching(_ contacts: [ContactItem], query: String) -> [ContactItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return contacts }
        let number = dialledNumber(query)
        return contacts.filter { contact in
            if let number, contact.phones.contains(where: { digits(of: $0.value).contains(number) }) {
                return true
            }
            let fields =
                [contact.title, contact.givenName, contact.familyName, contact.organization]
                + contact.emails.map(\.value)
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }
    }

    /// The query's digits if it reads as a number, minus a trunk `0`, so `0151` finds `+49 151`.
    static func dialledNumber(_ query: String) -> String? {
        let phoneCharacters = CharacterSet(charactersIn: "0123456789+-()./ ")
        guard query.unicodeScalars.allSatisfy(phoneCharacters.contains) else { return nil }
        let number = String(digits(of: query).drop { $0 == "0" })
        return number.count >= minimumPhoneDigits ? number : nil
    }

    private static func digits(of text: String) -> String {
        String(text.filter(\.isASCIIDigit))
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
