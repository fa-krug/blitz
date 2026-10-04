import AppKit

/// Hands a contact, a number or an address to the app that owns it.
@MainActor
enum ContactLauncher {
    private static let contactsBundleID = "com.apple.AddressBook"

    /// Contacts' own scheme opens the card itself; with no handler, the app opens bare.
    @discardableResult
    static func show(_ contact: ContactItem) -> Bool {
        let workspace = NSWorkspace.shared
        if let url = cardURL(contact), workspace.urlForApplication(toOpen: url) != nil {
            return workspace.open(url)
        }
        guard let app = workspace.urlForApplication(withBundleIdentifier: contactsBundleID) else {
            return false
        }
        return workspace.open(app)
    }

    /// False when nothing on this Mac handles the link, which the caller reports.
    static func open(_ url: URL) -> Bool {
        let workspace = NSWorkspace.shared
        guard workspace.urlForApplication(toOpen: url) != nil else { return false }
        return workspace.open(url)
    }

    /// An identifier reads as `host:port` to a strict parser, so the colon is escaped if refused.
    private static func cardURL(_ contact: ContactItem) -> URL? {
        if let url = URL(string: "addressbook://" + contact.id) { return url }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let encoded = contact.id.addingPercentEncoding(withAllowedCharacters: allowed)
        return encoded.flatMap { URL(string: "addressbook://" + $0) }
    }
}
