import Contacts
import Foundation

/// The address book, read from and written back through Contacts. See docs/features/contacts.md.
@MainActor
@Observable
final class ContactsStore {
    /// Every card in `ContactDirectory.sorted` order.
    private(set) var contacts: [ContactItem] = []
    private(set) var access: CalendarAccess = Permissions.contactsAccess()
    /// False until the first read lands, so an empty list never claims the address book is empty.
    private(set) var hasLoaded = false
    /// Cards the reader asked to find from root search; inclusions, since marking is the opt-in.
    private(set) var searchableIDs: Set<String>

    /// Fires after the snapshot or the marks move, so the launcher's slice follows both.
    @ObservationIgnored var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let searchableKey = "launcherContacts"

    @ObservationIgnored private var byID: [String: ContactItem] = [:]
    /// Built on first use, so a Mac with the feature off never loads Contacts at launch.
    @ObservationIgnored private var contactStore: CNContactStore?
    @ObservationIgnored private var changeObserver: NotificationToken?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Names the read in flight, so one that `stop` abandoned cannot clear its successor's slot.
    @ObservationIgnored private var loadGeneration = 0
    /// A sync can post a burst of changes; they collapse into one more read, never a pile of them.
    @ObservationIgnored private var reloadPending = false
    /// A change notice queued just before `stop` must not bring a stopped store back to life.
    @ObservationIgnored private var isRunning = false

    init() {
        searchableIDs = Set(defaults.stringArray(forKey: searchableKey) ?? [])
    }

    /// TCC sends nothing when a grant changes in Settings, so anything acting on `access` re-reads.
    func refreshAccess() {
        access = Permissions.contactsAccess()
    }

    // MARK: - Lifecycle

    func start() {
        isRunning = true
        refreshAccess()
        guard access == .granted else { return }
        reload()
    }

    func stop() {
        isRunning = false
        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
        reloadPending = false
        changeObserver = nil
        contactStore = nil
        publish([])
        hasLoaded = false
    }

    /// Blitz's own consent dialog has already been accepted by the time this runs.
    func requestAccess() async -> Bool {
        let granted = await Permissions.requestContactsAccess()
        refreshAccess()
        guard granted else { return false }
        changeObserver = nil
        contactStore = nil
        reload()
        return true
    }

    /// Covers an edit made in Contacts.app, on another device, or by this store's own save.
    private func observeStoreChanges() {
        guard changeObserver == nil else { return }
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        changeObserver = NotificationToken(token, center: center)
    }

    // MARK: - Reading

    func reload() {
        guard isRunning else { return }
        guard loadTask == nil else {
            reloadPending = true
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            await self?.load()
            self?.loadFinished(generation)
        }
    }

    private func loadFinished(_ generation: Int) {
        guard generation == loadGeneration else { return }
        loadTask = nil
        guard reloadPending else { return }
        reloadPending = false
        reload()
    }

    /// The whole book is read off main: thousands of cards are a visible stall on the summon path.
    private func load() async {
        refreshAccess()
        guard access == .granted else {
            publish([])
            return
        }
        _ = currentStore()
        observeStoreChanges()
        let fetched = await Task.detached(priority: .userInitiated) { Self.fetchAll() }.value
        guard !Task.isCancelled, isRunning, let fetched else { return }
        publish(ContactDirectory.sorted(fetched))
    }

    /// A store of its own: `CNContactStore` is safe to use from any thread, but is not `Sendable`.
    nonisolated private static func fetchAll() -> [ContactItem]? {
        Signposts.interval("ContactsStore.fetch") {
            let store = CNContactStore()
            let formatter = CNContactFormatter()
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = true
            var items: [ContactItem] = []
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    items.append(item(from: contact, formatter: formatter))
                }
            } catch {
                return nil
            }
            return items
        }
    }

    nonisolated private static var keys: [any CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as NSString, CNContactFamilyNameKey as NSString,
            CNContactOrganizationNameKey as NSString, CNContactPhoneNumbersKey as NSString,
            CNContactEmailAddressesKey as NSString
        ]
    }

    nonisolated private static func item(
        from contact: CNContact, formatter: CNContactFormatter
    ) -> ContactItem {
        ContactItem(
            id: contact.identifier,
            fullName: formatter.string(from: contact) ?? "",
            givenName: contact.givenName,
            familyName: contact.familyName,
            organization: contact.organizationName,
            phones: contact.phoneNumbers.map {
                ContactField(id: $0.identifier, label: label($0.label), value: $0.value.stringValue)
            },
            emails: contact.emailAddresses.map {
                ContactField(id: $0.identifier, label: label($0.label), value: $0.value as String)
            })
    }

    nonisolated private static func label(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }

    private func publish(_ next: [ContactItem]) {
        if access == .granted, !hasLoaded { hasLoaded = true }
        guard next != contacts else { return }
        contacts = next
        byID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        onChange?()
    }

    func contact(id: ContactItem.ID) -> ContactItem? {
        byID[id]
    }

    // MARK: - Writing

    /// False when the card is gone or will not save; anything the prompt does not show is kept.
    func update(_ item: ContactItem, with draft: ContactDraft) -> Bool {
        let store = currentStore()
        guard access == .granted,
            let stored = try? store.unifiedContact(withIdentifier: item.id, keysToFetch: Self.keys),
            let contact = stored.mutableCopy() as? CNMutableContact
        else { return false }
        contact.givenName = draft.trimmedGivenName
        contact.familyName = draft.trimmedFamilyName
        contact.organizationName = draft.trimmedOrganization
        if draft.changesPhones(of: item) {
            contact.phoneNumbers = Self.labeled(
                draft.trimmedPhones, replacing: contact.phoneNumbers,
                newLabel: CNLabelPhoneNumberMobile, value: { CNPhoneNumber(stringValue: $0) })
        }
        if draft.changesEmails(of: item) {
            contact.emailAddresses = Self.labeled(
                draft.trimmedEmails, replacing: contact.emailAddresses,
                newLabel: CNLabelHome, value: { $0 as NSString })
        }
        let request = CNSaveRequest()
        request.update(contact)
        guard (try? store.execute(request)) != nil else { return false }
        reload()
        return true
    }

    /// An existing value keeps its identifier and label; one the prompt added takes `newLabel`.
    private static func labeled<Value: NSCopying & NSSecureCoding>(
        _ fields: [ContactDraft.Field], replacing existing: [CNLabeledValue<Value>],
        newLabel: String, value: (String) -> Value
    ) -> [CNLabeledValue<Value>] {
        fields.map { field in
            if let id = field.id, let stored = existing.first(where: { $0.identifier == id }) {
                return stored.settingValue(value(field.value))
            }
            return CNLabeledValue(label: newLabel, value: value(field.value))
        }
    }

    private func currentStore() -> CNContactStore {
        let store = contactStore ?? CNContactStore()
        contactStore = store
        return store
    }

    // MARK: - Root search

    func isSearchable(_ contact: ContactItem) -> Bool {
        searchableIDs.contains(contact.id)
    }

    func setSearchable(_ searchable: Bool, for contact: ContactItem) {
        if searchable {
            searchableIDs.insert(contact.id)
        } else {
            searchableIDs.remove(contact.id)
        }
        defaults.set(Array(searchableIDs), forKey: searchableKey)
        onChange?()
    }
}
