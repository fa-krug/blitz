import SwiftUI

/// Search Contacts: the whole address book under a letter per run, filtered by the query.
struct ContactsScreen: PaletteScreen {
    let store: ContactsStore
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    /// Filtering keeps the store's order, so these are exactly the rows the groups walk.
    var rows: [ContactItem] { ContactDirectory.matching(store.contacts, query: vm.query) }

    var primaryActionTitle: String { "Edit Contact" }

    private func contact(at selection: Int) -> ContactItem? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let contact = contact(at: selection) else { return nil }
        return ContactActionsMenu.content(contact: contact, core: core, context: .list)
    }

    func activate(at selection: Int) {
        guard let contact = contact(at: selection) else { return }
        core.contactsCoordinator.edit(contact)
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
        guard shortcut == .openInApp, let contact = contact(at: selection) else { return false }
        core.contactsCoordinator.openInContacts(contact)
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
                onActivate: { core.contactsCoordinator.edit($0) },
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

/// The ⌘K menu for a contact, from its own list or from its row in root search.
@MainActor
enum ContactActionsMenu {
    enum Context {
        /// Search Contacts, where ↵ edits.
        case list
        /// A marked card in root search, where ↵ opens it in Search Contacts.
        case launcher
    }

    static func content(
        contact: ContactItem, core: AppCore, context: Context
    ) -> PopoverMenuContent {
        PopoverMenuContent(
            header: contact.title, items: items(contact: contact, core: core, context: context))
    }

    static func items(
        contact: ContactItem, core: AppCore, context: Context
    ) -> [PopoverMenuItem] {
        let coordinator = core.contactsCoordinator
        var items: [PopoverMenuItem] =
            switch context {
            case .list:
                [
                    PopoverMenuItem(title: "Edit Contact", systemImage: "pencil", shortcut: "↵") {
                        coordinator.edit(contact)
                    }
                ]
            case .launcher:
                [
                    PopoverMenuItem(
                        title: "Show Contact", systemImage: "person.crop.circle", shortcut: "↵"
                    ) {
                        coordinator.showContact(entryID: contact.entryID)
                    }
                ]
            }
        items += reachItems(contact: contact, coordinator: coordinator)
        items += copyItems(contact: contact, coordinator: coordinator)
        items.append(
            PopoverMenuItem(
                title: "Open in Contacts", systemImage: "person.crop.rectangle.stack",
                startsSection: true, shortcut: "⌘O"
            ) {
                coordinator.openInContacts(contact)
            })
        if context == .launcher {
            items.append(
                PopoverMenuItem(title: "Edit Contact", systemImage: "pencil") {
                    coordinator.edit(contact)
                })
        }
        let searchable = coordinator.isSearchable(contact)
        items.append(
            PopoverMenuItem(
                title: searchable ? "Remove from Launcher Search" : "Show in Launcher Search",
                systemImage: searchable ? "minus.magnifyingglass" : "plus.magnifyingglass",
                startsSection: context == .list
            ) {
                coordinator.toggleSearchable(contact)
            })
        return items
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
                    detail: phone.value
                ) {
                    coordinator.copy(phone)
                })
        }
        if let email = contact.emails.first {
            items.append(
                PopoverMenuItem(
                    title: "Copy Email Address", icon: .symbol("doc.on.doc"),
                    startsSection: items.isEmpty, detail: email.value
                ) {
                    coordinator.copy(email)
                })
        }
        return items
    }
}
