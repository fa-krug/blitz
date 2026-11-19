import SwiftUI

/// Search Contacts: the whole address book under a letter per run, filtered by the query.
struct ContactsScreen: PaletteScreen {
    let store: ContactsStore
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    /// Filtering keeps the store's order, so these are exactly the rows the groups walk.
    var rows: [ContactItem] { ContactDirectory.matching(store.contacts, query: vm.query) }

    var primaryActionTitle: String { "Show Contact" }

    private func contact(at selection: Int) -> ContactItem? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let contact = contact(at: selection) else { return nil }
        return ContactActionsMenu.content(contact: contact, core: core)
    }

    func activate(at selection: Int) {
        guard let contact = contact(at: selection) else { return }
        core.contactsCoordinator.showCard(contact)
    }

    /// ⌘↵ — call, the other thing a card is for.
    func secondary(at selection: Int) -> Bool {
        guard let contact = contact(at: selection) else { return false }
        core.contactsCoordinator.call(contact)
        return true
    }

    /// ⌃⌘↵ — write to the card's first address.
    func tertiary(at selection: Int) -> Bool {
        guard let contact = contact(at: selection) else { return false }
        core.contactsCoordinator.email(contact)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard let contact = contact(at: selection) else { return false }
        switch shortcut {
        case .edit: core.contactsCoordinator.edit(contact)
        case .openInApp: core.contactsCoordinator.openInContacts(contact)
        case .copyFile: core.contactsCoordinator.copyPhone(contact)
        case .copyName: core.contactsCoordinator.copyEmail(contact)
        default: return false
        }
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        let rows = rows
        if rows.isEmpty {
            emptyState
        } else {
            ContactsList(
                groups: ContactDirectory.grouping(rows),
                selectedID: rows.indices.contains(selection) ? rows[selection].id : nil,
                searchableIDs: store.searchableIDs,
                scroll: scroll,
                onActivate: { core.contactsCoordinator.showCard($0) },
                onActions: { contact in
                    if let index = rows.firstIndex(of: contact) { vm.selection = index }
                    openActions()
                }
            )
        }
    }

    /// Names why the list is empty: no access reads very differently from an empty address book.
    private var emptyState: EmptyResults {
        switch store.access {
        case .denied:
            return EmptyResults(
                text: "Blitz has no access to your contacts", symbol: "person.crop.circle",
                hint: "Allow Blitz under Privacy & Security in System Settings",
                action: .init(title: "Open Privacy Settings") {
                    core.paletteCoordinator.hidePalette(restoreFocus: false)
                    Permissions.openContactsSettings()
                })
        // Settings lists no app TCC has no record of, so only asking again gets Blitz there.
        case .notDetermined:
            return EmptyResults(
                text: "Blitz hasn't been given access to your contacts", symbol: "person.crop.circle",
                hint: "macOS asks once before Blitz can read them",
                action: .init(title: "Allow Access") {
                    core.paletteCoordinator.hidePalette(restoreFocus: false)
                    core.contactsCoordinator.setContactsEnabled(true)
                })
        case .granted:
            break
        }
        if !store.hasLoaded {
            return EmptyResults(text: "Loading contacts…", symbol: "person.crop.circle")
        }
        if !vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return EmptyResults(text: "No matching contacts")
        }
        return EmptyResults(text: "No contacts", symbol: "person.crop.circle")
    }
}

/// The ⌘K menus for a contact: from its row in a list, or from a line on its own card.
@MainActor
enum ContactActionsMenu {
    /// From Search Contacts or a marked card in root search, where ↵ opens the card.
    static func content(contact: ContactItem, core: AppCore) -> PopoverMenuContent {
        PopoverMenuContent(header: contact.title, items: items(contact: contact, core: core))
    }

    static func items(contact: ContactItem, core: AppCore) -> [PopoverMenuItem] {
        let coordinator = core.contactsCoordinator
        var items = [
            PopoverMenuItem(title: "Show Contact", systemImage: "person.crop.circle", shortcut: "↵") {
                coordinator.showCard(contact)
            }
        ]
        items += reachItems(contact: contact, coordinator: coordinator)
        items += copyItems(contact: contact, coordinator: coordinator)
        items += cardItems(contact: contact, coordinator: coordinator)
        return items
    }

