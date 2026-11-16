import Foundation

/// Sources an API cites beside its text, inlined as the Markdown links `ChatReferences` reads.
struct AICitationLinker: Sendable {
    private var text = ""
    private var linked: Set<String> = []

    mutating func record(_ delta: String) {
        text += delta
    }

    /// Nil for a page the reply already links, so a source the model wrote itself is not repeated.
    mutating func link(to string: String) -> String? {
        guard let url = URL(string: string), url.scheme == "https" || url.scheme == "http",
            !text.contains(string), linked.insert(string).inserted
        else { return nil }
        // A bare `)` would close the Markdown link early, and `ChatReferences` would cut it there.
        let target = string.replacing("(", with: "%28").replacing(")", with: "%29")
        return " ([\(ChatReference.host(of: url))](\(target)))"
    }
}
