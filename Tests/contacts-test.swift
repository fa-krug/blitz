// Contact titles and entry ids, the directory's order, letters and search, drafts, and the links.
import Foundation

@main
@MainActor
struct ContactsTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        titles()
        entryIDs()
        initials()
        ordering()
        letters()
        grouping()
        matching()
        phoneMatching()
        drafts()
        draftChanges()
        callLinks()
        emailLinks()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - The card

    static func titles() {
        expect(contact("a", name: "Greg House").title == "Greg House", "a name is the title")
        let company = contact("b", name: "", organization: "Acme")
        expect(company.title == "Acme", "a company card is titled by its company")
        expect(company.subtitle == nil, "and does not repeat it beneath")
        expect(
            contact("c", name: "Greg", organization: "Acme").subtitle == "Acme",
            "a person's company is the subtitle")
        expect(
            contact("d", name: "  ", emails: ["greg@example.com"]).title == "greg@example.com",
            "a card with no name falls back to its address")
        expect(
            contact("e", name: "", phones: ["+49 151 2345"]).title == "+49 151 2345",
            "then to its number")
        expect(contact("f", name: "").title == "No Name", "an empty card still has a title")
    }

    static func entryIDs() {
        let card = contact("410FE041-5C4E-48DA-B4DE-04C15EA3DBAC:ABPerson", name: "Greg")
        expect(
            ContactItem.id(fromEntryID: card.entryID) == card.id,
            "an entry id round-trips, colon and all")
        expect(ContactItem.id(fromEntryID: "quicklink:abc") == nil, "another kind's id is not one")
        expect(ContactItem.id(fromEntryID: ContactItem.entryIDPrefix) == nil, "nor is a bare prefix")
    }

    static func initials() {
        expect(
            contact("a", name: "Greg House", given: "Greg", family: "House").initials == "GH",
            "a person's initials are one per name part")
        expect(contact("b", name: "", organization: "acme").initials == "A", "a company has one")
        expect(
            contact("c", name: "Émile", given: "émile").initials == "É",
            "an accented letter keeps its accent")
    }

    // MARK: - The directory

    static func ordering() {
        let order = ContactDirectory.sorted([
            contact("3", name: "zoe"), contact("2", name: "Bea"), contact("1", name: "adam"),
            contact("5", name: "Émile"), contact("4", name: "Émile")
        ]).map(\.id)
        expect(
            order == ["1", "2", "4", "5", "3"], "by title, case and accent aside, then id — got \(order)")
    }

    static func letters() {
        expect(ContactDirectory.letter(of: contact("a", name: "émile")) == "E", "accents fold away")
        expect(ContactDirectory.letter(of: contact("b", name: "zoe")) == "Z", "letters upper-case")
        expect(
            ContactDirectory.letter(of: contact("c", name: "", phones: ["0151"])) == "#",
            "a number files under #")
    }

    static func grouping() {
        let groups = ContactDirectory.grouping(
            ContactDirectory.sorted([
                contact("b", name: "Bea"), contact("a2", name: "Al"),
                contact("n", name: "", phones: ["1"]), contact("a1", name: "Ada")
            ]))
        expect(groups.map(\.letter) == ["#", "A", "B"], "one header per letter, in sorted order")
        expect(
            groups.flatMap(\.contacts).map(\.id) == ["n", "a1", "a2", "b"],
            "the groups walk the contacts in sorted order")
        expect(Set(groups.map(\.id)).count == groups.count, "group ids are distinct")
        let split = ContactDirectory.grouping([
            contact("1", name: "Ada"), contact("2", name: "Bea"), contact("3", name: "Al")
        ])
        expect(
            split.map(\.letter) == ["A", "B", "A"],
            "a letter that comes back heads a second run rather than reordering the rows")
        expect(ContactDirectory.grouping([]).isEmpty, "no contacts, no groups")
    }

    static func matching() {
        let cards = [
            contact("greg", name: "Greg House", organization: "Princeton", emails: ["gh@pp.org"]),
            contact("lisa", name: "Lisa Cuddy", organization: "Princeton"),
            contact("jose", name: "José Martí")
        ]
        let found = { ContactDirectory.matching(cards, query: $0).map(\.id) }
        expect(found("") == ["greg", "lisa", "jose"], "an empty query keeps everyone")
        expect(found("greg") == ["greg"], "a name finds its card")
        expect(found("princeton") == ["greg", "lisa"], "so does a company")
        expect(found("house greg") == ["greg"], "every word must hit, in any order")
        expect(found("greg cuddy").isEmpty, "a word nobody has rules a card out")
        expect(found("pp.org") == ["greg"], "an address finds its card")
        expect(found("jose") == ["jose"], "accents fold away")
    }

    static func phoneMatching() {
        let cards = [
            contact("greg", name: "Greg", phones: ["+49 (151) 234-5678"]),
            contact("lisa", name: "Lisa 151")
        ]
        let found = { ContactDirectory.matching(cards, query: $0).map(\.id) }
        expect(found("2345") == ["greg"], "digits find a number, formatting aside")
        expect(found("0151 234") == ["greg"], "a trunk zero still finds the international form")
        expect(found("151") == ["greg", "lisa"], "and a name holding the digits still matches")
        expect(ContactDirectory.dialledNumber("12") == nil, "two digits are too few to dial")
        expect(ContactDirectory.dialledNumber("greg 151") == nil, "a word is not a number")
        expect(ContactDirectory.dialledNumber("+49 151") == "49151", "a number reads as digits")
    }

    // MARK: - Drafts

    static func drafts() {
        expect(!ContactDraft().isValid, "an empty card cannot be written")
        expect(ContactDraft(organization: " Acme ").isValid, "a company alone names a card")
        expect(
            ContactDraft(phones: [.init(id: nil, label: nil, value: "0151")]).isValid,
            "and so does a number")
        let draft = ContactDraft(
            givenName: " Greg ",
            phones: [
                .init(id: "p1", label: "mobile", value: " 0151 "),
                .init(id: nil, label: nil, value: "   ")
            ])
        expect(draft.trimmedGivenName == "Greg", "names are trimmed")
        expect(
            draft.trimmedPhones == [.init(id: "p1", label: "mobile", value: "0151")],
            "a blank row is dropped and the rest trimmed")
    }

    static func draftChanges() {
        let card = contact(
            "a", name: "Greg", phones: ["0151", "0170"], emails: ["gh@pp.org"])
        let editing = ContactDraft(editing: card)
        expect(!editing.changesPhones(of: card), "an untouched draft changes no numbers")
        expect(!editing.changesEmails(of: card), "nor addresses")

        var padded = editing
        padded.phones.append(.init(id: nil, label: nil, value: ""))
        padded.phones[0].value = " 0151 "
        expect(!padded.changesPhones(of: card), "a blank row and stray spaces are not a change")

        var edited = editing
        edited.phones[1].value = "0171"
        expect(edited.changesPhones(of: card), "a new number is a change")
        var removed = editing
        removed.emails[0].value = ""
        expect(removed.changesEmails(of: card), "clearing an address removes it")
        var added = editing
        added.emails.append(.init(id: nil, label: nil, value: "greg@example.com"))
        expect(added.changesEmails(of: card), "an added address is a change")
    }

    // MARK: - Links

    static func callLinks() {
        expect(
            ContactLink.call("+49 (151) 234-5678")?.absoluteString == "tel:+491512345678",
            "formatting is stripped from a number")
        expect(
            ContactLink.call("030 1234#56")?.absoluteString == "tel:0301234%2356",
            "an extension's # is escaped rather than ending the URL")
        expect(ContactLink.call("call me") == nil, "text with no digits is not a number")
    }

    static func emailLinks() {
        expect(
            ContactLink.email(" greg@example.com ")?.absoluteString == "mailto:greg@example.com",
            "an address becomes a mailto link")
        expect(ContactLink.email("greg") == nil, "a word is not an address")
        expect(ContactLink.email("greg @example.com") == nil, "nor is one with a space in it")
    }

    // MARK: - Helpers

    static func contact(
        _ id: String, name: String, given: String = "", family: String = "",
        organization: String = "", phones: [String] = [], emails: [String] = []
    ) -> ContactItem {
        ContactItem(
            id: id, fullName: name, givenName: given, familyName: family,
            organization: organization,
            phones: phones.enumerated().map { ContactField(id: "p\($0)", label: nil, value: $1) },
            emails: emails.enumerated().map { ContactField(id: "e\($0)", label: nil, value: $1) })
    }

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            passes += 1
        } else {
            fail(label)
        }
    }

    static func fail(_ label: String) {
        print("FAIL: \(label)")
        failures += 1
    }
}