    /// On the card, the selected line leads: ↵ reaches it and ⌘↵ copies it.
    static func cardContent(
        contact: ContactItem, row: ContactCardRow?, core: AppCore
    ) -> PopoverMenuContent {
        let coordinator = core.contactsCoordinator
        var items: [PopoverMenuItem] = []
        if let row {
            let isPhone = row.kind == .phone
            items.append(
                PopoverMenuItem(
                    title: "\(isPhone ? "Call" : "Email") \(row.field.value)",
                    icon: .symbol(isPhone ? "phone" : "envelope"), shortcut: "↵"
                ) {
                    reach(row, of: contact, coordinator: coordinator)
                })
            items.append(
                PopoverMenuItem(
                    title: isPhone ? "Copy Phone Number" : "Copy Email Address",
                    icon: .symbol("doc.on.doc"), shortcut: "⌘↵"
                ) {
                    coordinator.copy(row.field)
                })
        }
        items += cardItems(contact: contact, coordinator: coordinator)
        return PopoverMenuContent(header: contact.title, items: items)
    }

    /// One line of the card, reached the way its kind is: a call or a new message.
    static func reach(
        _ row: ContactCardRow, of contact: ContactItem, coordinator: ContactsCoordinator
    ) {
        switch row.kind {
        case .phone: coordinator.call(contact, number: row.field)
        case .email: coordinator.email(contact, address: row.field)
        }
    }

    /// The rows every menu ends on: the card itself, then whether root search lists it.
    private static func cardItems(
        contact: ContactItem, coordinator: ContactsCoordinator
    ) -> [PopoverMenuItem] {
        let searchable = coordinator.isSearchable(contact)
        return [
            PopoverMenuItem(
                title: "Edit Contact", systemImage: "pencil", startsSection: true, shortcut: "⌘E"
            ) {
                coordinator.edit(contact)
            },
            PopoverMenuItem(
                title: "Open in Contacts", systemImage: "person.crop.rectangle.stack",
                shortcut: "⌘O"
            ) {
                coordinator.openInContacts(contact)
            },
            PopoverMenuItem(
                title: searchable ? "Remove from Launcher Search" : "Show in Launcher Search",
                systemImage: searchable ? "minus.magnifyingglass" : "plus.magnifyingglass",
                startsSection: true
            ) {
                coordinator.toggleSearchable(contact)
            }
        ]
    }

    /// One row per number and address, so a card's second line is as reachable as its first.
    private static func reachItems(
        contact: ContactItem, coordinator: ContactsCoordinator
    ) -> [PopoverMenuItem] {
        let calls = contact.phones.enumerated().map { index, phone in
            PopoverMenuItem(
                title: "Call \(phone.value)", icon: .symbol("phone"), startsSection: index == 0,
                shortcut: index == 0 ? "⌘↵" : nil, detail: phone.label
            ) {
                coordinator.call(contact, number: phone)
            }
        }
        let emails = contact.emails.enumerated().map { index, email in
            PopoverMenuItem(
                title: "Email \(email.value)", icon: .symbol("envelope"),
                startsSection: index == 0 && calls.isEmpty, shortcut: index == 0 ? "⌃⌘↵" : nil,
                detail: email.label
            ) {
                coordinator.email(contact, address: email)
            }
        }
        return calls + emails
    }

    private static func copyItems(
        contact: ContactItem, coordinator: ContactsCoordinator
    ) -> [PopoverMenuItem] {
        var items: [PopoverMenuItem] = []
        if let phone = contact.phones.first {
            items.append(
                PopoverMenuItem(
                    title: "Copy Phone Number", icon: .symbol("doc.on.doc"), startsSection: true,
                    shortcut: "⇧⌘C", detail: phone.value
                ) {
                    coordinator.copy(phone)
                })
        }
        if let email = contact.emails.first {
            items.append(
                PopoverMenuItem(
                    title: "Copy Email Address", icon: .symbol("doc.on.doc"),
                    startsSection: items.isEmpty, shortcut: "⌥⌘C", detail: email.value
                ) {
                    coordinator.copy(email)
                })
        }
        return items
    }
}
