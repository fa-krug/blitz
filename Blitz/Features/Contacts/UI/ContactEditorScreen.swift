import SwiftUI

/// The fields the editor page holds; reference semantics let the store keep it across a hide.
@MainActor
@Observable
final class ContactDraftState {
    let contactID: ContactItem.ID
    /// What the card held when editing began, so an untouched page saves nothing.
    let original: ContactDraft
    var givenName: String
    var familyName: String
    var organization: String
    /// Always one blank row last, the way to add a value; typing into it grows the next.
    private(set) var phones: [ContactDraft.Field]
    private(set) var emails: [ContactDraft.Field]

    init(contact: ContactItem) {
        let draft = ContactDraft(editing: contact)
        contactID = contact.id
        original = draft
        givenName = draft.givenName
        familyName = draft.familyName
        organization = draft.organization
        phones = draft.phones + [Self.blank]
        emails = draft.emails + [Self.blank]
    }

    /// Blank rows are dropped here, so an untouched page reads back as the draft it was given.
    var draft: ContactDraft {
        let filled = { (field: ContactDraft.Field) in !field.trimmedValue.isEmpty }
        return ContactDraft(
            givenName: givenName, familyName: familyName, organization: organization,
            phones: phones.filter(filled), emails: emails.filter(filled))
    }

    func setPhone(_ value: String, at index: Int) {
        guard phones.indices.contains(index) else { return }
        phones[index].value = value
        Self.keepOneBlankRow(&phones)
    }

    func setEmail(_ value: String, at index: Int) {
        guard emails.indices.contains(index) else { return }
        emails[index].value = value
        Self.keepOneBlankRow(&emails)
    }

    private static let blank = ContactDraft.Field(id: nil, label: nil, value: "")

    private static func keepOneBlankRow(_ fields: inout [ContactDraft.Field]) {
        let isBlank = { (field: ContactDraft.Field) in field.id == nil && field.value.isEmpty }
        while fields.count > 1, isBlank(fields[fields.count - 1]), isBlank(fields[fields.count - 2]) {
            fields.removeLast()
        }
        if fields.last.map(isBlank) != true { fields.append(blank) }
    }
}

/// One focusable field of the editor, in the order Tab and ↑/↓ walk them.
enum ContactEditorField: Hashable {
    case givenName
    case familyName
    case organization
    case phone(Int)
    case email(Int)

    var scrollID: String {
        switch self {
        case .givenName: "given"
        case .familyName: "family"
        case .organization: "organization"
        case .phone(let index): "phone-\(index)"
        case .email(let index): "email-\(index)"
        }
    }

    @MainActor static func all(in state: ContactDraftState) -> [Self] {
        [.givenName, .familyName, .organization]
            + state.phones.indices.map(Self.phone) + state.emails.indices.map(Self.email)
    }
}

extension ContactEditorField: Identifiable {
    var id: String { scrollID }
}

/// Edit Contact, inside the palette: the search field steps aside and the fields take the keys.
struct ContactEditorScreen: PaletteScreen {
    let store: ContactsStore
    let core: AppCore
    let vm: PaletteState

    var rows: [ContactEditorField] { store.editor.map(ContactEditorField.all(in:)) ?? [] }

    var primaryActionTitle: String { "Save Contact" }

    var hidesSearchField: Bool { true }

    func hasPrimaryAction(at selection: Int) -> Bool { store.editor != nil }

    func hasActions(at selection: Int) -> Bool { false }

    func activate(at selection: Int) {
        core.contactsCoordinator.saveEdit()
    }

    /// ⌘↵ saves from any field, as a form's does.
    func secondary(at selection: Int) -> Bool {
        core.contactsCoordinator.saveEdit()
        return true
    }

    /// ⇥ / ⇧⇥ walk the fields, wrapping at either end.
    func tabTarget(from selection: Int, backwards: Bool) -> Int? {
        let count = rows.count
        guard count > 0 else { return nil }
        return (selection + (backwards ? -1 : 1) + count) % count
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        guard let state = store.editor, let contact = store.presented else {
            return AnyView(EmptyResults(text: "This contact is no longer available"))
        }
        return AnyView(
            ContactEditorView(
                state: state, contact: contact, fields: rows, selection: selection,
                scroll: scroll, onSelect: { vm.selection = $0 },
                onSubmit: { core.contactsCoordinator.saveEdit() }))
    }
}
