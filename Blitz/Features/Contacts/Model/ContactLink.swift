import Foundation

/// The URLs that reach a contact, built here so a stored value never reaches a handler raw.
enum ContactLink {
    /// What a dialler reads; anything else in a stored number is formatting.
    private static let dialCharacters = Set("0123456789+*#,;")

    /// `tel:` is handed to the Mac's phone handler, which places the call through an iPhone.
    static func call(_ number: String) -> URL? {
        let dialled = number.filter(dialCharacters.contains)
        guard dialled.contains(where: \.isNumber) else { return nil }
        // An unescaped `#` would end the URL there and drop the extension after it.
        return URL(string: "tel:" + dialled.replacingOccurrences(of: "#", with: "%23"))
    }

    /// `mailto:` opens a new message in the default mail app, addressed and nothing more.
    static func email(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), !trimmed.contains(where: \.isWhitespace) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = trimmed
        return components.url
    }
}
