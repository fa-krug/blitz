import AppKit

/// Owns the contacts feature: the consent gate, the commands, root search and every write.
@MainActor
final class ContactsCoordinator {
    private let store: ContactsStore
    private let appIndex: AppIndex
    private let settings: AppSettings
    private let paletteCoordinator: PaletteCoordinator
    /// Dialogs and the HUD, so both stay owned by `AppCore`.
    private unowned let core: AppCore

    init(
        store: ContactsStore,
        appIndex: AppIndex,
        settings: AppSettings,
        paletteCoordinator: PaletteCoordinator,
        core: AppCore
    ) {
        self.store = store
        self.appIndex = appIndex
        self.settings = settings
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    // MARK: - Feature switch

    /// The switch funnels here so enabling, which is also consent, confirms first.
    func setContactsEnabled(_ enabled: Bool) {
        if !enabled {
            guard settings.contactsEnabled else { return }
            settings.contactsEnabled = false
            return
        }

        // Asking again is the only way back: Settings cannot add an app TCC has no record of.
        store.refreshAccess()
        guard !settings.contactsEnabled || store.access != .granted else { return }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: "Enable contacts?",
                    message:
                        "Blitz lists your contacts so you can call, email and edit them from the "
                        + "palette. Your contacts are never sent anywhere.",
                    symbol: "person.crop.circle", confirmTitle: "Continue", tone: .neutral,
                    confirmRole: .standard)
            else { return }

            guard await store.requestAccess() else { return }
            // The flag is consent, so it is written only once macOS has actually granted access.
            settings.contactsEnabled = true
            applyEnabled()
        }
    }

    /// Publishes or withdraws everything the feature contributes to the launcher.
    func applyEnabled() {
        appIndex.setCommandsVisible([.searchContacts], settings.contactsEnabled)
        if settings.contactsEnabled {
            store.start()
        } else {
            store.stop()
        }
        publishEntries()
    }

    /// Access revoked in System Settings announces nothing, so opening the list re-reads it.
    func contactsWillShow() {
        guard settings.contactsEnabled else { return }
        store.reload()
    }

    // MARK: - Root search

    /// Only the cards the reader marked; the store's change hook calls this as either side moves.
    func publishEntries() {
        guard settings.contactsEnabled else {
            appIndex.setContacts([])
            return
        }
        appIndex.setContacts(store.contacts.filter(store.isSearchable).map(Self.entry(for:)))
    }

    private static func entry(for contact: ContactItem) -> AppEntry {
        let path = contact.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return AppEntry(
            id: contact.entryID, name: contact.title, url: URL(string: "blitz://contact/" + path)!,
            bundleID: nil, kind: .contact, settingsOwner: .contacts, subtitle: contact.subtitle,
            keywords: contact.emails.map(\.value))
    }

    func contact(entryID: String) -> ContactItem? {
        ContactItem.id(fromEntryID: entryID).flatMap(store.contact(id:))
    }

    func isSearchable(_ contact: ContactItem) -> Bool {
        store.isSearchable(contact)
    }

    func setSearchable(_ searchable: Bool, for contact: ContactItem) {
        store.setSearchable(searchable, for: contact)
    }

    func toggleSearchable(_ contact: ContactItem) {
        let searchable = !store.isSearchable(contact)
        store.setSearchable(searchable, for: contact)
        core.showMessage(
            searchable
                ? "\u{201C}\(contact.title)\u{201D} is in launcher search"
                : "\u{201C}\(contact.title)\u{201D} left launcher search")
    }

    // MARK: - Commands

    /// `query` is the fallback row's, so the list opens already narrowed to it.
    func show(query: String = "") {
        paletteCoordinator.togglePalette(mode: .contacts, seeding: query.isEmpty ? nil : query)
    }

    /// ↵ on a card in root search opens the list on that card, where every action is a key away.
    func showContact(entryID: String) {
        guard let contact = contact(entryID: entryID) else { return }
        paletteCoordinator.showPalette(mode: .contacts, seeding: contact.title)
    }

    // MARK: - Row actions

    /// ↵ on a row. The palette stays up behind the dialog, so the list shows the edit landing.
    func edit(_ contact: ContactItem) {
        Task {
            let original = ContactDraft(editing: contact)
            guard let draft = await core.editContact(original), draft != original else { return }
            guard store.update(contact, with: draft) else {
                await reportGone(contact)
                return
            }
            core.showMessage("Contact saved")
        }
    }

    /// The first number unless a menu row named one; the phone handler takes it from there.
    func call(_ contact: ContactItem, number: ContactField? = nil) {
        guard let number = number ?? contact.phones.first else {
            report("\(contact.title) has no phone number")
            return
        }
        guard let url = ContactLink.call(number.value) else {
            report("\u{201C}\(number.value)\u{201D} can't be dialled")
            return
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        if !ContactLauncher.open(url) { report("Nothing on this Mac can place calls") }
    }

    func email(_ contact: ContactItem, address: ContactField? = nil) {
        guard let address = address ?? contact.emails.first else {
            report("\(contact.title) has no email address")
            return
        }
        guard let url = ContactLink.email(address.value) else {
            report("\u{201C}\(address.value)\u{201D} isn't an email address")
            return
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        if !ContactLauncher.open(url) { report("Nothing on this Mac can send email") }
    }

    func copy(_ field: ContactField) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(field.value)
    }

    func openInContacts(_ contact: ContactItem) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        if !ContactLauncher.show(contact) { report("Contacts isn't available on this Mac") }
    }

    // MARK: - Reports

    private func reportGone(_ contact: ContactItem) async {
        _ = await core.reportFailure(
            title: "Couldn't change \u{201C}\(contact.title)\u{201D}",
            message: "It may have been changed or deleted somewhere else.",
            symbol: "person.crop.circle", recovery: nil)
    }

    /// A miss is transient, so it reports through the HUD rather than a dialog needing dismissal.
    private func report(_ message: String) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.showMessage(message, tone: .neutral)
    }
}
